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

/// Owns the ItemStatCost table a BuffList needs, so a host can drive buffs without importing d2-data.
/// Load once, keep on the game instance, deinit at teardown.
pub const BuffContext = struct {
    isc: d2data.Table,

    pub fn load(gpa: std.mem.Allocator) !BuffContext {
        return .{ .isc = try d2data.open(gpa, "ItemStatCost") };
    }
    pub fn deinit(self: *BuffContext) void {
        self.isc.deinit();
    }
    /// Cast a timed buff on `u`, deriving its duration from the skill (see BuffList.applySkill).
    pub fn cast(self: *const BuffContext, list: *BuffList, u: *Unit, skills: *const skillmod.Skills, book: skillmod.SkillBook, skill_id: u16, level: i32) void {
        list.applySkill(u, skills, &self.isc, book, skill_id, level);
    }
};

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

    /// Cast a timed buff on `u`, deriving its duration from the skill's own aura-length calc — fully
    /// table-driven, no host-supplied duration. `book` provides the levels the duration calc reads
    /// (Battle Orders' length synergises off Shout / Battle Command).
    pub fn applySkill(self: *BuffList, u: *Unit, skills: *const skillmod.Skills, isc: *const d2data.Table, book: skillmod.SkillBook, skill_id: u16, level: i32) void {
        self.apply(u, skills, isc, skill_id, level, buffDuration(skills, book, skill_id, level));
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

    /// Remove EVERY active buff from `u` (subtracting all their stats) and empty the list. Used to
    /// enforce single-curse-per-unit: clear the old curse before applying a new one.
    pub fn clearAll(self: *BuffList, u: *Unit) void {
        for (&self.buffs) |*b| {
            if (b.active) self.deactivate(u, b);
        }
    }

    /// Whether ANY buff is still active (used to reap an empty per-unit curse list).
    pub fn anyActive(self: *const BuffList) bool {
        for (self.buffs) |b| {
            if (b.active) return true;
        }
        return false;
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

/// Whether a skill is a TIMED self/party buff — a state that grants stats for a finite length — as
/// opposed to a permanent aura, an instant cast, or a passive. True when it has an `aurastate`, a
/// non-empty `auralencalc` (finite duration) and at least one `aurastat`. Drive these with applySkill;
/// masteries/permanent passives use skill.applyPassives instead. Covers Enchant, Frozen/Shiver/
/// Chilling Armor, Holy Shield, the warcries (BO/Shout/Battle Command), Enchant, etc. across classes.
pub fn isTimedBuff(skills: *const skillmod.Skills, skill_id: u16) bool {
    const row = skills.rowById(skill_id) orelse return false;
    if (skills.table.get(row, "aurastate").len == 0) return false;
    if (skills.table.get(row, "auralencalc").len == 0) return false;
    return skills.table.get(row, "aurastat1").len != 0;
}

/// A timed buff's duration in FRAMES (D2 aura length is 1/25s frames) for (skill, level), from the
/// skill's `auralencalc` — Battle Orders ln12 + synergy off Shout/Battle Command (BO slvl1 = 750 +
/// 1*250 = 1000 frames = 40s, growing per level). `book` supplies the synergy skill levels. 0 for a
/// permanent aura / a non-timed skill.
pub fn buffDuration(skills: *const skillmod.Skills, book: skillmod.SkillBook, skill_id: u16, level: i32) i32 {
    return skills.evalCalc(book, 0, skill_id, level, "auralencalc");
}

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

test "the timed-buff category works across classes via applySkill (Enchant/Frozen Armor/Holy Shield/Shout)" {
    var s = try skillmod.Skills.load(testing.allocator);
    defer s.deinit();
    var isc = try d2data.open(testing.allocator, "ItemStatCost");
    defer isc.deinit();

    // Each is a timed buff granting a stat that BuffList applies + expires — one generic path.
    const cases = .{
        .{ "Enchant", "firemindam" }, // Sorceress: +fire damage to attacks
        .{ "Frozen Armor", "skill_armor_percent" }, // Sorceress: +defense
        .{ "Holy Shield", "toblock" }, // Paladin: +block%
        .{ "Shout", "skill_armor_percent" }, // Barbarian: +defense
    };
    inline for (cases) |c| {
        const id = s.idByName(c[0]).?;
        try testing.expect(isTimedBuff(&s, id));
        var u = Unit.init(.player);
        var bl = BuffList{};
        var book = skillmod.SkillBook{};
        book.setByName(&s, c[0], 10);
        bl.applySkill(&u, &s, &isc, book, id, 10);
        const sid: u16 = skillmod.statIdByName(&isc, c[1]).?;
        try testing.expect(u.stats.get(@enumFromInt(sid)) > 0); // buff granted its stat
        try testing.expect(bl.isActive(id));
        bl.tick(&u, 1_000_000); // long past any duration
        try testing.expect(!bl.isActive(id)); // expired
        try testing.expectEqual(@as(i32, 0), u.stats.get(@enumFromInt(sid))); // stat removed
    }
    // An instant skill (Ice Bolt) is NOT a timed buff.
    try testing.expect(!isTimedBuff(&s, s.idByName("Ice Bolt").?));
}

test "buff duration is table-driven from auralencalc (Battle Orders slvl1 = 1000 frames)" {
    var s = try skillmod.Skills.load(testing.allocator);
    defer s.deinit();
    var isc = try d2data.open(testing.allocator, "ItemStatCost");
    defer isc.deinit();
    const bo = s.idByName("Battle Orders").?;

    // With no synergy skills (Shout / Battle Command at 0), BO length = ln12 = 750 + 1*250 = 1000.
    var book = skillmod.SkillBook{};
    book.setByName(&s, "Battle Orders", 1);
    try testing.expectEqual(@as(i32, 1000), buffDuration(&s, book, bo, 1));
    try testing.expectEqual(@as(i32, 3250), buffDuration(&s, book, bo, 10)); // 750 + 10*250

    // applySkill derives the duration itself; the buff stays active within it and drops after.
    var u = Unit.init(.player);
    var bl = BuffList{};
    bl.applySkill(&u, &s, &isc, book, bo, 1);
    try testing.expect(bl.isActive(bo));
    bl.tick(&u, 999);
    try testing.expect(bl.isActive(bo)); // 1 frame left
    bl.tick(&u, 1);
    try testing.expect(!bl.isActive(bo)); // exactly expired at 1000
}
