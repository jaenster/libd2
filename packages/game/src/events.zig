//! EVENT timer subsystem — faithful port of the D2 1.14d server per-unit timer queue.
//!
//! Ghidra session 62fbfe69, Game.exe. The engine does NOT walk every unit every frame:
//! each unit schedules its periodic work (AI think, stat regen, skill/state expiry,
//! mode changes) as timer callbacks in a 64-bucket ring, and the frame dispatch fires
//! whatever is due. Modelled functions/types:
//!   D2TimerQueueStrc  (pGame->pTimerQueue)  pTimerListByType[5] (immediate) +
//!                                           pActiveTimersByType[5][64] (scheduled ring)
//!   D2TimerStrc  (0x30)  the node: nTimerType/nFrame/pUnit/nGUID/eUnitType/fpTimerFunction
//!   EVENT_DispatchAllTimers @0x5414d0  index = dwGameFrame & 0x3f; fires 5 types in the
//!                                      order missile->player->monster->object->item
//!   SetEvent @0x5417d0  bucket = (dwGameFrame + nDelay) & 0x3f; nDelay 0 -> immediate list
//!   ExecuteTimerTrigger  the (unit, callbackType, delay) trigger MONSTER_StartAiAndRegenTimers
//!                        @0x5738d0 uses to arm AITHINK + STATREGEN at spawn (delay 0).
//!
//! This is a Zig-native model of that mechanism: same 5x64 ring, same immediate-vs-
//! scheduled split, same fire order, same fire-once / self-reschedule / remove-on-dead
//! semantics. Timer TYPES carry the real eD2TimerType values. The per-callback
//! reschedule CADENCE (how many frames AI/regen wait) lives inside each engine callback
//! and is not yet RE'd, so periodic work is armed as IMMEDIATE (every-frame) here — the
//! faithful SUPERSET of the true schedule — until each callback's cadence is ported.

const std = @import("std");

/// Unit types that carry timers, indexing the per-type arrays. eD2UnitType 0..4; tiles
/// (type 5) are passive and have no dispatcher (confirmed: EVENT_DispatchAllTimers only
/// dispatches these five).
pub const NUM_TYPES = 5;
/// Scheduled-ring bucket count. bucket = dwGameFrame & 0x3f (confirmed 0x3f mask).
pub const NUM_BUCKETS = 64;
const BUCKET_MASK: i64 = NUM_BUCKETS - 1;

/// The engine's per-frame dispatch order over unit types (EVENT_DispatchAllTimers): the
/// array is indexed by eD2UnitType, but the five types are VISITED in this order.
pub const DISPATCH_ORDER = [NUM_TYPES]u8{ 2, 0, 1, 3, 4 }; // missile, player, monster, object, item

/// eD2TimerType (1.14d /Diablo2/SERVER). One name per value (the enum has a few aliases:
/// 5=ACTIVESTATE/RESET, 7=MONUMOD/QUESTFN, 12=REMOVESTATE/UPDATETRADE).
pub const TimerType = enum(u8) {
    modechange = 0,
    endanim = 1,
    aithink = 2,
    statregen = 3,
    trap = 4,
    activestate = 5,
    freehover = 6,
    monumod = 7,
    periodicskills = 8,
    periodicstats = 9,
    aireset = 10,
    delayedportal = 11,
    removestate = 12,
    refreshvendor = 13,
    removeskillcooldown = 14,
    _,
};

/// A scheduled timer node (D2TimerStrc slice). `frame` is the absolute target frame
/// (-1 == immediate: fire every frame). `period` 0 == one-shot; >0 == reschedule
/// `period` frames after firing (the self-rescheduling callback pattern). `unit_type` is
/// eD2UnitType (0..4). The engine's fpTimerFunction is modelled by the host routing on
/// (unit_type, timer_type) in its fire callback rather than a stored pointer.
pub const Timer = struct {
    timer_type: TimerType,
    frame: i64,
    unit_guid: u32,
    unit_type: u8,
    period: u32 = 0,
    arg: i32 = 0,
};

const List = std.ArrayListUnmanaged(Timer);

/// D2TimerQueueStrc — one per hosted world (the engine keeps one per game). `immediate`
/// mirrors pTimerListByType (walked unconditionally every frame); `active` mirrors
/// pActiveTimersByType (the scheduled ring, a node fires only when frame == now).
pub const TimerQueue = struct {
    immediate: [NUM_TYPES]List = .{List.empty} ** NUM_TYPES,
    active: [NUM_TYPES][NUM_BUCKETS]List = .{.{List.empty} ** NUM_BUCKETS} ** NUM_TYPES,

    pub fn deinit(self: *TimerQueue, gpa: std.mem.Allocator) void {
        for (&self.immediate) |*l| l.deinit(gpa);
        for (&self.active) |*ring| for (ring) |*l| l.deinit(gpa);
    }

    /// SetEvent @0x5417d0 — schedule a timer for a unit. `delay` <= 0 arms it on the
    /// immediate list (fires every frame, frame = -1); `delay` > 0 places it in bucket
    /// (now + delay) & 0x3f to fire when the game frame reaches now + delay.
    pub fn setEvent(
        self: *TimerQueue,
        gpa: std.mem.Allocator,
        now: i64,
        unit_guid: u32,
        unit_type: u8,
        timer_type: TimerType,
        delay: i64,
        period: u32,
        arg: i32,
    ) !void {
        std.debug.assert(unit_type < NUM_TYPES);
        const t = Timer{
            .timer_type = timer_type,
            .frame = if (delay <= 0) -1 else now + delay,
            .unit_guid = unit_guid,
            .unit_type = unit_type,
            .period = period,
            .arg = arg,
        };
        if (delay <= 0) {
            try self.immediate[unit_type].append(gpa, t);
        } else {
            try self.active[unit_type][@intCast((now + delay) & BUCKET_MASK)].append(gpa, t);
        }
    }

    /// ExecuteTimerTrigger with delay 0 — arm a per-frame (immediate) callback. Used to
    /// mirror MONSTER_StartAiAndRegenTimers @0x5738d0 (AITHINK + STATREGEN at spawn).
    pub fn trigger(self: *TimerQueue, gpa: std.mem.Allocator, unit_guid: u32, unit_type: u8, timer_type: TimerType) !void {
        try self.setEvent(gpa, 0, unit_guid, unit_type, timer_type, 0, 0, 0);
    }

    /// EVENT_DispatchAllTimers @0x5414d0 — fire every due timer for `now`, visiting the
    /// five unit types in the engine's order. `ctx` must expose
    /// `fn fire(self, *const Timer) bool` returning whether the owning unit is still
    /// valid; a dead/absent unit's timers are dropped. A surviving periodic timer
    /// reschedules itself `period` frames out.
    pub fn dispatchAll(self: *TimerQueue, gpa: std.mem.Allocator, now: i64, ctx: anytype) void {
        for (DISPATCH_ORDER) |ut| self.dispatchType(gpa, ut, now, ctx);
    }

    fn dispatchType(self: *TimerQueue, gpa: std.mem.Allocator, ut: u8, now: i64, ctx: anytype) void {
        // Immediate list: fire every node this frame; keep it unless the unit is gone.
        var imm = &self.immediate[ut];
        var i: usize = 0;
        while (i < imm.items.len) {
            if (ctx.fire(&imm.items[i])) i += 1 else _ = imm.swapRemove(i);
        }

        // Scheduled ring: only nodes whose absolute frame == now fire (others share the
        // bucket for a different absolute frame and are left in place).
        var bl = &self.active[ut][@intCast(now & BUCKET_MASK)];
        i = 0;
        while (i < bl.items.len) {
            if (bl.items[i].frame != now) {
                i += 1;
                continue;
            }
            const fired = bl.items[i]; // copy: swapRemove invalidates the slot
            _ = bl.swapRemove(i); // do not advance; the swapped-in node is checked next
            if (ctx.fire(&fired) and fired.period > 0) {
                const next = fired.frame + @as(i64, fired.period);
                var resc = fired;
                resc.frame = next;
                self.active[ut][@intCast(next & BUCKET_MASK)].append(gpa, resc) catch {};
            }
        }
    }

    /// Live timer count (status/tests).
    pub fn count(self: *const TimerQueue) usize {
        var n: usize = 0;
        for (self.immediate) |l| n += l.items.len;
        for (self.active) |ring| for (ring) |l| {
            n += l.items.len;
        };
        return n;
    }
};

// --- tests ------------------------------------------------------------------

const TestCtx = struct {
    fires: *std.ArrayListUnmanaged(Timer),
    gpa: std.mem.Allocator,
    alive_guid: u32, // any other guid is treated as dead (its timers get dropped)
    fn fire(self: *TestCtx, t: *const Timer) bool {
        self.fires.append(self.gpa, t.*) catch {};
        return t.unit_guid == self.alive_guid;
    }
};

test "immediate timer fires every frame and drops when the unit dies" {
    const gpa = std.testing.allocator;
    var q = TimerQueue{};
    defer q.deinit(gpa);
    try q.trigger(gpa, 1, 1, .aithink); // monster (type 1) AI think

    var fires: std.ArrayListUnmanaged(Timer) = .empty;
    defer fires.deinit(gpa);
    var ctx = TestCtx{ .fires = &fires, .gpa = gpa, .alive_guid = 1 };

    q.dispatchAll(gpa, 0, &ctx);
    q.dispatchAll(gpa, 1, &ctx);
    try std.testing.expectEqual(@as(usize, 2), fires.items.len); // fired both frames
    try std.testing.expectEqual(@as(usize, 1), q.count());

    ctx.alive_guid = 999; // unit now "dead" -> timer dropped after firing
    q.dispatchAll(gpa, 2, &ctx);
    try std.testing.expectEqual(@as(usize, 0), q.count());
}

test "scheduled timer fires on its target frame and reschedules by period" {
    const gpa = std.testing.allocator;
    var q = TimerQueue{};
    defer q.deinit(gpa);
    // Arm at now=0 with delay 100 (> ring size, exercising the frame==now guard) and a
    // 10-frame period. Bucket = 100 & 0x3f = 36.
    try q.setEvent(gpa, 0, 7, 1, .statregen, 100, 10, 0);

    var fires: std.ArrayListUnmanaged(Timer) = .empty;
    defer fires.deinit(gpa);
    var ctx = TestCtx{ .fires = &fires, .gpa = gpa, .alive_guid = 7 };

    // Visiting bucket 36 at frame 36 must NOT fire (target is frame 100).
    q.dispatchAll(gpa, 36, &ctx);
    try std.testing.expectEqual(@as(usize, 0), fires.items.len);
    // Fires exactly at frame 100, then reschedules to 110.
    q.dispatchAll(gpa, 100, &ctx);
    try std.testing.expectEqual(@as(usize, 1), fires.items.len);
    q.dispatchAll(gpa, 110, &ctx);
    try std.testing.expectEqual(@as(usize, 2), fires.items.len);
}
