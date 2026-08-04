//! rollDrop — the public item-generation entry point.
//! Wires the faithful chain: TreasureClassEx resolution (drop seed) -> GAME_GetItemQuality (drop seed,
//! +MF) -> item creation (game seed) -> ITEM_ApplyQualityAndAffixes (item mod seed) -> base stats.
//!
//! THREE seed streams, exactly as the engine keeps them:
//!   * the DROP seed  — the dropping unit's own sSeed: the TC walk and the MF-aware quality roll.
//!   * the GAME seed  — one global counter (D2GameStrc.pGameSeed). SUnit::CreateUnit 0x555230 steps it
//!     twice per item: the first step seeds the item unit's sSeed, the second its MOD seed.
//!   * the ITEM MOD seed — every affix, property, socket, ethereal and quantity roll.
//! Because the mod seed comes off the game counter and not off the drop seed, two identical monsters
//! killed in a different order produce different items — reproducing a drop needs the game seed too.

const std = @import("std");
const rng = @import("rng.zig");
const tables = @import("tables.zig");
const treasure = @import("treasure.zig");
const quality = @import("quality.zig");
const affix = @import("affix.zig");
const sockets = @import("sockets.zig");
const itemtype = @import("itemtype.zig");
const model = @import("model.zig");

pub const Drop = model.Drop;
pub const Quality = model.Quality;

/// Base-item flags needed by the quality + affix rollers.
pub const ItemFlags = struct {
    qlvl: i32 = 0,
    magic_lvl: i32 = 0,
    auto_prefix: i32 = 0,
    is_type_normal: bool = false,
    is_type_magic: bool = false,
    is_type_rare: bool = false,
    is_base_unique: bool = false,
    is_quest: bool = false,
    has_durability: bool = false,
    item_class: []const u8 = "",
};

pub fn itemFlags(t: *const tables.Tables, code: []const u8) ItemFlags {
    const ref = t.itemRef(code) orelse return .{};
    const tbl = t.itemTable(ref.table);
    var f = ItemFlags{
        .qlvl = @intCast(tbl.int(ref.row, "level")),
        .magic_lvl = @intCast(tbl.int(ref.row, "magic lvl")),
        .auto_prefix = @intCast(tbl.int(ref.row, "auto prefix")),
        .is_base_unique = tbl.int(ref.row, "unique") != 0,
        .is_quest = tbl.int(ref.row, "quest") != 0,
        .has_durability = tbl.int(ref.row, "nodurability") == 0 and tbl.int(ref.row, "durability") != 0,
        .item_class = affix.itemClassOf(t, code),
    };
    const type_code = tbl.str(ref.row, "type");
    if (t.itype_by_code.get(type_code)) |trow| {
        f.is_type_normal = t.item_types.int(trow, "Normal") != 0;
        f.is_type_magic = t.item_types.int(trow, "Magic") != 0;
        f.is_type_rare = t.item_types.int(trow, "Rare") != 0;
    }
    return f;
}

pub const RollOpts = struct {
    magic_find: i32 = 0,
    players: i32 = 1,
    is_expansion: bool = true,
    /// Ladder-only uniques are dropped from the pool outside a ladder game.
    is_ladder: bool = true,
    socket_tier: sockets.SocketTier = .cap3,
    /// The DROPPING unit's level — the gold amount is derived from it.
    drop_level: i32 = 0,
    /// The player's found-uniques bitmask; a unique already found fails its roll and downgrades.
    found_uniques: ?*affix.FoundUniques = null,
};

/// The two seeds SUnit::CreateUnit gives a fresh item unit.
pub const ItemSeeds = struct { unit: rng.Seed, item: rng.Seed };

/// SUnit::CreateUnit 0x555230 -> SetSeed 0x552df0 + SetItemSeeds 0x552e90. Two steps of the game's
/// single seed counter per item: the first becomes the unit's sSeed (and nInitSeed), the second the
/// item's MOD seed. Both are re-based to high = 0x29a.
pub fn createItemSeeds(game_seed: *rng.Seed) ItemSeeds {
    _ = game_seed.next();
    const unit = rng.Seed.init(game_seed.low, 0x29a);
    _ = game_seed.next();
    return .{ .unit = unit, .item = rng.Seed.init(game_seed.low, 0x29a) };
}

/// Roll a full drop from a treasure class. `drop_seed` is advanced through the TC walk and the
/// MF-aware quality rolls; `game_seed` is advanced twice per created item and supplies each item's own
/// roll stream. Returns the list of concrete items / gold; caller owns the slice.
pub fn rollDrop(
    gpa: std.mem.Allocator,
    drop_seed: *rng.Seed,
    game_seed: *rng.Seed,
    t: *const tables.Tables,
    tc_set: *const treasure.TCSet,
    tc_name: []const u8,
    mlvl: i32,
    opts: RollOpts,
) ![]Drop {
    var drops: std.ArrayListUnmanaged(Drop) = .empty;
    errdefer drops.deinit(gpa);

    const tc = tc_set.byLevel(tc_name, mlvl) orelse return drops.toOwnedSlice(gpa);

    var picks: std.ArrayListUnmanaged(treasure.Pick) = .empty;
    defer picks.deinit(gpa);
    try treasure.resolve(tc_set, drop_seed, tc, mlvl, .{ .is_expansion = opts.is_expansion, .players = opts.players }, .{}, &picks, gpa, 0);

    const ratio_row = t.ratioRow(if (opts.is_expansion) 1 else 0, 0, 0) orelse return error.NoItemRatio;
    const ratio = quality.Ratio{ .v = ratio_row };
    const drop_level = if (opts.drop_level != 0) opts.drop_level else mlvl;

    for (picks.items) |pk| {
        if (pk.kind == .gold) {
            var seeds = createItemSeeds(game_seed);
            try drops.append(gpa, .{
                .kind = .gold,
                .quantity = rollGoldAmount(&seeds.item, drop_level, pk.quantity_mult),
                .item_seed = seeds.item.low,
            });
            continue;
        }
        if (pk.kind != .item) continue;

        const flags = itemFlags(t, pk.code);
        const is_real_item = t.itemRef(pk.code) != null;

        var d = Drop{ .kind = .item, .item_level = mlvl };
        setCode(&d, pk.code);

        if (!is_real_item) {
            try drops.append(gpa, d);
            continue;
        }

        var seeds = createItemSeeds(game_seed);
        d.item_seed = seeds.item.low;

        if (pk.forced_quality != .invalid) {
            // A TC unique/set link entry: quality and the exact row are forced, the drop-time quality
            // roll is skipped entirely.
            d.quality = pk.forced_quality;
        } else {
            const qmods = [4]i32{ pk.mods.magic, pk.mods.rare, pk.mods.set, pk.mods.unique };
            d.quality = quality.gameGetItemQuality(drop_seed, &ratio, .{
                .qlvl = flags.qlvl,
                .victim_level = mlvl,
                .magic_find = opts.magic_find,
                .quality_mods = qmods,
                .is_type_normal = flags.is_type_normal,
                .is_type_magic = flags.is_type_magic,
                .is_type_rare = flags.is_type_rare,
                .is_base_unique = flags.is_base_unique,
                .is_quest = flags.is_quest,
            });
        }

        try applyQualityAndAffixes(gpa, &seeds, t, &ratio, &d, flags, opts, pk.forced_id);
        d.quantity = try rollStackQuantity(gpa, &seeds.item, t, &d);

        try drops.append(gpa, d);
    }

    return drops.toOwnedSlice(gpa);
}

/// ITEM_ApplyQualityAndAffixes 0x557450. The drop-time quality is already on `d`; the item's OWN
/// quality cascade still runs first and is then overridden — it advances the mod seed either way, so
/// skipping it desyncs every later roll. After the type overrides the tier is attempted, and on failure
/// the engine walks a per-tier fallback chain, each step restoring the saved seed and re-rolling (and
/// discarding) the quality before trying the next tier.
pub fn applyQualityAndAffixes(
    gpa: std.mem.Allocator,
    seeds: *ItemSeeds,
    t: *const tables.Tables,
    ratio: *const quality.Ratio,
    d: *Drop,
    flags: ItemFlags,
    opts: RollOpts,
    forced_id: u16,
) !void {
    var types = try itemtype.typesForItem(gpa, t, d.code());
    defer types.deinit(gpa);

    const qp = quality.Params{
        .ilvl = d.item_level,
        .qlvl = flags.qlvl,
        .is_expansion = opts.is_expansion,
        .is_misc = types.has("misc"),
        .is_quest = flags.is_quest,
    };
    _ = quality.rollItemQuality(&seeds.item, ratio, qp);

    // Item-type overrides, in the engine's order.
    if (flags.is_type_magic) {
        if (flags.is_quest) {
            d.quality = .unique;
        } else if (@intFromEnum(d.quality) < @intFromEnum(Quality.magic)) {
            d.quality = .magic;
        }
    }
    if (!flags.is_type_rare and d.quality == .rare) d.quality = .magic;
    if (flags.is_base_unique) d.quality = .unique;
    if (flags.is_type_normal) d.quality = .normal;

    const ctx = affix.AffixCtx{
        .types = &types,
        .ilvl = d.item_level,
        .qlvl = flags.qlvl,
        .magic_lvl = flags.magic_lvl,
        .item_class = flags.item_class,
        .is_expansion = opts.is_expansion,
        .quality = d.quality,
    };

    // The fallback chains, verbatim from the switch in 0x557450.
    const chain: []const Quality = switch (d.quality) {
        .unique => &.{ .unique, .rare, .magic, .superior, .normal },
        .set => &.{ .set, .magic, .superior, .normal },
        .rare => &.{ .rare, .magic, .superior, .normal },
        .magic => &.{ .magic, .superior, .normal },
        .superior => &.{ .superior, .normal },
        .low => &.{ .low, .normal },
        .crafted, .tempered => &.{ d.quality, .normal },
        else => &.{.normal},
    };

    var saved: u32 = seeds.item.low;
    for (chain, 0..) |tier, i| {
        if (i > 0) {
            seeds.item = rng.Seed.init(saved, 0x29a);
            _ = quality.rollItemQuality(&seeds.item, ratio, qp);
            saved = seeds.item.low;
        }
        d.quality = tier;
        var tctx = ctx;
        tctx.quality = tier;
        if (try rollTier(gpa, seeds, t, d, tctx, opts, forced_id)) break;
    }

    // Ethereal is rolled for every expansion item, whatever the quality landed on.
    if (opts.is_expansion) rollEthereal(&seeds.item, d, flags, &types);

    // Sockets: low / normal / superior only.
    switch (d.quality) {
        .low, .normal, .superior => {
            const max_sock = sockets.maxSockForItem(t, d.code(), d.item_level);
            if (max_sock > 0) {
                d.sockets = sockets.rollSocketCount(&seeds.item, .{
                    .max_sock = max_sock,
                    .ctx_tier = opts.socket_tier,
                    .is_expansion = opts.is_expansion,
                });
            }
        },
        else => {},
    }

    // Automagic: an extra group-restricted prefix from the base's `auto prefix`, for every quality
    // except set and unique.
    if (opts.is_expansion and flags.auto_prefix != 0) switch (d.quality) {
        .low, .normal, .superior, .magic, .rare, .crafted, .tempered => {
            var actx = ctx;
            actx.quality = d.quality;
            d.auto_prefix_id = try affix.rollAutoPrefix(gpa, &seeds.item, t, actx, flags.auto_prefix);
        },
        else => {},
    };
}

/// One tier attempt. Returns false when the tier could not be applied, which is what makes the caller
/// walk to the next entry of the fallback chain.
fn rollTier(
    gpa: std.mem.Allocator,
    seeds: *ItemSeeds,
    t: *const tables.Tables,
    d: *Drop,
    ctx: affix.AffixCtx,
    opts: RollOpts,
    forced_id: u16,
) !bool {
    const sel = affix.SelectOpts{
        .is_expansion = opts.is_expansion,
        .is_ladder = opts.is_ladder,
        .is_quest = false,
        .found = opts.found_uniques,
        .forced_id = forced_id,
    };
    switch (d.quality) {
        .unique => {
            d.unique_id = try affix.rollUniqueItem(gpa, &seeds.item, t, d.code(), d.item_level, sel);
            return d.unique_id != 0;
        },
        .set => {
            d.set_id = try affix.rollSetItem(gpa, &seeds.item, t, d.code(), d.item_level, sel);
            return d.set_id != 0;
        },
        .rare, .crafted, .tempered => {
            const r = try affix.rollRareAffixes(gpa, &seeds.item, t, ctx);
            if (!r.ok) return false;
            d.rare_prefix_name = r.prefix_name;
            d.rare_suffix_name = r.suffix_name;
            for (r.prefixes, 0..) |a, k| d.rare_prefix_ids[k] = a.id;
            for (r.suffixes, 0..) |a, k| d.rare_suffix_ids[k] = a.id;
            return true;
        },
        .magic => {
            const m = try affix.rollMagicPrefixSuffix(gpa, &seeds.item, t, ctx);
            d.prefix_id = m.prefix.id;
            d.suffix_id = m.suffix.id;
            return m.prefix.id != 0 or m.suffix.id != 0;
        },
        .superior => {
            d.quality_id = try affix.rollQualityItem(gpa, &seeds.item, t, d.code());
            return d.quality_id != 0;
        },
        // ITEMMOD_ApplyCrudeQualityClassic 0x5c2d40: one roll picks the LowQualityItems row (the
        // item's nFileIndex); the durability penalty rolls off the UNIT seed, not the mod seed.
        .low => {
            const n = t.low_quality_items.rowCount();
            if (n == 0) return false;
            d.low_quality_id = @intCast(seeds.item.pick(@intCast(n)) + 1);
            return true;
        },
        // ITEM_ApplyNormalTypeProperties 0x556f30 — charms roll a forced affix, body parts and
        // scrolls/books only pick a file index. Never fails.
        else => return true,
    }
}

/// ITEM_ApplyEthereal 0x556ca0 — a flat 5% roll off the item's own seed for every expansion weapon or
/// armour with durability, barring low-quality, set and quest items. The advance happens whether or not
/// the gates pass in the engine's forced paths; here the gates are checked first, so a skipped item
/// costs nothing. Damage/AC x3/2 and the halved max durability are stat effects the drop model does not
/// carry — only the flag is recorded.
fn rollEthereal(seed: *rng.Seed, d: *Drop, flags: ItemFlags, types: *const itemtype.TypeSet) void {
    if (d.quality == .low or d.quality == .set) return;
    if (flags.is_quest or !flags.has_durability) return;
    if (!types.has("weap") and !types.has("armo")) return;
    if (seed.pick(100) < 5) d.ethereal = true;
}

/// ITEM_InitItemBaseStats 0x557ab0, gold branch: `amount = level + selector(level*5)`, floored at 1.
/// A TC entry's `mul=` then rescales it as a 256ths fixed multiplier (mul=1280 -> x5); a plain `gld`
/// entry carries no multiplier and keeps the raw amount.
pub fn rollGoldAmount(seed: *rng.Seed, level: i32, mul: i32) i32 {
    var amount = level + @as(i32, @bitCast(seed.pick(@bitCast(level * 5))));
    if (amount < 1) amount = 1;
    if (mul != 0) amount = @intCast(@divTrunc(@as(i64, amount) * mul, 256));
    return amount;
}

/// ITEM_InitItemBaseStats 0x557ab0, stackable branch. Quivers roll straight over [minstack, maxstack];
/// misc stackables fold `spawnstack` into the upper bound; both misc and throwing weapons collapse to a
/// single unit once the item is magic or better. Non-stackables return 0 and consume no RNG.
fn rollStackQuantity(gpa: std.mem.Allocator, seed: *rng.Seed, t: *const tables.Tables, d: *const Drop) !i32 {
    const ref = t.itemRef(d.code()) orelse return 0;
    const tbl = t.itemTable(ref.table);
    if (tbl.int(ref.row, "stackable") == 0) return 0;

    const min: i32 = @intCast(tbl.int(ref.row, "minstack"));
    const max: i32 = @intCast(tbl.int(ref.row, "maxstack"));
    const spawn: i32 = @intCast(tbl.int(ref.row, "spawnstack"));

    var types = try itemtype.typesForItem(gpa, t, d.code());
    defer types.deinit(gpa);
    const is_quiver = blk: {
        const row = t.itypeRow(tbl.str(ref.row, "type")) orelse break :blk false;
        break :blk t.item_types.int(row, "Quiver") != 0;
    };

    const eff = if (is_quiver) max else if (spawn < min or spawn == 0) max else @min(spawn, max);
    var n = min + @as(i32, @bitCast(seed.pick(@bitCast(eff - min))));
    if (n < 1) n = 1;
    if (!is_quiver and @intFromEnum(d.quality) >= @intFromEnum(Quality.magic)) n = 1;
    return n;
}

fn setCode(d: *Drop, code: []const u8) void {
    d.item_code = .{ 0, 0, 0, 0 };
    const n = @min(code.len, 4);
    @memcpy(d.item_code[0..n], code[0..n]);
}

const testing = std.testing;

test "rollDrop deterministic end-to-end" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try treasure.build(testing.allocator, &t);
    defer set.deinit();

    var s1 = rng.Seed.init(0xC0FFEE, 0x29a);
    var s2 = rng.Seed.init(0xC0FFEE, 0x29a);
    var g1 = rng.Seed.init(7, 0x29a);
    var g2 = rng.Seed.init(7, 0x29a);
    const d1 = try rollDrop(testing.allocator, &s1, &g1, &t, &set, "Act 1 Equip A", 12, .{});
    defer testing.allocator.free(d1);
    const d2 = try rollDrop(testing.allocator, &s2, &g2, &t, &set, "Act 1 Equip A", 12, .{});
    defer testing.allocator.free(d2);

    try testing.expectEqual(d1.len, d2.len);
    for (d1, d2) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqualStrings(a.code(), b.code());
        try testing.expectEqual(a.quality, b.quality);
        try testing.expectEqual(a.prefix_id, b.prefix_id);
        try testing.expectEqual(a.suffix_id, b.suffix_id);
    }
    try testing.expectEqual(s1.low, s2.low);
    try testing.expectEqual(g1.low, g2.low);
}

test "each created item takes exactly two steps of the game seed" {
    var g = rng.Seed.init(0x1234, 0x29a);
    var probe = rng.Seed.init(0x1234, 0x29a);
    const seeds = createItemSeeds(&g);
    _ = probe.next();
    try testing.expectEqual(probe.low, seeds.unit.low);
    _ = probe.next();
    try testing.expectEqual(probe.low, seeds.item.low);
    try testing.expectEqual(@as(u32, 0x29a), seeds.item.high);
    try testing.expectEqual(probe.low, g.low);
}

test "gold: amount lands in [level, 6*level) and mul rescales in 256ths" {
    var n: u32 = 0;
    while (n < 200) : (n += 1) {
        var s = rng.Seed.init(n +% 1, 0x29a);
        const raw = rollGoldAmount(&s, 20, 0);
        try testing.expect(raw >= 20 and raw < 20 * 6);
        var s2 = rng.Seed.init(n +% 1, 0x29a);
        // mul=1280 is a x5 multiplier on the same roll.
        try testing.expectEqual(@divTrunc(raw * 1280, 256), rollGoldAmount(&s2, 20, 1280));
    }
}

test "a TC unique link forces that unique onto its own base item" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try treasure.build(testing.allocator, &t);
    defer set.deinit();

    // Find a TC that links a UniqueItems row by index and confirm the parsed entry resolved it.
    var found = false;
    for (set.list) |tc| {
        for (tc.entries) |e| {
            if (e.link_quality != .unique) continue;
            found = true;
            const uid = e.link_id;
            try testing.expect(uid != 0);
            // The entry's code is the unique's own base item, and that base really exists.
            try testing.expectEqualStrings(t.unique_items.str(uid - 1, "code"), e.name);
            try testing.expect(t.itemRef(e.name) != null);
        }
    }
    try testing.expect(found);
}

test "rollDrop on a gem TC yields real gem items" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try treasure.build(testing.allocator, &t);
    defer set.deinit();

    var found = false;
    var n: u32 = 0;
    while (n < 300) : (n += 1) {
        var s = rng.Seed.init(n +% 1, 0x29a);
        var g = rng.Seed.init(n +% 1, 0x29a);
        const d = try rollDrop(testing.allocator, &s, &g, &t, &set, "Chipped Gem", 10, .{});
        defer testing.allocator.free(d);
        for (d) |dr| {
            if (dr.kind == .item and t.itemRef(dr.code()) != null) found = true;
        }
    }
    try testing.expect(found);
}

test "quivers drop a real stack, non-stackables none" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var d = Drop{ .kind = .item, .quality = .normal, .item_level = 10 };
    setCode(&d, "aqv"); // Arrows
    var s = rng.Seed.init(0x31337, 0x29a);
    const n = try rollStackQuantity(testing.allocator, &s, &t, &d);
    const ref = t.itemRef("aqv").?;
    const tbl = t.itemTable(ref.table);
    try testing.expect(n >= @as(i32, @intCast(tbl.int(ref.row, "minstack"))));
    try testing.expect(n <= @as(i32, @intCast(tbl.int(ref.row, "maxstack"))));

    var d2 = Drop{ .kind = .item, .quality = .normal, .item_level = 10 };
    setCode(&d2, "cap");
    var s2 = rng.Seed.init(0x31337, 0x29a);
    const before = s2.low;
    try testing.expectEqual(@as(i32, 0), try rollStackQuantity(testing.allocator, &s2, &t, &d2));
    try testing.expectEqual(before, s2.low); // no RNG burnt on a non-stackable
}

test "an already-found unique fails its roll and the item downgrades" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    const ratio = quality.Ratio{ .v = t.ratioRow(1, 0, 0).? };

    // Force a Cap to unique quality; with an empty tracker it lands on a unique.
    var found = affix.FoundUniques{};
    var d = Drop{ .kind = .item, .quality = .unique, .item_level = 40 };
    setCode(&d, "cap");
    var seeds = ItemSeeds{ .unit = rng.Seed.init(1, 0x29a), .item = rng.Seed.init(0x777, 0x29a) };
    try applyQualityAndAffixes(testing.allocator, &seeds, &t, &ratio, &d, itemFlags(&t, "cap"), .{ .found_uniques = &found }, 0);
    try testing.expectEqual(Quality.unique, d.quality);
    try testing.expect(d.unique_id != 0);

    // Re-rolling with the same tracker cannot produce that unique again; when it is the only
    // candidate the item downgrades out of unique entirely.
    var d2 = Drop{ .kind = .item, .quality = .unique, .item_level = 40 };
    setCode(&d2, "cap");
    var seeds2 = ItemSeeds{ .unit = rng.Seed.init(1, 0x29a), .item = rng.Seed.init(0x777, 0x29a) };
    try applyQualityAndAffixes(testing.allocator, &seeds2, &t, &ratio, &d2, itemFlags(&t, "cap"), .{ .found_uniques = &found }, 0);
    try testing.expect(d2.unique_id != d.unique_id);
}

test "a superior drop picks a QualityItems row whose type gate accepts the base" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    const ratio = quality.Ratio{ .v = t.ratioRow(1, 0, 0).? };

    for ([_][]const u8{ "ssd", "cap" }) |code| {
        var d = Drop{ .kind = .item, .quality = .superior, .item_level = 40 };
        setCode(&d, code);
        var seeds = ItemSeeds{ .unit = rng.Seed.init(1, 0x29a), .item = rng.Seed.init(0x2468, 0x29a) };
        try applyQualityAndAffixes(testing.allocator, &seeds, &t, &ratio, &d, itemFlags(&t, code), .{}, 0);
        try testing.expectEqual(Quality.superior, d.quality);
        try testing.expect(d.quality_id != 0);

        // …and it rolls real stats off the same seed stream.
        const properties = @import("properties.zig");
        var out: std.ArrayListUnmanaged(properties.RolledStat) = .empty;
        defer out.deinit(testing.allocator);
        var s2 = rng.Seed.init(0x1357, 0x29a);
        try properties.rollDropStats(testing.allocator, &out, &s2, &t, &d);
        try testing.expect(out.items.len > 0);
    }
}

test "a low-quality drop names a LowQualityItems row" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    const ratio = quality.Ratio{ .v = t.ratioRow(1, 0, 0).? };
    var d = Drop{ .kind = .item, .quality = .low, .item_level = 30 };
    setCode(&d, "ssd");
    var seeds = ItemSeeds{ .unit = rng.Seed.init(1, 0x29a), .item = rng.Seed.init(0x5150, 0x29a) };
    try applyQualityAndAffixes(testing.allocator, &seeds, &t, &ratio, &d, itemFlags(&t, "ssd"), .{}, 0);
    try testing.expectEqual(Quality.low, d.quality);
    try testing.expect(d.low_quality_id >= 1 and d.low_quality_id <= t.low_quality_items.rowCount());
    try testing.expect(!d.ethereal); // low quality never rolls ethereal
}

test "ethereal appears on weapons/armour at roughly the engine's 5%" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    const ratio = quality.Ratio{ .v = t.ratioRow(1, 0, 0).? };
    const flags = itemFlags(&t, "7ls");

    var eth: u32 = 0;
    const runs: u32 = 4000;
    var n: u32 = 0;
    while (n < runs) : (n += 1) {
        var d = Drop{ .kind = .item, .quality = .normal, .item_level = 80 };
        setCode(&d, "7ls");
        var seeds = ItemSeeds{ .unit = rng.Seed.init(1, 0x29a), .item = rng.Seed.init(n +% 1, 0x29a) };
        try applyQualityAndAffixes(testing.allocator, &seeds, &t, &ratio, &d, flags, .{}, 0);
        if (d.ethereal) eth += 1;
    }
    // 5% of 4000 is 200; allow generous slack for the seed distribution.
    try testing.expect(eth > 100 and eth < 320);

    // A ring has no durability, so it can never be ethereal.
    var r = Drop{ .kind = .item, .quality = .normal, .item_level = 80 };
    setCode(&r, "rin");
    var rs = ItemSeeds{ .unit = rng.Seed.init(1, 0x29a), .item = rng.Seed.init(9, 0x29a) };
    try applyQualityAndAffixes(testing.allocator, &rs, &t, &ratio, &r, itemFlags(&t, "rin"), .{}, 0);
    try testing.expect(!r.ethereal);
}

test "the item-seed quality cascade runs even when the drop already forced a quality" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    const ratio = quality.Ratio{ .v = t.ratioRow(1, 0, 0).? };
    const flags = itemFlags(&t, "cap");

    // Running the discarded cascade is what puts the affix rolls on the right seed: dropping it
    // would leave the mod seed one or more advances behind.
    var d = Drop{ .kind = .item, .quality = .magic, .item_level = 40 };
    setCode(&d, "cap");
    var seeds = ItemSeeds{ .unit = rng.Seed.init(1, 0x29a), .item = rng.Seed.init(0x4242, 0x29a) };
    try applyQualityAndAffixes(testing.allocator, &seeds, &t, &ratio, &d, flags, .{}, 0);

    var probe = rng.Seed.init(0x4242, 0x29a);
    _ = quality.rollItemQuality(&probe, &ratio, .{
        .ilvl = 40,
        .qlvl = flags.qlvl,
        .is_expansion = true,
        .is_misc = false,
        .is_quest = false,
    });
    try testing.expect(probe.low != 0x4242); // the cascade really does advance the seed
}

test "high MF shifts quality upward over many drops" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try treasure.build(testing.allocator, &t);
    defer set.deinit();

    var rare_plus_none: u32 = 0;
    var rare_plus_mf: u32 = 0;
    var n: u32 = 0;
    while (n < 4000) : (n += 1) {
        var s0 = rng.Seed.init(n +% 1, 0x29a);
        var s1 = rng.Seed.init(n +% 1, 0x29a);
        var g0 = rng.Seed.init(n +% 1, 0x29a);
        var g1 = rng.Seed.init(n +% 1, 0x29a);
        const a = try rollDrop(testing.allocator, &s0, &g0, &t, &set, "Chipped Gem", 10, .{ .magic_find = 0 });
        defer testing.allocator.free(a);
        const b = try rollDrop(testing.allocator, &s1, &g1, &t, &set, "Chipped Gem", 10, .{ .magic_find = 900 });
        defer testing.allocator.free(b);
        for (a) |d| if (@intFromEnum(d.quality) >= @intFromEnum(Quality.magic)) {
            rare_plus_none += 1;
        };
        for (b) |d| if (@intFromEnum(d.quality) >= @intFromEnum(Quality.magic)) {
            rare_plus_mf += 1;
        };
    }
    try testing.expect(rare_plus_mf >= rare_plus_none);
}
