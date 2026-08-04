//! The runtime, MUTABLE world state of one hosted level — distinct from world.zig, which GENERATES a
//! level's static layout. `LevelState` owns everything that lives and changes in a level while players
//! are in it: the units + their AI/timers/regen, the transient combat overlays (poison DoTs, curses,
//! aura debuffs, ground effects, fear/freeze/chill markers, corpses), and the placed warps/objects/
//! ground items. It is pure game state + the small queries over it; the per-tick LOGIC that mutates it
//! lives with the host for now and migrates here piece by piece.

const std = @import("std");
const unit = @import("unit.zig");
const missile = @import("missile.zig");
const ai = @import("ai.zig");
const world = @import("world.zig");
const events = @import("events.zig");
const skill = @import("skill.zig");
const select = @import("select.zig");
const rng = @import("rng.zig");
const buff = @import("buff.zig");
const shrines = @import("shrines.zig");
const spell = @import("spell.zig");
const items = @import("d2-item");

const Unit = unit.Unit;
const MonsterAI = ai.MonsterAI;

pub const MoveTarget = struct { x: i32, y: i32 };

pub const GroundItem = struct {
    guid: u32,
    x: i32,
    y: i32,
    code: [4]u8 = .{ 0, 0, 0, 0 },
    is_gold: bool = false,
    /// Gold amount (is_gold) / stack count — the d2-item Drop.quantity roll.
    quantity: i32 = 0,
    /// Absolute game frame this item expires (FreeUnusedItems removes it once reached).
    /// 0 == persist — the normal case for a dropped item (engine field nLinkedPortalY).
    expire_frame: u64 = 0,
    /// The rolled item identity (quality + affix/unique/set ids + mod seed) so its stats survive the
    /// drop -> pickup -> equip path. Default `.invalid`/0 for gold and code-only spawns.
    drop: items.Drop = .{},
};

/// One outgoing inter-level warp instantiated in a level: a clickable AssignLevelWarp unit
/// at (x,y) whose interaction transitions the player to `dest_level`. `class_id` carries
/// the Levels.txt warp type. Adjacency (dest) comes from the real Vis/Warp graph.
pub const Warp = struct {
    guid: u32,
    class_id: u8,
    x: i32,
    y: i32,
    dest_level: u16,
};

/// One seeded world object (shrine / chest / well / door / waypoint) placed in a level:
/// a CreateObject entity at (x,y) with its Objects.txt `class_id`. Distinct from living
/// units — objects don't fight, path or die — so they live in their own list like warps.
/// `operate_fn` selects the interact behaviour (OBJECTSOPERATEFN index); `anim_mode` is
/// the live eD2ObjectAnimMode (0 Neutral, 1 Operating, 2 Opened, 3-7 Special) broadcast
/// via ObjectState 0x0E on change. Timer-driven machines (trap arm, day/night) are TODO.
pub const WorldObject = struct {
    guid: u32,
    class_id: i32,
    x: i32,
    y: i32,
    operate_fn: i32 = 0,
    anim_mode: u8 = 0,
    /// For shrine objects: the Shrines.txt function rolled once at spawn (flat-uniform, gated
    /// by LevelMin — see shrines.Table.pick) and the effect it grants on operate. `.none`
    /// for non-shrines / unassigned. `shrine_reset_min` is that row's re-enable delay.
    shrine_effect: shrines.Effect = .none,
    shrine_reset_min: i32 = 0,
    /// Last game frame this object was operated — the door anti-spam debounce reads it (the engine
    /// gates OBJOP_ToggleDoor on GetTickCount, 500ms; we track the frame equivalent).
    last_op_frame: u64 = 0,
};

/// Per-frame sub-missile emitter (Frozen Orb / Blizzard / Hydra), keyed by the parent missile's guid.
pub const EmitterState = struct {
    func: i32 = 15, // pSrvDoFunc: 15 = rotating single ring shot (Frozen Orb); 10 = N random area shots (Blizzard/Hydra)
    interval: i32,
    rotate: i32 = 0, // func 15: ring-angle step per shot
    count: i32 = 1, // func 10: sub-missiles per pulse
    radius: i32 = 8, // func 10: random spawn footprint
    angle: i32 = 0,
    owner: u32,
    cast: spell.Cast,
    sub: [24]u8 = [_]u8{0} ** 24,
    sub_len: u8 = 0,
    pub fn subName(self: *const EmitterState) []const u8 {
        return self.sub[0..self.sub_len];
    }
};

/// A persistent ground AoE (Fire Wall / Blaze / Blizzard): pulses its skill's staged elemental damage
/// each frame to hostile monsters within `radius` of (x,y) until `end_frame`.
pub const GroundEffect = struct {
    skill_id: u16,
    level: i32,
    x: i32,
    y: i32,
    radius: i32,
    end_frame: u64,
};

/// A single hosted level's live world state. Owned by the host's `levels` map.
pub const LevelState = struct {
    level_id: u16,
    summary: world.LevelSummary,
    entry_x: i32,
    entry_y: i32,
    path_grid: ?world.PathGrid = null,

    units: std.AutoHashMapUnmanaged(u32, Unit) = .empty,
    targets: std.AutoHashMapUnmanaged(u32, MoveTarget) = .empty,
    moved: std.AutoHashMapUnmanaged(u32, void) = .empty,
    ai: std.AutoHashMapUnmanaged(u32, MonsterAI) = .empty,
    /// Per-unit fractional life-regen accumulator (<<8): the engine keeps hitpoints in
    /// 1/256 fixed point and adds the small hpregen delta each frame; our units track
    /// whole HP, so we bank the sub-1 remainder here and add a whole HP when it overflows.
    regen_acc: std.AutoHashMapUnmanaged(u32, i32) = .empty,
    /// Active poison damage-over-time per unit (guid -> remaining PoisonDot). A poison hit registers
    /// its resisted total spread over the skill's ELen; tickPoison deals per_frame each frame and
    /// drops the entry at 0. Re-poisoning refreshes (overwrites), not stacks — faithful to D2.
    poison_dots: std.AutoHashMapUnmanaged(u32, skill.PoisonDot) = .empty,
    /// Active Necromancer curse per enemy unit (guid -> the curse's stat debuffs as a one-slot buff
    /// list). A curse applies its aurastat debuff for auralencalc frames; recasting replaces it (one
    /// curse per unit). tickCurses counts it down and lifts the debuff on expiry.
    curses: std.AutoHashMapUnmanaged(u32, buff.BuffList) = .empty,
    /// Enemy-aura debuffs currently on hostile monsters (guid -> the aura's stat penalties as a
    /// one-slot buff list) — e.g. Conviction dropping a monster's resistances. Re-applied each frame to
    /// units in the aura's range and lapses ~2 frames after they leave it or the aura stops.
    aura_debuffs: std.AutoHashMapUnmanaged(u32, buff.BuffList) = .empty,
    /// Active persistent ground effects (Fire Wall / Blaze / Blizzard): each pulses its skill's staged
    /// elemental damage to every hostile monster within `radius` of (x,y) EVERY frame (recon: the effect
    /// missile has NextDelay 0, so it re-hits overlapping units each frame) until `end_frame`. Duration
    /// = the damage missile's Range (firewall/blaze 90f, blizzardcenter 100f).
    ground_effects: std.ArrayListUnmanaged(GroundEffect) = .empty,
    /// Per-frame sub-missile emitters (Frozen Orb), keyed by the parent orb missile's guid.
    emitters: std.AutoHashMapUnmanaged(u32, EmitterState) = .empty,
    /// Guids of STATIONARY pets — Assassin trap sentries (Lightning/Death/Inferno/... Sentry). They
    /// spawn as summons (their sentry monster carries the fire skill) but, unlike a following pet, they
    /// never move: they just fire their skill at any hostile monster that comes into cast range.
    stationary: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Monsters currently FEARED (guid -> end_frame). A feared monster flees directly away from the
    /// nearest player instead of attacking, until its timer runs out. Applied by Grim Ward / Howl / the
    /// Terror curse.
    feared: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Monsters currently FROZEN (guid -> end_frame) — cannot act (no move/attack) until it thaws.
    /// Applied by e.g. Blades of Ice at charge 3 (dwFrzLength = coldLength/Param4).
    frozen: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Teleport cooldown (guid -> earliest next-teleport frame) for the blinking bosses (Mephisto / Baal)
    /// so they don't warp to the target every single think.
    boss_teleport_cd: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Per-monster skill-rotation cursor (guid -> next skill offset). A multi-skill caster (act bosses,
    /// Succubus, ...) advances this each cast so it cycles through all its damaging skills instead of
    /// spamming the first one.
    cast_rotation: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    /// Units currently CHILLED (guid -> end_frame) by a slowing aura (Duriel Holy Freeze). A chilled
    /// unit moves at a reduced step until the marker lapses; it is re-stamped each think it stays in range.
    chilled: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Burrowers (guid -> phase-change frame). Paired with Unit.submerged: while submerged, the frame is
    /// when it surfaces; while surfaced, when it next dives. Drives the SandRaider emerge-ambush cycle.
    burrow_until: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    /// Dead monsters held as CORPSES (guid -> remaining frames) so corpse-consuming skills (Corpse
    /// Explosion / Poison Explosion / Revive) can target them. A fresh death rolls its drops once, then
    /// lingers here; sweepDeaths reaps it at 0 (or when a skill consumes it). The unit stays in `units`
    /// as a dead body (isAlive() false, so it never interferes with live targeting/collision).
    corpses: std.AutoHashMapUnmanaged(u32, i32) = .empty,
    /// Last hp% (128-scale) broadcast for each monster (UNITSTAT_last_sent_hp_pct, seeded
    /// 0x80); a fresh 0xAB goes out when the live hp% moves more than 4 from it.
    hp_pct_sent: std.AutoHashMapUnmanaged(u32, u8) = .empty,
    ground_items: std.ArrayListUnmanaged(GroundItem) = .empty,
    missiles: std.ArrayListUnmanaged(missile.Missile) = .empty,
    warps: std.ArrayListUnmanaged(Warp) = .empty,
    objects: std.ArrayListUnmanaged(WorldObject) = .empty,
    /// GUIDs of units that are interactable town NPCs (a subset of `units`, all monster-type).
    /// They emit as normal monsters for visibility but have no AI armed and, on interact,
    /// open the NPC menu instead of a warp/object operate.
    npcs: std.AutoHashMapUnmanaged(u32, void) = .empty,

    /// Game frame this level last went player-empty (0 = a player is present / never emptied). FreeDungeons
    /// frees the level once it has been empty past the idle timeout (nActiveCount==0 in the engine); the
    /// layout regenerates from the seed on re-entry.
    empty_since: u64 = 0,

    /// Baal Throne-of-Destruction wave cursor: the next of the 5 minion waves to spawn (0..5); 5 = all
    /// waves done. Only meaningful on the Throne level. `baal_spawned` gates the final Baal appearance.
    baal_wave: u8 = 0,
    baal_spawned: bool = false,

    /// This level's per-unit timer queue (D2TimerQueueStrc; one per game in the engine,
    /// per level here since units are level-scoped). Monster AI/regen are scheduled here;
    /// player/object/item callbacks migrate here as they are ported.
    timers: events.TimerQueue = .{},

    pub fn deinit(self: *LevelState, gpa: std.mem.Allocator) void {
        self.units.deinit(gpa);
        self.targets.deinit(gpa);
        self.moved.deinit(gpa);
        self.ai.deinit(gpa);
        self.regen_acc.deinit(gpa);
        self.hp_pct_sent.deinit(gpa);
        self.poison_dots.deinit(gpa);
        self.curses.deinit(gpa);
        self.aura_debuffs.deinit(gpa);
        self.ground_effects.deinit(gpa);
        self.emitters.deinit(gpa);
        self.stationary.deinit(gpa);
        self.feared.deinit(gpa);
        self.frozen.deinit(gpa);
        self.boss_teleport_cd.deinit(gpa);
        self.cast_rotation.deinit(gpa);
        self.chilled.deinit(gpa);
        self.burrow_until.deinit(gpa);
        self.corpses.deinit(gpa);
        self.ground_items.deinit(gpa);
        self.missiles.deinit(gpa);
        self.warps.deinit(gpa);
        self.objects.deinit(gpa);
        self.npcs.deinit(gpa);
        self.timers.deinit(gpa);
        if (self.path_grid) |*pg| pg.deinit(gpa);
        self.summary.deinit(gpa);
    }

    pub fn monsterCount(self: *const LevelState) u32 {
        var n: u32 = 0;
        var it = self.units.valueIterator();
        while (it.next()) |u| {
            if (u.unit_type == .monster) n += 1;
        }
        return n;
    }

    /// Advance active poison DoTs one frame: deal per_frame to each poisoned unit and drop entries
    /// whose unit died or whose duration ran out. Re-poisoning refreshes (overwrites), not stacks.
    pub fn tickPoison(self: *LevelState) void {
        var expired: [128]u32 = undefined;
        var ne: usize = 0;
        var it = self.poison_dots.iterator();
        while (it.next()) |e| {
            const guid = e.key_ptr.*;
            const dot = e.value_ptr;
            const u = self.units.getPtr(guid);
            if (u == null or !u.?.isAlive()) {
                if (ne < expired.len) {
                    expired[ne] = guid;
                    ne += 1;
                }
                continue;
            }
            u.?.setLife(@max(0, u.?.life() - dot.per_frame));
            dot.frames -= 1;
            if (dot.frames <= 0 and ne < expired.len) {
                expired[ne] = guid;
                ne += 1;
            }
        }
        for (expired[0..ne]) |g| _ = self.poison_dots.remove(g);
    }

    /// Advance active curses one frame: BuffList.tick counts each down and lifts its stat debuff on
    /// expiry; the entry is dropped once nothing is active or the cursed unit is gone.
    pub fn tickCurses(self: *LevelState) void {
        var expired: [128]u32 = undefined;
        var ne: usize = 0;
        var it = self.curses.iterator();
        while (it.next()) |e| {
            const guid = e.key_ptr.*;
            if (self.units.getPtr(guid)) |u| {
                e.value_ptr.tick(u, 1);
                if (!e.value_ptr.anyActive() and ne < expired.len) {
                    expired[ne] = guid;
                    ne += 1;
                }
            } else if (ne < expired.len) {
                expired[ne] = guid;
                ne += 1;
            }
        }
        for (expired[0..ne]) |g| _ = self.curses.remove(g);
    }

    /// Pulse every active ground effect one frame: deal its skill's staged elemental damage to hostile
    /// monsters within radius of its centre (castDirectAreaElemental, replicating the engine's per-frame
    /// re-hit) and reap it once past end_frame. `frame` is the current game tick; `seed` drives the
    /// damage rolls; `gpa` backs a scratch target list.
    pub fn tickGroundEffects(self: *LevelState, skills: *const skill.Skills, seed: *rng.Seed, frame: u64, gpa: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.ground_effects.items.len) {
            const ge = self.ground_effects.items[i];
            if (frame >= ge.end_frame) {
                _ = self.ground_effects.swapRemove(i);
                continue;
            }
            var tgts: std.ArrayListUnmanaged(*Unit) = .empty;
            defer tgts.deinit(gpa);
            var it = self.units.valueIterator();
            while (it.next()) |u| {
                if (select.isHostileMonster(u)) tgts.append(gpa, u) catch {};
            }
            _ = skill.castDirectAreaElemental(skills, .{}, ge.skill_id, ge.level, ge.x, ge.y, ge.radius, tgts.items, seed);
            i += 1;
        }
    }
};

/// A bare LevelState for unit tests — no generated layout, just the empty maps + a stub summary.
fn emptyLevelState() LevelState {
    return .{
        .level_id = 0,
        .summary = .{ .level_id = 0, .seed = 0, .difficulty = .normal, .room_count = 0, .tile_count = 0, .collision_cells = 0 },
        .entry_x = 0,
        .entry_y = 0,
    };
}

test "tickPoison deals per_frame each frame and drops the DoT when its duration runs out" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var ls = emptyLevelState();
    defer ls.deinit(gpa);

    var mon = Unit.init(.monster);
    mon.setLife(100);
    try ls.units.put(gpa, 1, mon);
    try ls.poison_dots.put(gpa, 1, .{ .total = 10, .frames = 2, .per_frame = 5 });

    ls.tickPoison();
    try testing.expectEqual(@as(i32, 95), ls.units.getPtr(1).?.life());
    try testing.expect(ls.poison_dots.contains(1)); // one frame still to go

    ls.tickPoison();
    try testing.expectEqual(@as(i32, 90), ls.units.getPtr(1).?.life());
    try testing.expect(!ls.poison_dots.contains(1)); // expired -> reaped
}

test "tickPoison reaps the DoT when its target dies" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var ls = emptyLevelState();
    defer ls.deinit(gpa);

    var mon = Unit.init(.monster);
    mon.setLife(0); // already dead
    try ls.units.put(gpa, 7, mon);
    try ls.poison_dots.put(gpa, 7, .{ .total = 30, .frames = 10, .per_frame = 3 });

    ls.tickPoison();
    try testing.expect(!ls.poison_dots.contains(7)); // dead unit -> DoT dropped, no negative life
}
