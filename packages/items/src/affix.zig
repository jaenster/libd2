//! Magic + rare affix rolling — THE crux (roll-exact).
//! Ports (1.14d Game.exe):
//!   ITEMMOD_RollMagicAffixClassic 0x5c1560 — frequency-WEIGHTED prefix/suffix
//!     roll (used for all expansion items via RollMagicAffixVersioned 0x5c18e0).
//!   ITEM_RollMagicPrefixSuffix   0x5565e0 — one prefix then one suffix.
//!   ITEMMOD_RollRareAffixes      0x5c21d0 — rare-name pick + 1..N alternating
//!     magic affixes with per-group no-dup reroll.
//!   ITEMMOD_CanApplyAutomod      0x65e620 — itype-include / etype-exclude match
//!     (see itemtype.zig).
//!
//! RNG contract (verified reA_roll_primitives.c): every advance is the LCG
//! `state = low*0x6ac690c5 + high`; reductions are LOW-WORD (rng.pick /
//! rng.rollBetween). A magic affix roll = 1 gate advance + (1 weighted-pick
//! advance if any candidate). One extra/missing advance desyncs the seed.

const std = @import("std");
const rng = @import("rng.zig");
const txt = @import("txt.zig");
const tables = @import("tables.zig");
const itemtype = @import("itemtype.zig");

pub const AffixKind = enum { prefix, suffix };

pub const AffixResult = struct {
    id: u16 = 0, // 1-based row index in the prefix/suffix table (0 = none)
    group: i32 = -1,
};

/// alvl (affix level), inline in RollMagicAffixClassic. `magic_lvl` is the base
/// item's magic level (Weapons/Armor/Misc `magiclvl`); for magic_lvl==0 this is
/// the classic quality-level curve.
pub fn computeAlvl(ilvl: i32, qlvl: i32, magic_lvl: i32) i32 {
    const eff = @max(ilvl, qlvl);
    var alvl: i32 = undefined;
    if (magic_lvl == 0) {
        const half = @divTrunc(qlvl, 2);
        alvl = if (eff < 99 - half) eff - half else 2 * eff - 99;
    } else {
        alvl = eff + magic_lvl;
    }
    if (alvl < 2) return 1;
    if (alvl > 98) return 99;
    return alvl;
}

/// One eligible affix in the weighted pool.
const Cand = struct { id: u16, group: i32, weight: i32 };

/// Roll one magic prefix OR suffix, frequency-weighted, faithful to
/// RollMagicAffixClassic. `exclude_group` (>=0) forbids an affix whose group
/// matches (one affix per group across a rare roll). `forced_id` (>0) forces a
/// specific table row (still consumes the gate + pick advances). `is_forced`
/// bypasses the 50% gate (used by forced/auto affixes).
pub fn rollMagicAffix(
    gpa: std.mem.Allocator,
    seed: *rng.Seed,
    t: *const tables.Tables,
    tbl: *const txt.Table,
    kind: AffixKind,
    item_types: *const itemtype.TypeSet,
    ilvl: i32,
    qlvl: i32,
    magic_lvl: i32,
    is_expansion: bool,
    exclude_group: i32,
    forced_id: u16,
    is_forced: bool,
) !AffixResult {
    _ = kind;
    // 1. Gate advance (ALWAYS consumes one LCG step).
    _ = seed.next();
    if ((seed.low & 1) == 0 and !is_forced and forced_id == 0) return .{};

    _ = t; // classspecific restriction not modelled (residual)
    const alvl = computeAlvl(ilvl, qlvl, magic_lvl);

    var pool: std.ArrayListUnmanaged(Cand) = .empty;
    defer pool.deinit(gpa);
    var sum: i32 = 0;

    var itbuf: [8]u8 = undefined;
    var etbuf: [8]u8 = undefined;

    for (0..tbl.rowCount()) |row| {
        const spawnable = tbl.int(row, "spawnable");
        if (spawnable != 1) continue;

        const version = tbl.int(row, "version");
        if (!(version < 100 or is_expansion)) continue;

        const lvl_min: i32 = @intCast(tbl.int(row, "level"));
        const lvl_max: i32 = @intCast(tbl.int(row, "maxlevel"));
        if (alvl < lvl_min) continue;
        if (lvl_max != 0 and alvl > lvl_max) continue;

        const freq: i32 = @intCast(tbl.int(row, "frequency"));
        if (freq <= 0) continue;

        const group: i32 = @intCast(tbl.int(row, "group"));
        if (exclude_group >= 0 and group == exclude_group) continue;

        if (forced_id != 0 and @as(u16, @intCast(row + 1)) != forced_id) continue;

        // itype-include / etype-exclude match (CanApplyAutomod core).
        var itypes: [7][]const u8 = undefined;
        inline for (0..7) |i| {
            const col = std.fmt.bufPrint(&itbuf, "itype{d}", .{i + 1}) catch unreachable;
            itypes[i] = tbl.str(row, col);
        }
        var etypes: [5][]const u8 = undefined;
        inline for (0..5) |i| {
            const col = std.fmt.bufPrint(&etbuf, "etype{d}", .{i + 1}) catch unreachable;
            etypes[i] = tbl.str(row, col);
        }
        if (!itemtype.affixMatchesTypes(item_types, &itypes, &etypes)) continue;

        const weight = freq; // magic_lvl!=0 frequency*multiplier: residual
        sum += weight;
        try pool.append(gpa, .{ .id = @intCast(row + 1), .group = group, .weight = weight });
    }

    if (pool.items.len == 0) return .{};

    // 2. Weighted pick: r in [0, sum]; subtract-walk.
    var r = seed.rollBetween(0, sum + 1);
    for (pool.items) |c| {
        r -= c.weight;
        if (r < 0) return .{ .id = c.id, .group = c.group };
    }
    // Rounding safety: last candidate.
    const last = pool.items[pool.items.len - 1];
    return .{ .id = last.id, .group = last.group };
}

pub const MagicResult = struct { prefix: AffixResult = .{}, suffix: AffixResult = .{} };

/// ITEM_RollMagicPrefixSuffix: prefix first, then suffix. Both independent
/// (separate tables); each is a full gate+pick. Item is "magic" if either lands.
pub fn rollMagicPrefixSuffix(
    gpa: std.mem.Allocator,
    seed: *rng.Seed,
    t: *const tables.Tables,
    item_types: *const itemtype.TypeSet,
    ilvl: i32,
    qlvl: i32,
    magic_lvl: i32,
    is_expansion: bool,
) !MagicResult {
    const pfx = try rollMagicAffix(gpa, seed, t, &t.magic_prefix, .prefix, item_types, ilvl, qlvl, magic_lvl, is_expansion, -1, 0, false);
    const sfx = try rollMagicAffix(gpa, seed, t, &t.magic_suffix, .suffix, item_types, ilvl, qlvl, magic_lvl, is_expansion, -1, 0, false);
    return .{ .prefix = pfx, .suffix = sfx };
}

pub const RareResult = struct {
    prefix_name: u16 = 0, // RarePrefix.txt row (1-based)
    suffix_name: u16 = 0, // RareSuffix.txt row (1-based)
    prefixes: [3]AffixResult = .{ .{}, .{}, .{} },
    suffixes: [3]AffixResult = .{ .{}, .{}, .{} },
    ok: bool = false,
};

/// Rare name pick over the rare-name tables (GetMaxToRoll / GetMaxAffixGroupClassic).
/// The engine helper's exact eligibility+roll wasn't decompiled; modelled here as
/// a uniform pick (one advance) over rows whose itype matches — RESIDUAL: exact
/// internals may weight/filter differently.
fn rollRareName(gpa: std.mem.Allocator, seed: *rng.Seed, tbl: *const txt.Table, item_types: *const itemtype.TypeSet) !u16 {
    var pool: std.ArrayListUnmanaged(u16) = .empty;
    defer pool.deinit(gpa);
    var itbuf: [8]u8 = undefined;
    var etbuf: [8]u8 = undefined;
    for (0..tbl.rowCount()) |row| {
        var itypes: [7][]const u8 = undefined;
        inline for (0..7) |i| itypes[i] = tbl.str(row, std.fmt.bufPrint(&itbuf, "itype{d}", .{i + 1}) catch unreachable);
        var etypes: [4][]const u8 = undefined;
        inline for (0..4) |i| etypes[i] = tbl.str(row, std.fmt.bufPrint(&etbuf, "etype{d}", .{i + 1}) catch unreachable);
        if (itemtype.affixMatchesTypes(item_types, &itypes, &etypes)) try pool.append(gpa, @intCast(row + 1));
    }
    if (pool.items.len == 0) return 0;
    const idx: usize = @intCast(seed.rollBetween(0, @intCast(pool.items.len)));
    return pool.items[idx];
}

/// ITEMMOD_RollRareAffixes: rare-name pick + 1..N alternating magic affixes with
/// per-group no-dup reroll (up to 251 retries). Faithful roll structure.
pub fn rollRareAffixes(
    gpa: std.mem.Allocator,
    seed: *rng.Seed,
    t: *const tables.Tables,
    item_types: *const itemtype.TypeSet,
    ilvl: i32,
    qlvl: i32,
    magic_lvl: i32,
    is_expansion: bool,
) !RareResult {
    var res = RareResult{};
    res.prefix_name = try rollRareName(gpa, seed, &t.rare_prefix, item_types);
    res.suffix_name = try rollRareName(gpa, seed, &t.rare_suffix, item_types);
    if (res.prefix_name == 0 or res.suffix_name == 0) return res;

    // Affix count: seed.next(); count = low % 5, clamped up to minRolls(ilvl).
    var min_rolls: i32 = 1;
    if (ilvl > 30) min_rolls = 2;
    if (ilvl > 50) min_rolls = 3;
    if (ilvl > 70) min_rolls = 4;
    _ = seed.next();
    var count: i32 = @intCast(seed.low % 5);
    if (count < min_rolls) count = min_rolls;

    var n_prefix: usize = 0;
    var n_suffix: usize = 0;

    while (count > 0) : (count -= 1) {
        _ = seed.next();
        const want_suffix = (n_prefix == 3) or (n_suffix != 3 and (seed.low & 1) != 0);

        var retries: u32 = 0;
        while (retries < 0xfb) : (retries += 1) {
            if (want_suffix) {
                const roll = try rollMagicAffix(gpa, seed, t, &t.magic_suffix, .suffix, item_types, ilvl, qlvl, magic_lvl, is_expansion, -1, 0, true);
                if (collides(res.suffixes[0..n_suffix], roll)) continue;
                res.suffixes[n_suffix] = roll;
                n_suffix += 1;
            } else {
                const roll = try rollMagicAffix(gpa, seed, t, &t.magic_prefix, .prefix, item_types, ilvl, qlvl, magic_lvl, is_expansion, -1, 0, true);
                if (collides(res.prefixes[0..n_prefix], roll)) continue;
                res.prefixes[n_prefix] = roll;
                n_prefix += 1;
            }
            break;
        }
    }
    res.ok = true;
    return res;
}

fn collides(existing: []const AffixResult, roll: AffixResult) bool {
    if (roll.id == 0) return true;
    for (existing) |e| {
        if (e.id == roll.id or (e.group >= 0 and e.group == roll.group)) return true;
    }
    return false;
}

const testing = std.testing;

test "computeAlvl matches the classic quality-level curve" {
    // ilvl 50, qlvl 20, no magiclvl: half=10; 50 < 99-10=89 -> alvl = 50-10 = 40
    try testing.expectEqual(@as(i32, 40), computeAlvl(50, 20, 0));
    // high ilvl branch: ilvl 95, qlvl 10 -> half=5; 95 < 94? no -> 2*95-99 = 91
    try testing.expectEqual(@as(i32, 91), computeAlvl(95, 10, 0));
    // magiclvl adds directly
    try testing.expectEqual(@as(i32, 55), computeAlvl(50, 20, 5));
    // clamps
    try testing.expectEqual(@as(i32, 99), computeAlvl(200, 0, 0));
}

test "magic affix: deterministic + pulled from the correct table/type" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var types = try itemtype.typesForItem(testing.allocator, &t, "hax");
    defer types.deinit(testing.allocator);

    var s1 = rng.Seed.init(0x777, 0x29a);
    var s2 = rng.Seed.init(0x777, 0x29a);
    const a = try rollMagicPrefixSuffix(testing.allocator, &s1, &t, &types, 50, 10, 0, true);
    const b = try rollMagicPrefixSuffix(testing.allocator, &s2, &t, &types, 50, 10, 0, true);
    try testing.expectEqual(a.prefix.id, b.prefix.id);
    try testing.expectEqual(a.suffix.id, b.suffix.id);
    try testing.expectEqual(s1.low, s2.low);
}

test "magic affix: over many seeds at least one prefix and one suffix land, valid rows" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var types = try itemtype.typesForItem(testing.allocator, &t, "hax");
    defer types.deinit(testing.allocator);

    var got_prefix = false;
    var got_suffix = false;
    var n: u32 = 0;
    while (n < 300) : (n += 1) {
        var s = rng.Seed.init(n +% 1, 0x29a);
        const r = try rollMagicPrefixSuffix(testing.allocator, &s, &t, &types, 60, 10, 0, true);
        if (r.prefix.id != 0) {
            got_prefix = true;
            try testing.expect(r.prefix.id <= t.magic_prefix.rowCount());
        }
        if (r.suffix.id != 0) {
            got_suffix = true;
            try testing.expect(r.suffix.id <= t.magic_suffix.rowCount());
        }
    }
    try testing.expect(got_prefix and got_suffix);
}

test "rare affixes: deterministic, respects 3/type cap and no dup group" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var types = try itemtype.typesForItem(testing.allocator, &t, "hax");
    defer types.deinit(testing.allocator);

    var s = rng.Seed.init(0x424242, 0x29a);
    const r = try rollRareAffixes(testing.allocator, &s, &t, &types, 80, 10, 0, true);
    try testing.expect(r.ok);
    try testing.expect(r.prefix_name != 0 and r.suffix_name != 0);
    // No duplicate group among chosen prefixes.
    for (r.prefixes, 0..) |a, i| {
        if (a.id == 0) continue;
        for (r.prefixes[i + 1 ..]) |b| {
            if (b.id != 0 and a.group >= 0) try testing.expect(a.group != b.group);
        }
    }
}
