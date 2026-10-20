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
//! A NEGATIVE Picks column means "one of each entry, in order": the engine skips
//! the RNG entirely and walks the cumulative weights with a running index
//! 0,1,2,... (|Picks| - remaining), stopping once it passes the total weight.
//! That is how act bosses drop several distinct items — and, because no LCG
//! advance happens, getting it wrong desyncs every later roll off the same seed.
//!
//! NoDrop party-scaling (multiplayer): NoDrop' = TW * r^p / (1 - r^p) where
//! r = NoDrop/(NoDrop+TW), p = effective player count. Ported for completeness;
//! with players==1 (default) there is no scaling and the roll is unaffected.
//!
//! Cumulative weights are EXCLUSIVE running sums (AddOneParsedTCEntry 0x654080
//! stamps the total *before* the entry is added), so entry i covers
//! [cum[i], cum[i+1]) and selection is "the last entry whose cum <= index".
//! Classic and expansion carry separate sums: an entry is expansion-only when its
//! base item's Items.txt version >= 100, or when a nested TC has no classic
//! weight at all (TC_ParseTreasureClassEntry 0x654440 / AdjustRarities 0x6540c0).

const std = @import("std");
const rng = @import("rng.zig");
const txt = @import("txt.zig");
const tables = @import("tables.zig");
const model = @import("model.zig");
const QualityMods = model.QualityMods;

pub const Entry = struct {
    name: []const u8, // item code, sub-TC name, or "gld"
    prob: i32, // weight
    cum: i32 = 0, // exclusive running sum, expansion
    cum_classic: i32 = 0, // exclusive running sum, classic
    /// TC_Expansion (0x10): the entry contributes to the expansion weights only.
    expansion_only: bool = false,
    /// "mul=" modifier — the gold quantity multiplier (nItemLinkNodeId), 0 = none.
    mul: i32 = 0,
    /// TC_Unique (0x11) / TC_Set (0x12): the cell named a UniqueItems / SetItems `index` rather than a
    /// base item code, so `name` has been resolved to that row's base item and the drop's quality plus
    /// its exact row are forced — GAME_GetItemQuality never runs for these.
    link_quality: model.Quality = .invalid,
    link_id: u16 = 0,
    /// The per-entry quality modifiers of the cell (`cm=`, `cr=`, `cs=`, `cu=`, `ce=`, `cg=`;
    /// TC_ParseTreasureClassEntry 0x654440 stores them at +0xE..+0x18 of the entry). Only a Classic
    /// game reads them (SERVER_ITEM_RollItemToDrop 0x55a6d0): picking such an item entry raises the
    /// current class's running modifiers to at least these, for this pick and every later pick of it.
    entry_mods: QualityMods = .{},
    /// The base item's own ItemTypes row is Throwable: a Classic game picks again (0x55a6d0).
    throwable: bool = false,
    /// The base item's Items.txt version: a Classic game drops nothing for 100 and up (0x55a6d0).
    item_version: i32 = 0,
};

pub const ParsedTC = struct {
    name: []const u8,
    group: i32,
    level: i32,
    /// Picks column. Negative = "walk the entries once each" (no RNG).
    picks: i32,
    no_drop: i32,
    total_weight: i32,
    total_weight_classic: i32 = 0,
    entries: []Entry,
    mods: QualityMods,

    pub fn totalWeight(self: *const ParsedTC, is_expansion: bool) i32 {
        return if (is_expansion) self.total_weight else self.total_weight_classic;
    }
};

/// Weight bookkeeping shared by the TreasureClassEx parser and the auto-generated
/// item-type TCs: AddOneParsedTCEntry 0x654080 stamps the current totals onto the
/// new entry, AdjustRarities 0x6540c0 then adds its weight to the running totals
/// (classic only when the entry is not expansion-only).
const Builder = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    total: i32 = 0,
    total_classic: i32 = 0,

    fn add(self: *Builder, a: std.mem.Allocator, e: Entry) !void {
        var entry = e;
        entry.cum = self.total;
        entry.cum_classic = self.total_classic;
        try self.entries.append(a, entry);
        self.total += e.prob;
        if (!e.expansion_only) self.total_classic += e.prob;
    }
};

/// A single resolved drop candidate: either a concrete item pick or gold.
pub const Pick = struct {
    kind: model.DropKind,
    code: []const u8, // item code (kind == .item); "gld" for gold
    quantity_mult: i32 = 0, // gold/quiver quantity multiplier (nItemLinkNodeId)
    mods: QualityMods,
    /// Forced quality + 1-based UniqueItems/SetItems row for a TC unique/set link entry.
    forced_quality: model.Quality = .invalid,
    forced_id: u16 = 0,
    /// The drop-time quality, when the walk was given a `QualityRoll`: rolled at the pick, on the walk's seed,
    /// as 0x55a6d0 does (between this pick's draw and the next).
    quality: model.Quality = .invalid,
};

/// GAME_GetItemQuality for one picked base, on the walk's own seed: the engine rolls it right after the pick,
/// before the next pick's draw (and before the Classic thrown re-pick, so a thrown pick spends its draws too).
pub const QualityRoll = struct {
    ctx: *const anyopaque,
    roll: *const fn (ctx: *const anyopaque, seed: *rng.Seed, code: []const u8, mods: QualityMods) model.Quality,
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

/// TXT_AllocItemDropData 0x65a390 builds the TC array in exactly this order: the
/// auto-generated item-type classes first, then the TreasureClassEx.txt rows — so a
/// row's "armo3"/"weap24" entry resolves against classes that already exist.
pub fn build(gpa: std.mem.Allocator, t: *const tables.Tables) !TCSet {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const tbl = &t.treasure;

    var list: std.ArrayListUnmanaged(ParsedTC) = .empty;
    var by_name: std.StringHashMapUnmanaged(usize) = .{};

    try generateItemTypeClasses(a, t, &list, &by_name);

    for (0..tbl.rowCount()) |row| {
        const name = tbl.str(row, "Treasure Class");
        if (name.len == 0) continue;

        var b = Builder{};
        var k: usize = 1;
        while (k <= 10) : (k += 1) {
            var itembuf: [8]u8 = undefined;
            var probbuf: [8]u8 = undefined;
            const icol = std.fmt.bufPrint(&itembuf, "Item{d}", .{k}) catch unreachable;
            const pcol = std.fmt.bufPrint(&probbuf, "Prob{d}", .{k}) catch unreachable;
            const field = tbl.str(row, icol);
            if (field.len == 0) continue;
            const prob: i32 = @intCast(tbl.int(row, pcol));
            if (prob <= 0) continue; // TC_ParseTreasureClassEntry bails on Prob < 1

            const parsed = parseEntryField(field);
            const link = resolveLink(t, parsed.code);
            const code = if (link) |l| l.base_code else parsed.code;
            const base = baseFacts(t, code);
            try b.add(a, .{
                .name = try a.dupe(u8, code),
                .prob = prob,
                .mul = parsed.mul,
                .link_quality = if (link) |l| l.quality else .invalid,
                .link_id = if (link) |l| l.id else 0,
                .expansion_only = if (link != null) true else entryIsExpansionOnly(t, &list, &by_name, parsed.code),
                .entry_mods = parsed.mods,
                .throwable = base.throwable,
                .item_version = base.version,
            });
        }

        const idx = list.items.len;
        try list.append(a, .{
            .name = try a.dupe(u8, name),
            .group = @intCast(tbl.int(row, "group")),
            .level = @intCast(tbl.int(row, "level")),
            .picks = @intCast(tbl.int(row, "Picks")),
            .no_drop = @intCast(tbl.int(row, "NoDrop")),
            .total_weight = b.total,
            .total_weight_classic = b.total_classic,
            .entries = try b.entries.toOwnedSlice(a),
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

/// An Item column is `code[,key=value]*` (TC_ParseTreasureClassEntry 0x654440): `mul` (and `ma`/`mg`,
/// which land in the same field) is the gold quantity multiplier; `cm`/`cr`/`cs`/`cu`/`ce`/`cg` are the
/// entry's own quality modifiers, which only a Classic game reads.
fn parseEntryField(field: []const u8) struct { code: []const u8, mul: i32, mods: QualityMods } {
    var rest = std.mem.trim(u8, field, "\"");
    var code = rest;
    var mul: i32 = 0;
    var mods: QualityMods = .{};
    if (std.mem.indexOfScalar(u8, rest, ',')) |c| {
        code = rest[0..c];
        rest = rest[c + 1 ..];
        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |mod| {
            const eq = std.mem.indexOfScalar(u8, mod, '=') orelse continue;
            const key = mod[0..eq];
            const v = std.fmt.parseInt(i32, mod[eq + 1 ..], 10) catch 0;
            if (std.mem.eql(u8, key, "mul") or std.mem.eql(u8, key, "ma") or std.mem.eql(u8, key, "mg")) mul = v;
            if (std.mem.eql(u8, key, "cm")) mods.magic = v;
            if (std.mem.eql(u8, key, "cr")) mods.rare = v;
            if (std.mem.eql(u8, key, "cs")) mods.set = v;
            if (std.mem.eql(u8, key, "cu")) mods.unique = v;
        }
    }
    return .{ .code = code, .mul = mul, .mods = mods };
}

/// What the Classic walk needs to know of an entry's base item: its version and whether its own type
/// (not an Equiv parent: TXT_ItemTypes_CheckIfTypeIsThrowable 0x628860) is Throwable.
fn baseFacts(t: *const tables.Tables, code: []const u8) struct { version: i32, throwable: bool } {
    const ref = t.itemRef(code) orelse return .{ .version = 0, .throwable = false };
    const tbl = t.itemTable(ref.table);
    const type_row = t.itype_by_code.get(tbl.str(ref.row, "type"));
    return .{
        .version = @intCast(tbl.int(ref.row, "version")),
        .throwable = if (type_row) |r| t.item_types.int(r, "Throwable") != 0 else false,
    };
}

/// TC_ParseTreasureClassEntry tries any cell of 5+ characters against the UniqueItems and then the
/// SetItems link tables; a hit stores the row id plus that row's base item class and stamps the entry
/// TC_Unique / TC_Set. (The monster link table it tries first drives body-part drops, which this
/// package does not model.)
fn resolveLink(t: *const tables.Tables, code: []const u8) ?struct { quality: model.Quality, id: u16, base_code: []const u8 } {
    if (code.len < 5) return null;
    for (0..t.unique_items.rowCount()) |row| {
        if (!std.mem.eql(u8, t.unique_items.str(row, "index"), code)) continue;
        return .{ .quality = .unique, .id = @intCast(row + 1), .base_code = t.unique_items.str(row, "code") };
    }
    for (0..t.set_items.rowCount()) |row| {
        if (!std.mem.eql(u8, t.set_items.str(row, "index"), code)) continue;
        return .{ .quality = .set, .id = @intCast(row + 1), .base_code = t.set_items.str(row, "item") };
    }
    return null;
}

/// TC_ParseTreasureClassEntry: a base item is expansion-only when its Items.txt
/// version >= 100; a nested TC is expansion-only when it has no classic weight;
/// unique/set link entries are always expansion-only.
fn entryIsExpansionOnly(
    t: *const tables.Tables,
    list: *const std.ArrayListUnmanaged(ParsedTC),
    by_name: *const std.StringHashMapUnmanaged(usize),
    code: []const u8,
) bool {
    if (code.len < 5) {
        if (t.itemRef(code)) |ref| {
            return t.itemTable(ref.table).int(ref.row, "version") >= 100;
        }
    }
    if (by_name.get(code)) |i| return list.items[i].total_weight_classic == 0;
    return true;
}

/// TC_GenerateAutoItemTypeTreasureClasses 0x6541c0 — every ItemTypes.txt row with
/// TreasureClass set gets one TC per level band ("armo3", "armo6", … "armo96"),
/// holding each spawnable non-quest item of that type whose qlvl falls in
/// (band-3, band]. Entry weight is the item's own type Rarity, floored at 1.
/// Without these, every "weap3"/"armo24" entry in TreasureClassEx.txt is a dangling
/// name and monster drops resolve to nothing.
fn generateItemTypeClasses(
    a: std.mem.Allocator,
    t: *const tables.Tables,
    list: *std.ArrayListUnmanaged(ParsedTC),
    by_name: *std.StringHashMapUnmanaged(usize),
) !void {
    // Missile potions are excluded from every auto class except their own.
    const tpot: i32 = if (t.itypeRow("tpot")) |r| @intCast(r) else -1;

    for (0..t.item_types.rowCount()) |ti| {
        if (t.item_types.int(ti, "TreasureClass") == 0) continue;
        const type_code = t.item_types.str(ti, "Code");
        if (type_code.len == 0) continue;

        var band: i32 = 3;
        while (band < 97) : (band += 3) {
            var b = Builder{};
            for (t.item_classes, 0..) |ic, class_id| {
                if (ic.quest or !ic.spawnable) continue;
                if (!t.isOfType(class_id, @intCast(ti))) continue;
                if (ti != tpot and t.isOfType(class_id, tpot)) continue;
                if (ic.level <= band - 3 or ic.level > band) continue;
                if (ic.type_idx < 0) continue; // ItemTypes_GetLine(type) == null
                const rarity: i32 = @intCast(t.item_types.int(@intCast(ic.type_idx), "Rarity"));
                try b.add(a, .{
                    .name = ic.code,
                    .prob = @max(rarity, 1),
                    .expansion_only = ic.version >= 100,
                    .throwable = t.item_types.int(@intCast(ic.type_idx), "Throwable") != 0,
                    .item_version = ic.version,
                });
            }

            const name = try std.fmt.allocPrint(a, "{s}{d}", .{ type_code, band });
            const idx = list.items.len;
            try list.append(a, .{
                .name = name,
                .group = 0,
                .level = band - 3,
                .picks = 1,
                .no_drop = 0,
                .total_weight = b.total,
                .total_weight_classic = b.total_classic,
                .entries = try b.entries.toOwnedSlice(a),
                .mods = .{},
            });
            if (!by_name.contains(name)) try by_name.put(a, name, idx);
        }
    }
}

/// The NoDrop weight after the player scale (SERVER_ITEM_RollItemToDrop 0x55a6d0): for `players`
/// above 1, NoDrop' = trunc(TW * r^n / (1 - r^n)) with r = NoDrop / (NoDrop + TW), the power taken by
/// repeated x87 multiplication and the quotient truncated (`_ftol`); 0 when r^n is 1. `players` is the
/// effective count `effectivePlayers` gives.
pub fn scaledNoDrop(no_drop: i32, total_weight: i32, players: i32) i32 {
    if (players <= 1 or no_drop <= 0) return no_drop;
    const r: f64 = @as(f64, @floatFromInt(no_drop)) / @as(f64, @floatFromInt(no_drop + total_weight));
    var pow: f64 = r;
    var i: i32 = 1;
    while (i < players) : (i += 1) pow *= r;
    const keep = 1.0 - pow;
    if (keep == 0.0) return 0;
    return @intFromFloat(@trunc((1.0 - keep) * @as(f64, @floatFromInt(total_weight)) / keep));
}

/// The player count the NoDrop scale uses (0x55a6d0): the killer's party members counted by
/// CountDeadPartyMembers (1 for no party or one member, at most 8), plus half (rounded down) of the
/// other players in the game, capped by the monster's `monster_playercount` stat (floored at 1), which
/// the game sets from its player count when the monster spawns.
pub fn effectivePlayers(players_in_game: i32, party_near: i32, monster_playercount: i32) i32 {
    const near: i32 = if (party_near < 2) 1 else @min(party_near, 8);
    const n = near + @divTrunc(players_in_game - near, 2);
    return @min(n, @max(monster_playercount, 1));
}

/// Whether the dropping monster's treasure class is moved up its group chain to the monster's level
/// (SERVER_ITEM_RollItemAndGetTreasureClass 0x55afa0): only in an Expansion game, above Normal, for a
/// monster whose MonStats row is neither `boss` nor `noRatio`. A nested class is never moved
/// (0x55a6d0 asks TC_GetParsedTreasureClassByLevel 0x654e00 for level 0).
pub fn upgradesTreasureClass(is_expansion: bool, difficulty: u8, boss: bool, no_ratio: bool) bool {
    return is_expansion and difficulty != 0 and !boss and !no_ratio;
}

pub const ResolveOpts = struct {
    is_expansion: bool = true,
    /// The effective player count (`effectivePlayers`).
    players: i32 = 1,
    max_depth: u32 = 64,
    /// Find-Item drops bypass NoDrop entirely (bIsItemFindDrop).
    bypass_no_drop: bool = false,
    /// The engine stops the whole walk once this many items exist; a monster death
    /// passes no unit table, which SERVER_ITEM_RollItemToDrop turns into 6.
    max_items: i32 = 6,
    /// Roll each item's quality at its pick (`Pick.quality`); null leaves it to the caller.
    quality_roll: ?QualityRoll = null,
};

/// What one walk keeps across its nested classes: the Classic re-picks of thrown items are counted
/// over the whole walk (0x55a6d0's nThrowableCount), not per class.
pub const WalkState = struct {
    thrown_repicks: i32 = 0,
};

/// The base a Classic walk drops in place of an eleventh thrown item: 0x55aeb5 converts the code
/// `lsd ` (a Long Sword).
pub const classic_thrown_fallback = "lsd";

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
    var state: WalkState = .{};
    return resolveWalk(set, seed, tc, mlvl, opts, parent_mods, out, gpa, depth, &state);
}

pub fn resolveWalk(
    set: *const TCSet,
    seed: *rng.Seed,
    tc: *const ParsedTC,
    mlvl: i32,
    opts: ResolveOpts,
    parent_mods: QualityMods,
    out: *std.ArrayListUnmanaged(Pick),
    gpa: std.mem.Allocator,
    depth: u32,
    state: *WalkState,
) !void {
    _ = mlvl;
    if (depth >= opts.max_depth) return;
    const total_weight = tc.totalWeight(opts.is_expansion);
    if (total_weight == 0) return;

    // A pushed class takes each of the parent's modifiers unless the parent's is 0 or lower than its
    // own (0x55abf0); the root class takes its own.
    var mods = if (depth == 0) tc.mods else QualityMods{
        .magic = inherit(parent_mods.magic, tc.mods.magic),
        .rare = inherit(parent_mods.rare, tc.mods.rare),
        .set = inherit(parent_mods.set, tc.mods.set),
        .unique = inherit(parent_mods.unique, tc.mods.unique),
    };

    // Picks: |Picks|, floored at 1. Negative additionally switches the selection
    // from a weighted roll to a straight walk over the entries.
    const each_once = tc.picks < 0;
    const picks = @max(if (each_once) -tc.picks else tc.picks, 1);

    const no_drop = if (opts.bypass_no_drop) 0 else scaledNoDrop(tc.no_drop, total_weight, opts.players);

    var remaining = picks;
    while (remaining > 0) {
        if (opts.max_items > 0 and out.items.len >= @as(usize, @intCast(opts.max_items))) return;

        var wanted: i32 = undefined;
        if (each_once) {
            wanted = picks - remaining; // 0, 1, 2, … — no LCG advance at all
            if (total_weight <= wanted) return;
            remaining -= 1;
        } else {
            const total = if (opts.bypass_no_drop) total_weight else total_weight + no_drop;
            const index: i32 = if (total < 1) 0 else @bitCast(seed.pick(@intCast(total)));
            remaining -= 1;
            if (!opts.bypass_no_drop and index < no_drop) continue; // NoDrop won this pick
            wanted = if (opts.bypass_no_drop) index else index - no_drop;
        }

        const e = selectEntry(tc, wanted, opts.is_expansion) orelse continue;

        if (set.byName(e.name)) |sub| {
            // Nested TC: recurse, never level-moved.
            try resolveWalk(set, seed, sub, 0, opts, mods, out, gpa, depth + 1, state);
        } else if (isGold(e.name)) {
            try out.append(gpa, .{ .kind = .gold, .code = "gld", .quantity_mult = e.mul, .mods = mods });
        } else {
            var code = e.name;
            var rolled: model.Quality = .invalid;
            if (!opts.is_expansion) {
                // Classic: a base of version 100 or more drops nothing; the entry's own modifiers raise
                // the class's; a thrown base is picked again, ten times per walk, then a Long Sword.
                if (e.item_version > 99) continue;
                mods = .{
                    .magic = @max(mods.magic, e.entry_mods.magic),
                    .rare = @max(mods.rare, e.entry_mods.rare),
                    .set = @max(mods.set, e.entry_mods.set),
                    .unique = @max(mods.unique, e.entry_mods.unique),
                };
            }
            if (opts.quality_roll) |qr| if (e.link_quality == .invalid) {
                rolled = qr.roll(qr.ctx, seed, e.name, mods);
            };
            if (!opts.is_expansion) {
                if (e.throwable) {
                    if (state.thrown_repicks < 10) {
                        state.thrown_repicks += 1;
                        remaining += 1;
                        continue;
                    }
                    state.thrown_repicks += 1;
                    code = classic_thrown_fallback;
                }
            }
            try out.append(gpa, .{
                .kind = .item,
                .code = code,
                .quantity_mult = e.mul,
                .mods = mods,
                .forced_quality = e.link_quality,
                .forced_id = e.link_id,
                .quality = rolled,
            });
        }
    }
}

fn inherit(parent: i32, own: i32) i32 {
    if (parent == 0) return own;
    return if (own <= parent) parent else own;
}

/// The last entry whose exclusive cumulative weight is <= `wanted` (the engine's
/// expansion binary search / classic linear scan). Classic skips expansion entries,
/// which carry no classic weight.
fn selectEntry(tc: *const ParsedTC, wanted: i32, is_expansion: bool) ?*const Entry {
    var chosen: ?*const Entry = null;
    for (tc.entries) |*e| {
        if (!is_expansion and e.expansion_only) continue;
        const cum = if (is_expansion) e.cum else e.cum_classic;
        if (cum > wanted) break;
        chosen = e;
    }
    return chosen;
}

fn isGold(name: []const u8) bool {
    return std.mem.eql(u8, name, "gld");
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

test "auto item-type classes exist and every TreasureClassEx reference resolves" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try build(testing.allocator, &t);
    defer set.deinit();

    // The five ItemTypes rows with TreasureClass set, banded 3..96 step 3.
    for ([_][]const u8{ "armo", "weap", "mele", "bow", "abow" }) |code| {
        var band: i32 = 3;
        while (band < 97) : (band += 3) {
            var buf: [16]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "{s}{d}", .{ code, band });
            try testing.expect(set.byName(name) != null);
        }
    }

    // No TreasureClassEx entry may name something that is neither a TC, a base item
    // code nor gold — that was the "class-token residual".
    for (0..t.treasure.rowCount()) |row| {
        if (t.treasure.str(row, "Treasure Class").len == 0) continue;
        var k: usize = 1;
        while (k <= 10) : (k += 1) {
            var buf: [8]u8 = undefined;
            const field = t.treasure.str(row, std.fmt.bufPrint(&buf, "Item{d}", .{k}) catch unreachable);
            if (field.len == 0) continue;
            const code = parseEntryField(field).code;
            if (set.byName(code) != null or t.itemRef(code) != null or isGold(code)) continue;
            // Unique/set link entries name a UniqueItems/SetItems row, not a base item.
            var known = false;
            for (0..t.unique_items.rowCount()) |u| {
                if (std.mem.eql(u8, t.unique_items.str(u, "index"), code)) known = true;
            }
            for (0..t.set_items.rowCount()) |s| {
                if (std.mem.eql(u8, t.set_items.str(s, "index"), code)) known = true;
            }
            try testing.expect(known);
        }
    }
}

test "armo3 holds only spawnable armor of qlvl 1..3" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try build(testing.allocator, &t);
    defer set.deinit();

    const tc = set.byName("armo3").?;
    try testing.expectEqual(@as(i32, 1), tc.picks);
    try testing.expect(tc.entries.len > 0);
    try testing.expect(tc.total_weight > 0);
    for (tc.entries) |e| {
        const ref = t.itemRef(e.name).?;
        const tbl = t.itemTable(ref.table);
        const lvl = tbl.int(ref.row, "level");
        try testing.expect(lvl >= 1 and lvl <= 3);
        try testing.expect(tbl.int(ref.row, "spawnable") != 0);
        try testing.expect(e.prob >= 1);
    }
    // Cumulative weights are exclusive running sums.
    var expect_cum: i32 = 0;
    for (tc.entries) |e| {
        try testing.expectEqual(expect_cum, e.cum);
        expect_cum += e.prob;
    }
    try testing.expectEqual(expect_cum, tc.total_weight);
}

test "negative Picks walks each entry once and never advances the seed" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try build(testing.allocator, &t);
    defer set.deinit();

    // "Act 1 Champ A": Picks -2 over [Act 1 Citem A (1), Act 1 Cpot A (2)].
    const tc = set.byName("Act 1 Champ A").?;
    try testing.expectEqual(@as(i32, -2), tc.picks);

    // Both entries are sub-TCs whose own (positive) picks still roll, so here we can
    // only assert that the walk visits them; the RNG-free property is checked below.
    var seed = rng.Seed.init(0x1234, 0x29a);
    var out: std.ArrayListUnmanaged(Pick) = .empty;
    defer out.deinit(testing.allocator);
    try resolve(&set, &seed, tc, 10, .{}, .{}, &out, testing.allocator, 0);
    try testing.expect(out.items.len >= 1);

    // A synthetic leaf TC exercises the RNG-free walk directly.
    var entries = [_]Entry{
        .{ .name = "gcv", .prob = 1, .cum = 0 },
        .{ .name = "gcy", .prob = 1, .cum = 1 },
        .{ .name = "gcb", .prob = 1, .cum = 2 },
    };
    const leaf = ParsedTC{
        .name = "synthetic",
        .group = 0,
        .level = 0,
        .picks = -3,
        .no_drop = 0,
        .total_weight = 3,
        .total_weight_classic = 3,
        .entries = &entries,
        .mods = .{},
    };
    var s2 = rng.Seed.init(0x1234, 0x29a);
    var picks: std.ArrayListUnmanaged(Pick) = .empty;
    defer picks.deinit(testing.allocator);
    try resolve(&set, &s2, &leaf, 10, .{}, .{}, &picks, testing.allocator, 0);
    try testing.expectEqual(@as(u32, 0x1234), s2.low); // no LCG advance
    try testing.expectEqual(@as(usize, 3), picks.items.len);
    try testing.expectEqualStrings("gcv", picks.items[0].code);
    try testing.expectEqualStrings("gcy", picks.items[1].code);
    try testing.expectEqualStrings("gcb", picks.items[2].code);
}

test "gld,mul= carries the gold quantity multiplier" {
    try testing.expectEqualStrings("gld", parseEntryField("\"gld,mul=1280\"").code);
    try testing.expectEqual(@as(i32, 1280), parseEntryField("\"gld,mul=1280\"").mul);
    try testing.expectEqualStrings("gcv", parseEntryField("gcv").code);
    try testing.expectEqual(@as(i32, 0), parseEntryField("gcv").mul);
}

test "party scaling reduces NoDrop as players increase" {
    // r = 100/(100+100)=0.5 ; p=2 -> factor=0.25 -> eff = 100*0.25/0.75 = 33.3 -> 33
    try testing.expectEqual(@as(i32, 100), scaledNoDrop(100, 100, 1));
    try testing.expectEqual(@as(i32, 33), scaledNoDrop(100, 100, 2));
    try testing.expect(scaledNoDrop(100, 100, 5) < scaledNoDrop(100, 100, 2));
}

test "Classic counts no Expansion entry: Andarielq (H) weighs 22 of 23, and its Key of Terror never drops" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try build(testing.allocator, &t);
    defer set.deinit();
    const tc = set.byName("Andarielq (H)").?;
    try testing.expectEqual(@as(i32, 23), tc.total_weight);
    try testing.expectEqual(@as(i32, 22), tc.total_weight_classic);
    var n: u32 = 0;
    while (n < 2000) : (n += 1) {
        var s = rng.Seed.init(n *% 2654435761 +% 1, 0x29a);
        var out: std.ArrayListUnmanaged(Pick) = .empty;
        defer out.deinit(testing.allocator);
        try resolve(&set, &s, tc, 75, .{ .is_expansion = false }, .{}, &out, testing.allocator, 0);
        for (out.items) |p| {
            try testing.expect(!std.mem.eql(u8, p.code, "tes"));
            if (t.itemRef(p.code)) |ref| try testing.expect(t.itemTable(ref.table).int(ref.row, "version") < 100);
        }
    }
}

test "Classic picks again for a thrown base, ten times in a walk, then drops a Long Sword" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try build(testing.allocator, &t);
    defer set.deinit();
    var entries = [_]Entry{.{ .name = "tkf", .prob = 1, .cum = 0, .cum_classic = 0, .throwable = true }};
    const leaf = ParsedTC{ .name = "thrown", .group = 0, .level = 0, .picks = 3, .no_drop = 0, .total_weight = 1, .total_weight_classic = 1, .entries = &entries, .mods = .{} };
    var s = rng.Seed.init(7, 0x29a);
    var out: std.ArrayListUnmanaged(Pick) = .empty;
    defer out.deinit(testing.allocator);
    try resolve(&set, &s, &leaf, 10, .{ .is_expansion = false }, .{}, &out, testing.allocator, 0);
    // picks 1..10 are thrown and picked again; the 11th, 12th and 13th draws are Long Swords
    try testing.expectEqual(@as(usize, 3), out.items.len);
    for (out.items) |p| try testing.expectEqualStrings("lsd", p.code);
    // Expansion keeps the thrown base
    var s2 = rng.Seed.init(7, 0x29a);
    var out2: std.ArrayListUnmanaged(Pick) = .empty;
    defer out2.deinit(testing.allocator);
    try resolve(&set, &s2, &leaf, 10, .{ .is_expansion = true }, .{}, &out2, testing.allocator, 0);
    try testing.expectEqual(@as(usize, 3), out2.items.len);
    try testing.expectEqualStrings("tkf", out2.items[0].code);
}

test "the player scale truncates, and the effective count is the party plus half the rest" {
    // r = 19/41, n = 2: 22 * r^2 / (1 - r^2) = 6.04... -> 6
    try testing.expectEqual(@as(i32, 6), scaledNoDrop(19, 22, 2));
    try testing.expectEqual(@as(i32, 19), scaledNoDrop(19, 22, 1));
    try testing.expectEqual(@as(i32, 1), effectivePlayers(1, 1, 1));
    try testing.expectEqual(@as(i32, 4), effectivePlayers(8, 1, 8)); // alone among 8: 1 + 7/2
    try testing.expectEqual(@as(i32, 8), effectivePlayers(8, 8, 8));
    try testing.expectEqual(@as(i32, 3), effectivePlayers(8, 8, 3)); // the monster's count caps it
    try testing.expect(!upgradesTreasureClass(false, 2, false, false));
    try testing.expect(!upgradesTreasureClass(true, 0, false, false));
    try testing.expect(!upgradesTreasureClass(true, 2, true, false));
    try testing.expect(upgradesTreasureClass(true, 2, false, false));
}
