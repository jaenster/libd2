//! ITEM_RollItemQuality — the quality-determination cascade.
//! Faithful port of 1.14d Game.exe 0x556f60 (D2Common::Items::Drop).
//!
//! Roll order (THE crux): iterate the 6-entry quality tier table in priority
//! order Unique -> Set -> Rare -> Magic -> Superior -> Normal. Per tier compute
//! a `chance`, then RANDOM_RandomNumberSelector(seed, chance) == 0 selects that
//! quality. Exactly one RNG advance per tier evaluated (see rng.pick).
//!
//! Two rulesets (item version): classic (version==0) vs expansion (>=100).
//!  - classic: Set/Rare/Unique use `base - ilvlAdj` (NO divisor); Magic/Superior/
//!    Normal use `base - ilvlAdj/divisor`; chance is clamped up to 1 (so even a
//!    "won" tier still needs selector()==0).
//!  - expansion: EVERY tier uses `base - ilvlAdj/divisor`; if chance < 1 the tier
//!    auto-wins WITHOUT consuming a roll.
//!
//! MF is NOT applied here — the caller (GAME_GetItemQuality, drop path) folds
//! magic-find + TC quality-mods into the effective chance before/around this.
//! This port models the raw cascade; see item.zig for the MF wiring (TODO).

const std = @import("std");
const rng = @import("rng.zig");
const model = @import("model.zig");
const Quality = model.Quality;

/// Parsed ItemRatio.txt row: the 16 numeric columns in table order.
/// [0]Unique [1]UniqueDivisor [2]UniqueMin [3]Rare [4]RareDivisor [5]RareMin
/// [6]Set [7]SetDivisor [8]SetMin [9]Magic [10]MagicDivisor [11]MagicMin
/// [12]HiQuality [13]HiQualityDivisor [14]Normal [15]NormalDivisor
pub const Ratio = struct {
    v: [16]i32,

    pub fn get(self: *const Ratio, i: usize) i32 {
        return self.v[i];
    }
};

/// The engine's gaItemQualityTierTable evaluation order (priority high->low).
/// Values are eD2ItemQuality tier codes.
pub const tier_order = [6]Quality{ .unique, .set, .rare, .magic, .superior, .normal };

pub const Params = struct {
    ilvl: i32, // drop item level (ctx.nItemLevel)
    qlvl: i32, // base item's quality level (Items.txt `level`)
    is_expansion: bool,
    is_misc: bool, // item is ITEMTYPE_Miscellaneous
    is_quest: bool, // base item's `quest` flag
    /// nFlags bit 0x40: if set, the exhausted-cascade fallback is Superior, else Low.
    fallback_superior: bool = false,
};

/// Faithful cascade. Advances `seed` per tier evaluated. Returns the selected
/// quality (never .invalid). Quest items short-circuit to Normal (engine: ret 2).
pub fn rollItemQuality(seed: *rng.Seed, ratio: *const Ratio, p: Params) Quality {
    if (p.is_quest) return .normal;

    // ilvlAdj: expansion subtracts the base item's qlvl (clamped to >=1);
    // classic uses ilvl directly.
    var ilvl_adj: i32 = p.ilvl;
    if (p.is_expansion) {
        if (p.is_misc or (p.ilvl - p.qlvl) < 1) {
            ilvl_adj = 1;
        } else {
            ilvl_adj = p.ilvl - p.qlvl;
        }
    }

    for (tier_order) |tier| {
        // base column + optional divisor per tier (see Ratio layout above).
        const cols: struct { base: usize, div: usize } = switch (tier) {
            .unique => .{ .base = 0, .div = 1 },
            .rare => .{ .base = 3, .div = 4 },
            .set => .{ .base = 6, .div = 7 },
            .magic => .{ .base = 9, .div = 10 },
            .superior => .{ .base = 12, .div = 13 },
            .normal => .{ .base = 14, .div = 15 },
            else => unreachable,
        };

        var chance: i32 = undefined;
        if (!p.is_expansion) {
            // classic: Set/Rare/Unique have no divisor.
            chance = switch (tier) {
                .set, .rare, .unique => ratio.get(cols.base) - ilvl_adj,
                else => ratio.get(cols.base) - divFloor(ilvl_adj, ratio.get(cols.div)),
            };
            if (chance < 1) chance = 1; // classic clamps up (no auto-win)
        } else {
            const div = ratio.get(cols.div);
            chance = ratio.get(cols.base) - divFloor(ilvl_adj, div);
            if (chance < 1) return tier; // expansion auto-wins
        }

        if (seed.pick(@bitCast(chance)) == 0) return tier;
    }

    return if (p.fallback_superior) .superior else .low;
}

fn divFloor(a: i32, b: i32) i32 {
    if (b == 0) return 0; // engine ratio divisors are nonzero for evaluated tiers
    return @divTrunc(a, b);
}

/// ITEMDROP_AdjustDrop 0x558610 — magic-find diminishing-returns curve.
/// mf_base = effectiveMF + 100. factor per quality (Unique 250, Set 500, Rare 600).
pub fn adjustDrop(mf_base: i32, factor: i32) i32 {
    if (mf_base < 111) return mf_base; // MF <= 10%: linear, no penalty
    return @divTrunc((mf_base - 100) * factor, (mf_base - 100) + factor) + 100;
}

/// Inputs to the drop-time quality roll (GAME_GetItemQuality). item flags come
/// from the base item's ItemTypes row + the item txt.
pub const DropQualityParams = struct {
    qlvl: i32, // base item level (Items.txt `level`)
    victim_level: i32, // dropping monster level
    magic_find: i32 = 0, // effective magic find (already summed)
    /// TC quality modifiers in 1024ths, index: [0]=magic [1]=rare [2]=set [3]=unique.
    quality_mods: [4]i32 = .{ 0, 0, 0, 0 },
    is_type_normal: bool = false, // ItemTypes.Normal (always normal quality)
    is_type_magic: bool = false, // ItemTypes.Magic (min magic)
    is_type_rare: bool = false, // ItemTypes.Rare (rare eligible)
    is_base_unique: bool = false, // Items.txt `unique` (quest/unique-only base)
    is_quest: bool = false,
};

/// GAME_GetItemQuality 0x558640 — the MF-aware DROP quality selector. Rolls off
/// the DROP seed (the monster's sSeed), NOT the item seed. Cascade order:
/// Unique -> Set -> Rare(if eligible) -> Magic -> Superior -> Normal/Low.
/// Per tier: chance = (base - lvlDiff/div); scaled x128; MF divides it down
/// (AdjustDrop); floored at the ratio Min; reduced by the TC quality-mod; then
/// RANDOM(seed, chance) < 128 wins (or chance<1 auto-wins). Roll-exact.
pub fn gameGetItemQuality(seed: *rng.Seed, ratio: *const Ratio, p: DropQualityParams) Quality {
    if (p.is_type_normal) return .normal;
    if (p.is_base_unique) return .unique;
    if (p.is_type_magic and p.is_quest) return .unique;

    const lvl_diff = p.victim_level - p.qlvl;
    const has_mf = p.magic_find != 0;
    if (p.magic_find < -99) return normalTail(seed, ratio, lvl_diff);
    const mf_base = p.magic_find + 100;

    // Unique
    if (rollTier(seed, ratio, 0, 1, 2, lvl_diff, has_mf, mf_base, 250, p.quality_mods[3])) return .unique;
    // Set
    if (rollTier(seed, ratio, 6, 7, 8, lvl_diff, has_mf, mf_base, 500, p.quality_mods[2])) return .set;
    // Rare (only if the item type can be rare)
    if (p.is_type_rare) {
        if (rollTier(seed, ratio, 3, 4, 5, lvl_diff, has_mf, mf_base, 600, p.quality_mods[1])) return .rare;
    }
    // Magic
    if (p.is_type_magic) return .magic;
    if (rollTierMagic(seed, ratio, lvl_diff, has_mf, mf_base, p.quality_mods[0])) return .magic;

    return normalTail(seed, ratio, lvl_diff);
}

fn tierChance(ratio: *const Ratio, base_i: usize, div_i: usize, min_i: usize, lvl_diff: i32, has_mf: bool, mf_base: i32, factor: i32, qmod: i32) i32 {
    const base = ratio.get(base_i) - divFloor(lvl_diff, ratio.get(div_i));
    var scaled: i32 = base * 0x80;
    if (has_mf) {
        const adj = adjustDrop(mf_base, factor);
        if (adj != 0) scaled = @intCast(@divTrunc(@as(i64, base) * 0x3200, adj));
    }
    if (scaled <= ratio.get(min_i)) scaled = ratio.get(min_i);
    // reduce by TC quality mod (1024ths).
    const reduced = scaled - @as(i32, @intCast(@divTrunc(@as(i64, qmod) * scaled, 1024)));
    return reduced;
}

fn rollTier(seed: *rng.Seed, ratio: *const Ratio, base_i: usize, div_i: usize, min_i: usize, lvl_diff: i32, has_mf: bool, mf_base: i32, factor: i32, qmod: i32) bool {
    const chance = tierChance(ratio, base_i, div_i, min_i, lvl_diff, has_mf, mf_base, factor, qmod);
    if (chance < 1) return true;
    return seed.pick(@bitCast(chance)) < 0x80;
}

fn rollTierMagic(seed: *rng.Seed, ratio: *const Ratio, lvl_diff: i32, has_mf: bool, mf_base: i32, qmod: i32) bool {
    // Magic uses mf_base directly as divisor (no AdjustDrop).
    const base = ratio.get(9) - divFloor(lvl_diff, ratio.get(10));
    var scaled: i32 = base * 0x80;
    if (has_mf) scaled = @intCast(@divTrunc(@as(i64, base) * 0x3200, mf_base));
    if (scaled <= ratio.get(11)) scaled = ratio.get(11);
    const chance = scaled - @as(i32, @intCast(@divTrunc(@as(i64, qmod) * scaled, 1024)));
    if (chance < 1) return true;
    return seed.pick(@bitCast(chance)) < 0x80;
}

fn normalTail(seed: *rng.Seed, ratio: *const Ratio, lvl_diff: i32) Quality {
    const sup = (ratio.get(12) - divFloor(lvl_diff, ratio.get(13))) * 0x80;
    if (sup > 0) {
        if (seed.pick(@bitCast(sup)) >= 0x80) {
            const norm = (ratio.get(14) - divFloor(lvl_diff, ratio.get(15))) * 0x80;
            if (norm < 1) return .normal;
            return if (seed.pick(@bitCast(norm)) < 0x80) .low else .normal;
        }
    }
    return .superior;
}

test "gameGetItemQuality: MF raises unique/set odds vs no MF (real data)" {
    const tbl = @import("tables.zig");
    var t = try tbl.Tables.load(testing.allocator);
    defer t.deinit();
    const r = Ratio{ .v = t.ratioRow(1, 0, 0).? };

    var high: u32 = 0;
    var none: u32 = 0;
    var n: u32 = 0;
    while (n < 30000) : (n += 1) {
        const p0 = DropQualityParams{ .qlvl = 20, .victim_level = 80, .is_type_magic = true, .is_type_rare = true };
        var p_mf = p0;
        p_mf.magic_find = 500;
        var s0 = rng.Seed.init(n +% 1, 0x29a);
        var s1 = rng.Seed.init(n +% 1, 0x29a);
        const q0 = gameGetItemQuality(&s0, &r, p0);
        const q1 = gameGetItemQuality(&s1, &r, p_mf);
        if (q0 == .unique or q0 == .set) none += 1;
        if (q1 == .unique or q1 == .set) high += 1;
    }
    // 500 MF must produce strictly more unique+set drops than 0 MF.
    try testing.expect(high > none);
}

test "gameGetItemQuality: normal-type item is always normal" {
    const tbl = @import("tables.zig");
    var t = try tbl.Tables.load(testing.allocator);
    defer t.deinit();
    const r = Ratio{ .v = t.ratioRow(1, 0, 0).? };
    var s = rng.Seed.init(5, 0x29a);
    const before = s;
    try testing.expectEqual(Quality.normal, gameGetItemQuality(&s, &r, .{ .qlvl = 1, .victim_level = 99, .is_type_normal = true }));
    try testing.expectEqual(before.low, s.low); // no roll consumed
}

const testing = std.testing;

fn testRatio() Ratio {
    // Plausible expansion "Hell/act" ratio-ish values; only relative magnitudes
    // matter for the distribution test.
    return .{ .v = .{
        400, 25, 6, // Unique
        400, 25, 25, // Rare
        160, 25, 12, // Set
        192, 25, 3, // Magic
        7, 1, // HiQuality (base, divisor)
        1, 1, // Normal (base, divisor)
    } };
}

test "deterministic: same seed+params -> same quality" {
    const r = testRatio();
    const p = Params{ .ilvl = 50, .qlvl = 10, .is_expansion = true, .is_misc = false, .is_quest = false };
    var s1 = rng.Seed.init(0x1234, 0x29a);
    var s2 = rng.Seed.init(0x1234, 0x29a);
    try testing.expectEqual(rollItemQuality(&s1, &r, p), rollItemQuality(&s2, &r, p));
}

test "quest item is always normal, no roll consumed" {
    const r = testRatio();
    var s = rng.Seed.init(0x9, 0x29a);
    const before = s;
    const q = rollItemQuality(&s, &r, .{ .ilvl = 99, .qlvl = 1, .is_expansion = true, .is_misc = false, .is_quest = true });
    try testing.expectEqual(Quality.normal, q);
    try testing.expectEqual(before.low, s.low);
}

test "distribution is sane on REAL ItemRatio data: normal dominates, unique rare" {
    const tables = @import("tables.zig");
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    const r = Ratio{ .v = t.ratioRow(1, 0, 0).? }; // expansion, non-uber, non-class-specific

    var counts = [_]u32{0} ** 10;
    var n: u32 = 0;
    while (n < 20000) : (n += 1) {
        var s = rng.Seed.init(n +% 1, 0x29a);
        const q = rollItemQuality(&s, &r, .{ .ilvl = 40, .qlvl = 5, .is_expansion = true, .is_misc = false, .is_quest = false });
        counts[@intFromEnum(q)] += 1;
    }
    // Normal is by far the most common; unique far rarer than normal.
    try testing.expect(counts[@intFromEnum(Quality.normal)] > counts[@intFromEnum(Quality.magic)]);
    try testing.expect(counts[@intFromEnum(Quality.unique)] < counts[@intFromEnum(Quality.normal)] / 10);
}
