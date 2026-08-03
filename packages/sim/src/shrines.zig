//! Faithful port of the D2 1.14d shrine system (Shrines.txt + OBJOP_ActivateShrine
//! @0x583c70). A shrine world object is spawned "unassigned"; the engine rolls its
//! concrete Shrines.txt function once (weighted by `rarity`, gated by `LevelMin` vs the
//! area level), then applies that function's effect when a player operates it and schedules
//! a re-enable `reset time in minutes` later. This module is the pure decision core: the
//! host owns the object list, the player stats and the event timer.
//!
//! Column names match the 1.14d Shrines.txt header verbatim.

const std = @import("std");
const txt = @import("txt.zig");
const d2data = @import("d2-data");
const core = @import("d2-core");

/// Frames per real-world minute at the 25fps server tick (1200 = 0x4b0). The reset timer is
/// `reset time in minutes` * FRAMES_PER_MINUTE frames.
pub const FRAMES_PER_MINUTE: u32 = 1200;

/// Coarse routing of a shrine function, taken from the `effectclass` column: what SUBSYSTEM
/// applies the effect. 1 = special/scripted (portal, gem upgrade, monster morph, ...),
/// 2 = health pool, 3 = mana pool, 4 = timed stat boost. Refill (both pools) is tagged 4 in
/// the table but is a pure instant restore, so we classify it by name below.
pub const EffectClass = enum(u8) {
    special = 1,
    health = 2,
    mana = 3,
    boost = 4,
    _,
};

/// The concrete shrine effects this port resolves. Everything not yet ported maps to
/// `.unhandled` so the host can broadcast the Operating animation without a wrong stat write.
pub const Effect = enum {
    none,
    refill, // Recharge/Refill: instantly top current life + mana to max.
    unhandled,
};

pub const Row = struct {
    /// Shrines.txt `Code` — the object family this function belongs to (0 = None).
    code: i64,
    arg0: i64,
    arg1: i64,
    duration_frames: i64,
    reset_minutes: i64,
    rarity: i64,
    effectclass: EffectClass,
    level_min: i64,
    name: []const u8,
    effect: Effect,
};

pub const Table = struct {
    raw: txt.Table,
    rows: []Row,
    arena: std.heap.ArenaAllocator,

    pub fn load(gpa: std.mem.Allocator) !Table {
        var raw = try txt.Table.parse(gpa, d2data.file("Shrines"));
        errdefer raw.deinit();
        var arena = std.heap.ArenaAllocator.init(gpa);
        const a = arena.allocator();

        var list: std.ArrayListUnmanaged(Row) = .empty;
        for (0..raw.rowCount()) |i| {
            const name = raw.str(i, "Shrine name");
            const ec: EffectClass = @enumFromInt(@as(u8, @intCast(std.math.clamp(raw.int(i, "effectclass"), 0, 255))));
            try list.append(a, .{
                .code = raw.int(i, "Code"),
                .arg0 = raw.int(i, "Arg0"),
                .arg1 = raw.int(i, "Arg1"),
                .duration_frames = raw.int(i, "Duration in frames"),
                .reset_minutes = raw.int(i, "reset time in minutes"),
                .rarity = raw.int(i, "rarity"),
                .effectclass = ec,
                .level_min = raw.int(i, "LevelMin"),
                .name = try a.dupe(u8, name),
                .effect = classify(name),
            });
        }
        return .{ .raw = raw, .rows = try list.toOwnedSlice(a), .arena = arena };
    }

    pub fn deinit(self: *Table) void {
        self.raw.deinit();
        self.arena.deinit();
    }

    /// Roll a concrete shrine function for a freshly spawned shrine object, gated to the area
    /// level. Faithful to OBJECT_SelectRandomShrineType (@0x54f770) / Objects_InitFn01
    /// (@0x54f9d0): selection is FLAT-UNIFORM (no rarity weighting) over the candidate rows,
    /// retried up to 8 times until the rolled row satisfies `LevelMin <= area_level`. `cat` is
    /// the shrine object's category (from Objects.txt Parm): `.any` draws from every row
    /// [1..count), otherwise only rows whose `effectclass` equals the category. Returns the row
    /// index into `self.rows`, or null when 8 rolls all miss the LevelMin gate.
    pub const Category = union(enum) { any, class: EffectClass };

    pub fn pick(self: *const Table, seed: *core.rng.Seed, cat: Category, area_level: i64) ?usize {
        // Candidate index range: skip row 0 (the "None" record), like the engine's 1..count.
        const lo: usize = 1;
        const hi: usize = self.rows.len;
        if (hi <= lo) return null;
        const span: u32 = @intCast(hi - lo);
        var tries: u8 = 0;
        while (tries < 8) : (tries += 1) {
            const idx = lo + @as(usize, seed.pick(span));
            const r = self.rows[idx];
            const in_cat = switch (cat) {
                .any => true,
                .class => |c| r.effectclass == c,
            };
            if (in_cat and r.level_min <= area_level) return idx;
        }
        return null;
    }
};

/// Map an Objects.txt shrine Parm to its selection category, faithful to Objects_InitFn01
/// (@0x54f9d0): Parm 0 = draw from anything; 1 -> health(2); 2 -> mana(3); >=3 -> boost(4),
/// except a 1-in-10 seed roll diverts to the special/magic pool(1). Consumes one roll only on
/// the Parm>=3 path so the seed advances exactly as the engine's does.
pub fn categoryForParm(seed: *core.rng.Seed, parm: i64) Table.Category {
    return switch (parm) {
        0 => .any,
        1 => .{ .class = .health },
        2 => .{ .class = .mana },
        else => if (seed.pick(10) == 0) .{ .class = .special } else .{ .class = .boost },
    };
}

/// Frames until a shrine re-enables after activation, faithful to OBJOP_ActivateShrine
/// (@0x583c70): `nResetTimeInMins * 1200 + 1`. Zero reset minutes => never re-enables (0).
pub fn resetDelayFrames(reset_minutes: i64) u32 {
    if (reset_minutes <= 0) return 0;
    return @intCast(reset_minutes * FRAMES_PER_MINUTE + 1);
}

fn classify(name: []const u8) Effect {
    if (name.len == 0 or std.mem.eql(u8, name, "None")) return .none;
    if (std.mem.eql(u8, name, "Refill")) return .refill;
    return .unhandled;
}

/// The stat writes a shrine operation grants. The host reads the player's current/max life
/// and mana and applies the returned target values. `null` fields mean "leave unchanged".
pub const Grant = struct {
    life: ?i32 = null,
    mana: ?i32 = null,
};

/// Resolve what operating shrine `effect` grants a player with the given max pools. Only the
/// instant-restore effects are ported here; timed boosts and scripted specials return an empty
/// grant (the host still plays the Operating animation).
///
/// Refill (Shrines_RefillFunction @0x5828e0) adds the deficit `max - current` to hitpoints and
/// mana — i.e. tops both pools to max. It ignores Arg0/Arg1 entirely (confirmed in the disasm).
pub fn grantFor(effect: Effect, max_life: i32, max_mana: i32) Grant {
    return switch (effect) {
        .refill => .{ .life = max_life, .mana = max_mana },
        else => .{},
    };
}

const testing = std.testing;

test "load Shrines.txt and classify Refill" {
    var t = try Table.load(testing.allocator);
    defer t.deinit();
    try testing.expect(t.rows.len > 20);
    // Refill is Code 1, effectclass 4, and the one pure full-restore.
    var found = false;
    for (t.rows) |r| {
        if (std.mem.eql(u8, r.name, "Refill")) {
            found = true;
            try testing.expectEqual(@as(i64, 1), r.code);
            try testing.expectEqual(Effect.refill, r.effect);
        }
    }
    try testing.expect(found);
}

test "Refill grant tops both pools to max" {
    const g = grantFor(.refill, 500, 200);
    try testing.expectEqual(@as(?i32, 500), g.life);
    try testing.expectEqual(@as(?i32, 200), g.mana);
}

test "unhandled shrine grants nothing" {
    const g = grantFor(.unhandled, 500, 200);
    try testing.expectEqual(@as(?i32, null), g.life);
    try testing.expectEqual(@as(?i32, null), g.mana);
}

test "pick never returns a row above the area LevelMin" {
    var t = try Table.load(testing.allocator);
    defer t.deinit();
    // At a low area level, any assigned shrine must satisfy LevelMin (the 8-retry gate); a
    // returned row is never above it. Some rolls legitimately give up (null) after 8 misses.
    var seed = core.rng.Seed.init(0x1234_5678, 0);
    for (0..256) |_| {
        if (t.pick(&seed, .any, 1)) |idx| try testing.expect(t.rows[idx].level_min <= 1);
    }
}

test "boost-category pick only draws boost rows; Refill is in that pool" {
    var t = try Table.load(testing.allocator);
    defer t.deinit();
    // Objects.txt Parm>=3 maps to the boost pool (effectclass 4), which the table tags Refill
    // with too — so a high-level boost shrine can roll Refill. Every hit is effectclass 4.
    var seed = core.rng.Seed.init(0xdead_beef, 0x99);
    var saw_refill = false;
    for (0..256) |_| {
        if (t.pick(&seed, .{ .class = .boost }, 40)) |idx| {
            try testing.expectEqual(EffectClass.boost, t.rows[idx].effectclass);
            if (t.rows[idx].effect == .refill) saw_refill = true;
        }
    }
    try testing.expect(saw_refill);
}

test "resetDelayFrames matches the engine formula" {
    try testing.expectEqual(@as(u32, 2 * 1200 + 1), resetDelayFrames(2));
    try testing.expectEqual(@as(u32, 0), resetDelayFrames(0));
}
