//! Typed views over the D2 1.14d item-generation excel tables.
//!
//! Every table generation reads is embedded via @embedFile so the port is
//! self-contained (data\global\excel\*.txt). Column names match the 1.14d
//! headers verbatim; empty cells read as 0 (D2 convention, see txt.zig).

const std = @import("std");
const txt = @import("txt.zig");
const d2data = @import("d2-data");

pub const Tables = struct {
    treasure: txt.Table,
    item_ratio: txt.Table,
    item_types: txt.Table,
    weapons: txt.Table,
    armor: txt.Table,
    misc: txt.Table,
    magic_prefix: txt.Table,
    magic_suffix: txt.Table,
    rare_prefix: txt.Table,
    rare_suffix: txt.Table,
    item_stat_cost: txt.Table,
    unique_items: txt.Table,
    set_items: txt.Table,
    runes: txt.Table,
    quality_items: txt.Table,
    properties: txt.Table,

    /// TreasureClass name -> row index (built once at load).
    tc_by_name: std.StringHashMapUnmanaged(usize) = .{},
    /// Item Code (weapon/armor/misc `code`) -> {table, row}.
    item_by_code: std.StringHashMapUnmanaged(ItemRef) = .{},
    /// ItemTypes Code -> row index.
    itype_by_code: std.StringHashMapUnmanaged(usize) = .{},

    /// The compiled unified Items array, in engine item-class-id order.
    item_classes: []ItemClass = &.{},
    /// Per ItemTypes row, the bitmask of every type it is equivalent to (itself plus
    /// the transitive Equiv1/Equiv2 closure) — the engine's pTxtItemTypesUnknown
    /// lattice, stride `equiv_stride` u32s per row.
    itype_equiv: []u32 = &.{},
    equiv_stride: usize = 0,

    arena: std.heap.ArenaAllocator,

    pub const ItemTable = enum { weapons, armor, misc };
    pub const ItemRef = struct { table: ItemTable, row: usize };

    /// One record of the engine's compiled unified Items array — the index space
    /// TXT_Items_GetLine 0x6335a0 addresses. Built by TXT_AllocTxt_items 0x6315d0 as
    /// Weapons.txt rows, then Armor.txt, then Misc.txt, each in file order.
    pub const ItemClass = struct {
        code: []const u8,
        ref: ItemRef,
        /// ItemTypes row of `type` / `type2` (D2ItemsTxt.wType / wType2), -1 if absent.
        type_idx: i32 = -1,
        type2_idx: i32 = -1,
        level: i32 = 0,
        version: i32 = 0,
        rarity: i32 = 0,
        spawnable: bool = false,
        quest: bool = false,
    };


    pub fn load(gpa: std.mem.Allocator) !Tables {
        var t = Tables{
            .treasure = try txt.Table.parse(gpa, d2data.file("TreasureClassEx")),
            .item_ratio = try txt.Table.parse(gpa, d2data.file("ItemRatio")),
            .item_types = try txt.Table.parse(gpa, d2data.file("ItemTypes")),
            .weapons = try txt.Table.parse(gpa, d2data.file("Weapons")),
            .armor = try txt.Table.parse(gpa, d2data.file("Armor")),
            .misc = try txt.Table.parse(gpa, d2data.file("Misc")),
            .magic_prefix = try txt.Table.parse(gpa, d2data.file("MagicPrefix")),
            .magic_suffix = try txt.Table.parse(gpa, d2data.file("MagicSuffix")),
            .rare_prefix = try txt.Table.parse(gpa, d2data.file("RarePrefix")),
            .rare_suffix = try txt.Table.parse(gpa, d2data.file("RareSuffix")),
            .item_stat_cost = try txt.Table.parse(gpa, d2data.file("ItemStatCost")),
            .unique_items = try txt.Table.parse(gpa, d2data.file("UniqueItems")),
            .set_items = try txt.Table.parse(gpa, d2data.file("SetItems")),
            .runes = try txt.Table.parse(gpa, d2data.file("Runes")),
            .quality_items = try txt.Table.parse(gpa, d2data.file("QualityItems")),
            .properties = try txt.Table.parse(gpa, d2data.file("Properties")),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        const a = t.arena.allocator();

        for (t.treasure.rows, 0..) |_, i| {
            const name = t.treasure.str(i, "Treasure Class");
            if (name.len != 0) try t.tc_by_name.put(a, name, i);
        }
        for (t.item_types.rows, 0..) |_, i| {
            const code = t.item_types.str(i, "Code");
            if (code.len != 0) try t.itype_by_code.put(a, code, i);
        }
        const item_tabs = [_]struct { tbl: *const txt.Table, tag: ItemTable }{
            .{ .tbl = &t.weapons, .tag = .weapons },
            .{ .tbl = &t.armor, .tag = .armor },
            .{ .tbl = &t.misc, .tag = .misc },
        };
        for (item_tabs) |it| {
            for (it.tbl.rows, 0..) |_, i| {
                const code = it.tbl.str(i, "code");
                if (code.len != 0 and !t.item_by_code.contains(code))
                    try t.item_by_code.put(a, code, .{ .table = it.tag, .row = i });
            }
        }

        try t.buildItemTypeEquivalence(a);

        var classes: std.ArrayListUnmanaged(ItemClass) = .empty;
        for (item_tabs) |it| {
            for (it.tbl.rows, 0..) |_, i| {
                try classes.append(a, .{
                    .code = it.tbl.str(i, "code"),
                    .ref = .{ .table = it.tag, .row = i },
                    .type_idx = t.itypeIndex(it.tbl.str(i, "type")),
                    .type2_idx = t.itypeIndex(it.tbl.str(i, "type2")),
                    .level = @intCast(it.tbl.int(i, "level")),
                    .version = @intCast(it.tbl.int(i, "version")),
                    .rarity = @intCast(it.tbl.int(i, "rarity")),
                    .spawnable = it.tbl.int(i, "spawnable") != 0,
                    .quest = it.tbl.int(i, "quest") != 0,
                });
            }
        }
        t.item_classes = try classes.toOwnedSlice(a);
        return t;
    }

    fn itypeIndex(self: *const Tables, code: []const u8) i32 {
        if (code.len == 0) return -1;
        const row = self.itype_by_code.get(code) orelse return -1;
        return @intCast(row);
    }

    /// Seed each ItemTypes row's mask with itself, then close it over Equiv1/Equiv2.
    fn buildItemTypeEquivalence(self: *Tables, a: std.mem.Allocator) !void {
        const n = self.item_types.rowCount();
        self.equiv_stride = (n + 31) / 32;
        self.itype_equiv = try a.alloc(u32, n * self.equiv_stride);
        @memset(self.itype_equiv, 0);
        for (0..n) |i| self.setEquivBit(i, i);
        for (0..n) |i| self.closeEquiv(i, i, 0);
    }

    fn setEquivBit(self: *Tables, row: usize, bit: usize) void {
        self.itype_equiv[row * self.equiv_stride + (bit >> 5)] |= @as(u32, 1) << @intCast(bit & 31);
    }

    fn closeEquiv(self: *Tables, root: usize, row: usize, depth: u32) void {
        if (depth > 32) return; // the Equiv chain is a DAG; guard a malformed table
        for ([2][]const u8{ "Equiv1", "Equiv2" }) |col| {
            const code = self.item_types.str(row, col);
            if (code.len == 0) continue;
            const parent = self.itype_by_code.get(code) orelse continue;
            self.setEquivBit(root, parent);
            self.closeEquiv(root, parent, depth + 1);
        }
    }

    /// TXT_ItemTypes_CheckEquivalence 0x629a90: does compiled item `class_id` satisfy
    /// ItemTypes row `type_idx`, through either of its two types' Equiv closures?
    /// (type2 == 0 is ITEMTYPE_None1, i.e. "unset", and is not tested — faithful.)
    pub fn isOfType(self: *const Tables, class_id: usize, type_idx: i32) bool {
        const n: i32 = @intCast(self.item_types.rowCount());
        if (type_idx < 0 or type_idx >= n) return false;
        if (class_id >= self.item_classes.len) return false;
        const ic = self.item_classes[class_id];
        if (ic.type_idx >= 0 and ic.type_idx < n and self.equivBit(ic.type_idx, type_idx)) return true;
        if (ic.type2_idx > 0 and ic.type2_idx < n) return self.equivBit(ic.type2_idx, type_idx);
        return false;
    }

    fn equivBit(self: *const Tables, row: i32, bit: i32) bool {
        const r: usize = @intCast(row);
        const b: usize = @intCast(bit);
        return self.itype_equiv[r * self.equiv_stride + (b >> 5)] & (@as(u32, 1) << @intCast(b & 31)) != 0;
    }

    /// ItemTypes row index for a type code, or null.
    pub fn itypeRow(self: *const Tables, code: []const u8) ?usize {
        return self.itype_by_code.get(code);
    }

    pub fn deinit(self: *Tables) void {
        self.treasure.deinit();
        self.item_ratio.deinit();
        self.item_types.deinit();
        self.weapons.deinit();
        self.armor.deinit();
        self.misc.deinit();
        self.magic_prefix.deinit();
        self.magic_suffix.deinit();
        self.rare_prefix.deinit();
        self.rare_suffix.deinit();
        self.item_stat_cost.deinit();
        self.unique_items.deinit();
        self.set_items.deinit();
        self.runes.deinit();
        self.quality_items.deinit();
        self.properties.deinit();
        self.arena.deinit();
    }

    pub fn tcRow(self: *const Tables, name: []const u8) ?usize {
        return self.tc_by_name.get(name);
    }

    pub fn itemRef(self: *const Tables, code: []const u8) ?ItemRef {
        return self.item_by_code.get(code);
    }

    /// The 16 numeric ItemRatio columns (in table order) for the row matching
    /// (version, uber, class_specific). Version: 0=classic, 1=expansion.
    /// Order matches quality.Ratio: Unique,UniqueDivisor,UniqueMin,Rare,...,NormalDivisor.
    pub fn ratioRow(self: *const Tables, version: i64, uber: i64, class_specific: i64) ?[16]i32 {
        const cols = [16][]const u8{
            "Unique",    "UniqueDivisor",    "UniqueMin",
            "Rare",      "RareDivisor",      "RareMin",
            "Set",       "SetDivisor",       "SetMin",
            "Magic",     "MagicDivisor",     "MagicMin",
            "HiQuality", "HiQualityDivisor", "Normal",
            "NormalDivisor",
        };
        for (0..self.item_ratio.rowCount()) |r| {
            if (self.item_ratio.int(r, "Version") == version and
                self.item_ratio.int(r, "Uber") == uber and
                self.item_ratio.int(r, "Class Specific") == class_specific)
            {
                var out: [16]i32 = undefined;
                for (cols, 0..) |c, i| out[i] = @intCast(self.item_ratio.int(r, c));
                return out;
            }
        }
        return null;
    }

    pub fn itemTable(self: *const Tables, tag: ItemTable) *const txt.Table {
        return switch (tag) {
            .weapons => &self.weapons,
            .armor => &self.armor,
            .misc => &self.misc,
        };
    }

    /// Inventory grid footprint {width, height} in cells for a base item code (invwidth/invheight of
    /// Weapons/Armor/Misc.txt), clamped to 1..6. Null when the code isn't a known base item.
    pub fn itemDims(self: *const Tables, code: []const u8) ?[2]u8 {
        const ref = self.itemRef(code) orelse return null;
        const tbl = self.itemTable(ref.table);
        const w = std.math.clamp(tbl.int(ref.row, "invwidth"), 1, 6);
        const h = std.math.clamp(tbl.int(ref.row, "invheight"), 1, 6);
        return .{ @intCast(w), @intCast(h) };
    }
};

const testing = std.testing;

test "load all tables and build indexes" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    try testing.expect(t.treasure.rowCount() > 100);
    try testing.expect(t.magic_prefix.rowCount() > 50);
    try testing.expect(t.magic_suffix.rowCount() > 50);
    // A well-known TC must resolve.
    try testing.expect(t.tcRow("Act 1 Equip A") != null);
    try testing.expect(t.tcRow("Gold") != null);
}

test "itemDims resolves the inventory footprint of a base item" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    // ssd = Short Sword: 1x3 in the weapons table.
    try testing.expectEqual(@as(?[2]u8, .{ 1, 3 }), t.itemDims("ssd"));
    // cap = Cap: 2x2 in the armor table.
    try testing.expectEqual(@as(?[2]u8, .{ 2, 2 }), t.itemDims("cap"));
    // Unknown code -> null.
    try testing.expectEqual(@as(?[2]u8, null), t.itemDims("zzz"));
}
