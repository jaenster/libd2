//! TreasureClassEx resolution — the drop-selection heart.
//! Faithful to SERVER_ITEM_RollItemToDrop 0x55a6d0 (the weighted NoDrop walk +
//! nested-TC recursion) and TC_GetParsedTreasureClassByLevel 0x654e00 (the
//! group-chain level-variant selector).
//!
//! Roll model (per pick): total = totalWeight + NoDrop; roll an index in
//! [0,total) via the LCG (low-word % total, or (total-1)&low for power-of-two --
//! EXACTLY rng.pick / RANDOM_RandomNumberSelector). If index < NoDrop the pick
//! drops nothing; otherwise index -= NoDrop and we walk the cumulative entry
//! weights to select an entry. Sub-TC entries recurse (up to 64 deep); the
//! parent's quality modifiers propagate down as max(parent, child).
//!
//! NoDrop party-scaling (multiplayer): NoDrop' = TW * r^p / (1 - r^p) where
//! r = NoDrop/(NoDrop+TW), p = effective player count. Ported for completeness;
//! with players==1 (default) there is no scaling and the roll is unaffected.

const std = @import("std");
const rng = @import("rng.zig");
const txt = @import("txt.zig");
const tables = @import("tables.zig");
const model = @import("model.zig");
const QualityMods = model.QualityMods;

pub const Entry = struct {
    name: []const u8, // item code, sub-TC name, or "gld"
    prob: i32, // weight
    cum: i32 = 0, // cumulative weight (running sum), filled at build
};

pub const ParsedTC = struct {
    name: []const u8,
    group: i32,
    level: i32,
    picks: i32, // Picks column (negative = "each entry once" — see TODO)
    no_drop: i32,
    total_weight: i32,
    entries: []Entry,
    mods: QualityMods,
};

/// A single resolved drop candidate: either a concrete item pick or gold.
pub const Pick = struct {
    kind: model.DropKind,
    code: []const u8, // item code (kind == .item); "gld" for gold
    quantity_mult: i32 = 0, // gold/quiver quantity multiplier (nItemLinkNodeId)
    mods: QualityMods,
};

pub const TCSet = struct {
    list: []ParsedTC,
    by_name: std.StringHashMapUnmanaged(usize) = .{},
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TCSet) void {
        self.arena.deinit();
    }

    pub fn byName(self: *const TCSet, name: []const u8) ?*ParsedTC {
        const i = self.by_name.get(name) orelse return null;
        return &self.list[i];
    }

    /// TC_GetParsedTreasureClassByLevel: within a group chain (contiguous rows
    /// sharing nGroup), pick the highest variant whose level <= `level`.
    pub fn byLevel(self: *const TCSet, name: []const u8, level: i32) ?*ParsedTC {
        const start = self.by_name.get(name) orelse return null;
        const base = &self.list[start];
        if (level <= 0 or base.group == 0) return base;
        // Rows are stored in table order; the group chain is contiguous.
        var i = start;
        var best = start;
        while (i + 1 < self.list.len and self.list[i + 1].group == base.group) : (i += 1) {
            if (level < self.list[i + 1].level) break;
            best = i + 1;
        }
        return &self.list[best];
    }
};

pub fn build(gpa: std.mem.Allocator, t: *const tables.Tables) !TCSet {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const tbl = &t.treasure;

    var list: std.ArrayListUnmanaged(ParsedTC) = .empty;
    var by_name: std.StringHashMapUnmanaged(usize) = .{};

    for (0..tbl.rowCount()) |row| {
        const name = tbl.str(row, "Treasure Class");
        if (name.len == 0) continue;

        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        var total: i32 = 0;
        var k: usize = 1;
        while (k <= 10) : (k += 1) {
            var itembuf: [8]u8 = undefined;
            var probbuf: [8]u8 = undefined;
            const icol = std.fmt.bufPrint(&itembuf, "Item{d}", .{k}) catch unreachable;
            const pcol = std.fmt.bufPrint(&probbuf, "Prob{d}", .{k}) catch unreachable;
            const iname = tbl.str(row, icol);
            if (iname.len == 0) continue;
            const prob: i32 = @intCast(tbl.int(row, pcol));
            if (prob <= 0) continue;
            total += prob;
            try entries.append(a, .{ .name = try a.dupe(u8, iname), .prob = prob, .cum = total });
        }

        const idx = list.items.len;
        try list.append(a, .{
            .name = try a.dupe(u8, name),
            .group = @intCast(tbl.int(row, "group")),
            .level = @intCast(tbl.int(row, "level")),
            .picks = @intCast(tbl.int(row, "Picks")),
            .no_drop = @intCast(tbl.int(row, "NoDrop")),
            .total_weight = total,
            .entries = try entries.toOwnedSlice(a),
            .mods = .{
                .magic = @intCast(tbl.int(row, "Magic")),
                .rare = @intCast(tbl.int(row, "Rare")),
                .set = @intCast(tbl.int(row, "Set")),
                .unique = @intCast(tbl.int(row, "Unique")),
            },
        });
        // First definition wins (group-chain base is the first row of the name).
        if (!by_name.contains(name)) try by_name.put(a, list.items[idx].name, idx);
    }

    return .{ .list = try list.toOwnedSlice(a), .by_name = by_name, .arena = arena };
}

/// Effective NoDrop after party scaling (players>=1). players==1 -> unchanged.
pub fn scaledNoDrop(no_drop: i32, total_weight: i32, players: i32) i32 {
    if (players <= 1 or no_drop <= 0) return no_drop;
    const denom: f64 = @floatFromInt(no_drop + total_weight);
    const r: f64 = @as(f64, @floatFromInt(no_drop)) / denom;
    var factor: f64 = 1.0;
    var i: i32 = 0;
    while (i < players) : (i += 1) factor *= r;
    if (1.0 - factor == 0.0) return 0;
    const eff = @as(f64, @floatFromInt(total_weight)) * factor / (1.0 - factor);
    return @intFromFloat(@round(eff));
}

pub const ResolveOpts = struct {
    is_expansion: bool = true,
    players: i32 = 1,
    max_depth: u32 = 64,
};

/// Resolve one full drop from a TC: performs `picks` weighted rolls, recursing
/// into sub-TCs. Appends each concrete pick (item/gold) to `out`. Advances
/// `seed` exactly as the engine would (one LCG advance per weighted pick).
pub fn resolve(
    set: *const TCSet,
    seed: *rng.Seed,
    tc: *const ParsedTC,
    mlvl: i32,
    opts: ResolveOpts,
    parent_mods: QualityMods,
    out: *std.ArrayListUnmanaged(Pick),
    gpa: std.mem.Allocator,
    depth: u32,
) !void {
    if (depth >= opts.max_depth) return;
    if (tc.total_weight == 0) return;

    // Propagate quality mods: child inherits max(parent, own) per tier.
    const mods = QualityMods{
        .magic = @max(parent_mods.magic, tc.mods.magic),
        .rare = @max(parent_mods.rare, tc.mods.rare),
        .set = @max(parent_mods.set, tc.mods.set),
        .unique = @max(parent_mods.unique, tc.mods.unique),
    };

    // Picks: positive = that many independent weighted rolls.
    // Negative ("pick once each") is a distinct engine path — TODO.
    var picks = tc.picks;
    if (picks < 0) picks = -picks; // conservative: treat |picks| as count
    if (picks < 1) picks = 1;

    const no_drop = scaledNoDrop(tc.no_drop, tc.total_weight, opts.players);
    const total: u32 = @intCast(tc.total_weight + no_drop);

    var p: i32 = 0;
    while (p < picks) : (p += 1) {
        const index: i32 = @bitCast(seed.pick(total)); // low-word % total / pow2 mask
        if (index < no_drop) continue; // NoDrop won this pick
        const wanted = index - no_drop;

        // Walk cumulative weights to find the selected entry.
        var chosen: ?*const Entry = null;
        for (tc.entries) |*e| {
            if (wanted < e.cum) {
                chosen = e;
                break;
            }
        }
        const e = chosen orelse continue;

        if (set.byLevel(e.name, mlvl)) |sub| {
            // Nested TC: recurse.
            try resolve(set, seed, sub, mlvl, opts, mods, out, gpa, depth + 1);
        } else if (isGold(e.name)) {
            try out.append(gpa, .{ .kind = .gold, .code = "gld", .mods = mods });
        } else {
            try out.append(gpa, .{ .kind = .item, .code = e.name, .mods = mods });
        }
    }
}

fn isGold(name: []const u8) bool {
    return std.mem.eql(u8, name, "gld") or std.mem.startsWith(u8, name, "gld,");
}

const testing = std.testing;

test "build TCSet and resolve a common mob TC deterministically" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try build(testing.allocator, &t);
    defer set.deinit();

    try testing.expect(set.byName("Act 1 Equip A") != null);

    const tc = set.byLevel("Act 1 Equip A", 5).?;
    var out1: std.ArrayListUnmanaged(Pick) = .empty;
    defer out1.deinit(testing.allocator);
    var out2: std.ArrayListUnmanaged(Pick) = .empty;
    defer out2.deinit(testing.allocator);

    var s1 = rng.Seed.init(0xABCD, 0x29a);
    var s2 = rng.Seed.init(0xABCD, 0x29a);
    try resolve(&set, &s1, tc, 5, .{}, .{}, &out1, testing.allocator, 0);
    try resolve(&set, &s2, tc, 5, .{}, .{}, &out2, testing.allocator, 0);

    // Determinism: identical seed -> identical resolution.
    try testing.expectEqual(out1.items.len, out2.items.len);
    for (out1.items, out2.items) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqualStrings(a.code, b.code);
    }
    try testing.expectEqual(s1.low, s2.low);
}

test "TC resolves to plausible item codes / gold that exist in item tables" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try build(testing.allocator, &t);
    defer set.deinit();

    // "Chipped Gem" has direct leaf item codes (gcv, gcy, ...) that must resolve
    // to real Misc.txt entries.
    const tc = set.byLevel("Chipped Gem", 10).?;
    var found_valid = false;
    var n: u32 = 0;
    while (n < 500) : (n += 1) {
        var s = rng.Seed.init(n +% 1, 0x29a);
        var out: std.ArrayListUnmanaged(Pick) = .empty;
        defer out.deinit(testing.allocator);
        try resolve(&set, &s, tc, 10, .{}, .{}, &out, testing.allocator, 0);
        for (out.items) |pk| {
            if (pk.kind == .item and t.itemRef(pk.code) != null) found_valid = true;
        }
    }
    try testing.expect(found_valid);
}

test "party scaling reduces NoDrop as players increase" {
    // r = 100/(100+100)=0.5 ; p=2 -> factor=0.25 -> eff = 100*0.25/0.75 = 33.3 -> 33
    try testing.expectEqual(@as(i32, 100), scaledNoDrop(100, 100, 1));
    try testing.expectEqual(@as(i32, 33), scaledNoDrop(100, 100, 2));
    try testing.expect(scaledNoDrop(100, 100, 5) < scaledNoDrop(100, 100, 2));
}
