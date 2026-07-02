//! Typed views over the D2 1.14d item-generation excel tables.
//!
//! Every table generation reads is embedded via @embedFile so the port is
//! self-contained (data\global\excel\*.txt). Column names match the 1.14d
//! headers verbatim; empty cells read as 0 (D2 convention, see txt.zig).

const std = @import("std");
const txt = @import("txt.zig");

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

    /// TreasureClass name -> row index (built once at load).
    tc_by_name: std.StringHashMapUnmanaged(usize) = .{},
    /// Item Code (weapon/armor/misc `code`) -> {table, row}.
    item_by_code: std.StringHashMapUnmanaged(ItemRef) = .{},
    /// ItemTypes Code -> row index.
    itype_by_code: std.StringHashMapUnmanaged(usize) = .{},

    arena: std.heap.ArenaAllocator,

    pub const ItemTable = enum { weapons, armor, misc };
    pub const ItemRef = struct { table: ItemTable, row: usize };

    pub fn load(gpa: std.mem.Allocator) !Tables {
        var t = Tables{
            .treasure = try txt.Table.parse(gpa, @embedFile("excel/TreasureClassEx.txt")),
            .item_ratio = try txt.Table.parse(gpa, @embedFile("excel/ItemRatio.txt")),
            .item_types = try txt.Table.parse(gpa, @embedFile("excel/ItemTypes.txt")),
            .weapons = try txt.Table.parse(gpa, @embedFile("excel/Weapons.txt")),
            .armor = try txt.Table.parse(gpa, @embedFile("excel/Armor.txt")),
            .misc = try txt.Table.parse(gpa, @embedFile("excel/Misc.txt")),
            .magic_prefix = try txt.Table.parse(gpa, @embedFile("excel/MagicPrefix.txt")),
            .magic_suffix = try txt.Table.parse(gpa, @embedFile("excel/MagicSuffix.txt")),
            .rare_prefix = try txt.Table.parse(gpa, @embedFile("excel/RarePrefix.txt")),
            .rare_suffix = try txt.Table.parse(gpa, @embedFile("excel/RareSuffix.txt")),
            .item_stat_cost = try txt.Table.parse(gpa, @embedFile("excel/ItemStatCost.txt")),
            .unique_items = try txt.Table.parse(gpa, @embedFile("excel/UniqueItems.txt")),
            .set_items = try txt.Table.parse(gpa, @embedFile("excel/SetItems.txt")),
            .runes = try txt.Table.parse(gpa, @embedFile("excel/Runes.txt")),
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
        return t;
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
