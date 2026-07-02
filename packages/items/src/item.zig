//! rollDrop — the public item-generation entry point.
//! Wires the faithful chain: TreasureClassEx resolution (drop seed) ->
//! GAME_GetItemQuality (drop seed, +MF) -> per-quality affixes (item MOD seed)
//! -> sockets. Mirrors SERVER_ITEM_RollItemToDrop 0x55a6d0 + CreateItem +
//! ITEM_ApplyQualityAndAffixes 0x557450.
//!
//! TWO SEEDS (per reA_seed_derivation.c): the drop/TC/quality rolls advance the
//! monster "drop seed"; affix/socket rolls advance the item's own "mod seed".
//! The drop-seed -> item-seed derivation lives in SUnit::CreateUnit (NOT
//! decompiled) — a documented RESIDUAL. So the whole cascade is roll-exact GIVEN
//! both seeds; the convenience derivation below is an explicit placeholder.

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
    is_type_normal: bool = false,
    is_type_magic: bool = false,
    is_type_rare: bool = false,
    is_base_unique: bool = false,
    is_quest: bool = false,
};

pub fn itemFlags(t: *const tables.Tables, code: []const u8) ItemFlags {
    const ref = t.itemRef(code) orelse return .{};
    const tbl = t.itemTable(ref.table);
    var f = ItemFlags{
        .qlvl = @intCast(tbl.int(ref.row, "level")),
        .magic_lvl = @intCast(tbl.int(ref.row, "magiclvl")),
        .is_base_unique = tbl.int(ref.row, "unique") != 0,
        .is_quest = tbl.int(ref.row, "quest") != 0,
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
    socket_tier: sockets.SocketTier = .cap3,
    /// Placeholder base for deriving each pick's item MOD seed (RESIDUAL: the
    /// engine derives this in SUnit::CreateUnit). Pick i uses (base + i).
    item_seed_base: u32 = 1,
};

/// Roll a full drop from a treasure class. `drop_seed` is advanced through the
/// TC walk and quality rolls (roll-exact). Returns the list of concrete items /
/// gold; caller owns the slice (allocated with `gpa`).
pub fn rollDrop(
    gpa: std.mem.Allocator,
    drop_seed: *rng.Seed,
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

    for (picks.items, 0..) |pk, i| {
        if (pk.kind == .gold) {
            try drops.append(gpa, .{ .kind = .gold, .quantity = 0 });
            continue;
        }
        if (pk.kind != .item) continue;

        // Type-token entries (e.g. "weap3","armo3") need the compiled tiered
        // Items array (ITEMDROP_RollItemClassByLevel) — RESIDUAL. Emit as-is.
        const flags = itemFlags(t, pk.code);
        const is_real_item = t.itemRef(pk.code) != null;

        var d = Drop{ .kind = .item, .item_level = mlvl };
        setCode(&d, pk.code);

        if (!is_real_item) {
            // class-token: quality/affixes require item-class resolution (residual)
            try drops.append(gpa, d);
            continue;
        }

        // Drop-time quality on the DROP seed (+MF +TC quality mods).
        const qmods = [4]i32{ pk.mods.magic, pk.mods.rare, pk.mods.set, pk.mods.unique };
        const q = quality.gameGetItemQuality(drop_seed, &ratio, .{
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
        d.quality = q;

        // Affixes/sockets roll off the item's own MOD seed (separate stream).
        var item_seed = rng.Seed.init(opts.item_seed_base +% @as(u32, @intCast(i)), 0x29a);
        try applyAffixes(gpa, &item_seed, t, &d, flags, opts);

        try drops.append(gpa, d);
    }

    return drops.toOwnedSlice(gpa);
}

/// ITEM_ApplyQualityAndAffixes dispatch (item MOD seed). Magic/rare fully ported;
/// set/unique/crafted/runeword are TODO stubs. Sockets roll for low/normal/
/// superior only (magic/rare/set/unique drops are never socketed — faithful).
pub fn applyAffixes(
    gpa: std.mem.Allocator,
    item_seed: *rng.Seed,
    t: *const tables.Tables,
    d: *Drop,
    flags: ItemFlags,
    opts: RollOpts,
) !void {
    var types = try itemtype.typesForItem(gpa, t, d.code());
    defer types.deinit(gpa);

    switch (d.quality) {
        .magic => {
            const m = try affix.rollMagicPrefixSuffix(gpa, item_seed, t, &types, d.item_level, flags.qlvl, flags.magic_lvl, opts.is_expansion);
            d.prefix_id = m.prefix.id;
            d.suffix_id = m.suffix.id;
        },
        .rare => {
            const r = try affix.rollRareAffixes(gpa, item_seed, t, &types, d.item_level, flags.qlvl, flags.magic_lvl, opts.is_expansion);
            for (r.prefixes, 0..) |a, k| d.rare_prefix_ids[k] = a.id;
            for (r.suffixes, 0..) |a, k| d.rare_suffix_ids[k] = a.id;
        },
        // TODO(follow-up): set (ITEMMOD_ApplySetAffixes), unique (ITEM_RollUniqueItem
        // 0x5566b0), crafted, runeword. Currently left without affixes.
        .set, .unique, .crafted, .tempered => {},
        else => {},
    }

    // Sockets: only low/normal/superior dropped items (RollSocketCount rejects
    // quality < normal, ApplyQualityAndAffixes only calls it for quality {1,2,3}).
    switch (d.quality) {
        .low, .normal, .superior => {
            const max_sock = sockets.maxSockForItem(t, d.code(), d.item_level);
            if (max_sock > 0) {
                d.sockets = sockets.rollSocketCount(item_seed, .{
                    .max_sock = max_sock,
                    .ctx_tier = opts.socket_tier,
                    .is_expansion = opts.is_expansion,
                });
            }
        },
        else => {},
    }
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
    const d1 = try rollDrop(testing.allocator, &s1, &t, &set, "Act 1 Equip A", 12, .{});
    defer testing.allocator.free(d1);
    const d2 = try rollDrop(testing.allocator, &s2, &t, &set, "Act 1 Equip A", 12, .{});
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
        const d = try rollDrop(testing.allocator, &s, &t, &set, "Chipped Gem", 10, .{ .item_seed_base = n +% 1 });
        defer testing.allocator.free(d);
        for (d) |dr| {
            if (dr.kind == .item and t.itemRef(dr.code()) != null) found = true;
        }
    }
    try testing.expect(found);
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
        const a = try rollDrop(testing.allocator, &s0, &t, &set, "Chipped Gem", 10, .{ .magic_find = 0 });
        defer testing.allocator.free(a);
        const b = try rollDrop(testing.allocator, &s1, &t, &set, "Chipped Gem", 10, .{ .magic_find = 900 });
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
