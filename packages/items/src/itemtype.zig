//! Item-type eligibility — the ItemTypes equivalency chain + IsOfType, used by
//! the affix eligibility predicate (ITEMMOD_CanApplyAutomod 0x65e620) and by the
//! magic/rare affix itype-include / etype-exclude filters.
//!
//! An item "is of type T" if its base `type` (or weapon/misc `type2`) equals T, or
//! any ancestor reachable through ItemTypes.Equiv1/Equiv2 equals T. E.g. a "swor"
//! is also "mele", "weap", etc. Faithful to D2 IsOfType (recursive Equiv walk).

const std = @import("std");
const tables = @import("tables.zig");

pub const TypeSet = struct {
    /// De-duplicated set of type codes this item satisfies (base + ancestors).
    codes: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn has(self: *const TypeSet, code: []const u8) bool {
        for (self.codes.items) |c| if (std.mem.eql(u8, c, code)) return true;
        return false;
    }

    pub fn deinit(self: *TypeSet, gpa: std.mem.Allocator) void {
        self.codes.deinit(gpa);
    }
};

/// Build the full IsOfType set for an item code (base types + all Equiv ancestors).
/// Codes are borrowed slices into the embedded tables (valid for the Tables' lifetime).
pub fn typesForItem(gpa: std.mem.Allocator, t: *const tables.Tables, item_code: []const u8) !TypeSet {
    var set = TypeSet{};
    const ref = t.itemRef(item_code) orelse return set;
    const tbl = t.itemTable(ref.table);

    // Seed with the item's `type` and (weapons/misc/armor) `type2`.
    try addWithAncestors(gpa, t, &set, tbl.str(ref.row, "type"));
    try addWithAncestors(gpa, t, &set, tbl.str(ref.row, "type2"));
    return set;
}

fn addWithAncestors(gpa: std.mem.Allocator, t: *const tables.Tables, set: *TypeSet, type_code: []const u8) !void {
    if (type_code.len == 0) return;
    if (set.has(type_code)) return;
    try set.codes.append(gpa, type_code);
    const row = t.itype_by_code.get(type_code) orelse return;
    const e1 = t.item_types.str(row, "Equiv1");
    const e2 = t.item_types.str(row, "Equiv2");
    try addWithAncestors(gpa, t, set, e1);
    try addWithAncestors(gpa, t, set, e2);
}

/// Affix itype/etype eligibility (ITEMMOD_CanApplyAutomod core): the item must
/// match at least one of `itypes` (include) and none of `etypes` (exclude).
/// Empty entries are ignored.
pub fn affixMatchesTypes(item: *const TypeSet, itypes: []const []const u8, etypes: []const []const u8) bool {
    for (etypes) |e| {
        if (e.len != 0 and item.has(e)) return false; // excluded
    }
    var any_include = false;
    var matched = false;
    for (itypes) |i| {
        if (i.len == 0) continue;
        any_include = true;
        if (item.has(i)) matched = true;
    }
    // No include list => not applicable (engine requires >=1 include match).
    return any_include and matched;
}

const testing = std.testing;

test "sword is also mele/weap via Equiv chain" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    // "hax" (Hand Axe) or a common weapon code; pick any weapon and check it maps
    // up to the broad "weap" type.
    var set = try typesForItem(testing.allocator, &t, "hax");
    defer set.deinit(testing.allocator);
    try testing.expect(set.codes.items.len > 1);
    try testing.expect(set.has("weap"));
}

test "affix type match: include required, exclude blocks" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();
    var set = try typesForItem(testing.allocator, &t, "hax");
    defer set.deinit(testing.allocator);
    try testing.expect(affixMatchesTypes(&set, &.{"weap"}, &.{}));
    try testing.expect(!affixMatchesTypes(&set, &.{"weap"}, &.{"weap"})); // excluded
    try testing.expect(!affixMatchesTypes(&set, &.{}, &.{})); // no include => false
    try testing.expect(!affixMatchesTypes(&set, &.{"ring"}, &.{})); // wrong include
}
