//! Timed skill buffs (states) — the DURATION + STACKING layer over the flat StatList. A buff like
//! Battle Orders / Shout / Frozen Armor / Enchant grants stats for a limited time and does NOT stack
//! on itself: recasting REFRESHES the timer and re-applies its (possibly higher, at a new level)
//! stats rather than adding a second copy. When a buff's timer runs out its stat contributions are
//! removed. This mirrors D2's per-state stat sublists (D2StatListEx): the unit's StatList carries
//! base + the sum of active buffs; set/clear a state -> add/remove that state's stat deltas.
//!
//! The host drives it: call `apply` on cast (with the buff's duration in server frames — from the
//! skill's aura-length calc) and `tick` each frame; read the unit's StatList for the live totals.

const std = @import("std");
const Unit = @import("unit.zig").Unit;
const skillmod = @import("skill.zig");
const d2data = @import("d2-data");

pub const MAX_BUFF_STATS = 8; // aurastat1..6 + headroom
pub const MAX_BUFFS = 16; // distinct simultaneous buffs on one unit

const StatDelta = struct { id: u16, value: i32 };

/// One active timed buff: which skill granted it, how many frames remain, and the exact stat deltas
/// it added (kept so they can be subtracted on expiry / refresh).
pub const Buff = struct {
    skill_id: u16 = 0,
    remaining: i32 = 0,
    deltas: [MAX_BUFF_STATS]StatDelta = undefined,
    n: usize = 0,
    active: bool = false,
};

pub const BuffList = struct {
    buffs: [MAX_BUFFS]Buff = [_]Buff{.{}} ** MAX_BUFFS,

    /// Apply (or REFRESH) a buff on `u`: remove any live copy of the same skill first (so it never
    /// double-stacks), evaluate the skill's aurastat1..6 into stat deltas, add them to `u`'s
    /// StatList, and record the buff for `duration_frames`. `duration_frames <= 0` just clears it.
    pub fn apply(self: *BuffList, u: *Unit, skills: *const skillmod.Skills, isc: *const d2data.Table, skill_id: u16, level: i32, duration_frames: i32) void {
        self.remove(u, skill_id); // refresh semantics: drop the old copy before re-adding
        if (duration_frames <= 0) return;
        const slot = self.freeSlot() orelse return;
        var b = Buff{ .skill_id = skill_id, .remaining = duration_frames, .active = true };
        b.n = gatherAuraStats(skills, isc, skill_id, level, &b.deltas);
        for (b.deltas[0..b.n]) |d| u.stats.add(@enumFromInt(d.id), d.value);
        self.buffs[slot] = b;
    }

    /// Advance every buff by `frames`; a buff whose timer reaches 0 is removed and its stat deltas
    /// subtracted from `u`. Call once per server frame (or with the elapsed frame count).
    pub fn tick(self: *BuffList, u: *Unit, frames: i32) void {
        for (&self.buffs) |*b| {
            if (!b.active) continue;
            b.remaining -= frames;
            if (b.remaining <= 0) self.deactivate(u, b);
        }
    }

    /// Remove a specific skill's buff from `u` right now (e.g. it was dispelled), subtracting its
    /// stats. No-op if that skill isn't active.
    pub fn remove(self: *BuffList, u: *Unit, skill_id: u16) void {
        for (&self.buffs) |*b| {
            if (b.active and b.skill_id == skill_id) self.deactivate(u, b);
        }
    }

    /// Whether a skill's buff is currently active (its timer hasn't run out).
    pub fn isActive(self: *const BuffList, skill_id: u16) bool {
        for (self.buffs) |b| {
            if (b.active and b.skill_id == skill_id) return true;
        }
        return false;
    }

    fn deactivate(self: *BuffList, u: *Unit, b: *Buff) void {
        _ = self;
        for (b.deltas[0..b.n]) |d| u.stats.add(@enumFromInt(d.id), -d.value); // subtract the granted stats
        b.active = false;
        b.n = 0;
    }

    fn freeSlot(self: *BuffList) ?usize {
        for (self.buffs, 0..) |b, i| {
            if (!b.active) return i;
        }
        return null;
    }
};

/// Evaluate a skill's aurastat1..6 into (stat id, value) deltas (the same stats applyAuraTo grants,
/// captured so a buff can later remove them). Returns the count.
fn gatherAuraStats(skills: *const skillmod.Skills, isc: *const d2data.Table, skill_id: u16, level: i32, out: *[MAX_BUFF_STATS]StatDelta) usize {
    const row = skills.rowById(skill_id) orelse return 0;
    var n: usize = 0;
    inline for (1..7) |slot| {
        const stat_col = std.fmt.comptimePrint("aurastat{d}", .{slot});
        const calc_col = std.fmt.comptimePrint("aurastatcalc{d}", .{slot});
        const stat = skills.table.get(row, stat_col);
        if (stat.len != 0 and n < out.len) {
            if (skillmod.statIdByName(isc, stat)) |sid| {
                out[n] = .{ .id = sid, .value = skills.evalCalc(.{}, 0, skill_id, level, calc_col) };
                n += 1;
            }
        }
    }
    return n;
}

const testing = std.testing;

test "a buff grants its stats, refreshes without double-stacking, and expires" {
    var s = try skillmod.Skills.load(testing.allocator);
    defer s.deinit();
    var isc = try d2data.open(testing.allocator, "ItemStatCost");
    defer isc.deinit();

    var u = Unit.init(.player);
    var bl = BuffList{};
    const bo = s.idByName("Battle Orders").?;
    const hpid: u16 = skillmod.statIdByName(&isc, "item_maxhp_percent").?;

    // Cast Battle Orders (100-frame duration): grants +life%.
    bl.apply(&u, &s, &isc, bo, 10, 100);
    const once = u.stats.get(@enumFromInt(hpid));
    try testing.expect(once > 0);
    try testing.expect(bl.isActive(bo));

    // Recast BEFORE it expires: refreshes, does NOT double the bonus (still `once`, not 2x).
    bl.apply(&u, &s, &isc, bo, 10, 100);
    try testing.expectEqual(once, u.stats.get(@enumFromInt(hpid)));

    // Tick past the duration: the buff expires and its stat is removed.
    bl.tick(&u, 60);
    try testing.expect(bl.isActive(bo)); // still 40 frames left
    bl.tick(&u, 60);
    try testing.expect(!bl.isActive(bo)); // expired
    try testing.expectEqual(@as(i32, 0), u.stats.get(@enumFromInt(hpid))); // stat gone
}
