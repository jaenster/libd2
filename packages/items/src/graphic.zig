//! Item graphic resolution — maps a rolled `Drop` (base item class) to its real
//! inventory sprite plus the quality colour D2 uses for the item name.
//!
//! The inventory graphic is the `invfile` column of Weapons/Armor/Misc.txt (the
//! DC6 base name, e.g. "invswrd"), rendered on an `invwidth` x `invheight` grid of
//! inventory cells. The quality colour follows D2's item-name colour convention
//! (normal=white, magic=blue, rare=yellow, set=green, unique=gold, crafted=orange).
//!
//! Unique/set items have their OWN sprites (uniqueinvfile / setinvfile columns);
//! wiring those to the specific UniqueItems/SetItems row is a documented follow-up
//! — this resolver returns the base `invfile` for every quality.

const std = @import("std");
const tables = @import("tables.zig");
const model = @import("model.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// Where an item's inventory sprite lives and how big its grid is.
pub const Graphic = struct {
    /// DC6 base name from the `invfile` column (no extension / path).
    invfile: []const u8,
    /// Inventory grid dimensions (cells), from invwidth/invheight.
    inv_width: u8,
    inv_height: u8,
    /// Quality-name colour for the label / border.
    color: Rgb,
};

/// D2 item-name colour convention. RGB approximations of the in-game text colours.
pub fn qualityColor(q: model.Quality) Rgb {
    return switch (q) {
        .magic => .{ .r = 0x69, .g = 0x69, .b = 0xFF }, // blue
        .rare => .{ .r = 0xFF, .g = 0xFF, .b = 0x64 }, // yellow
        .set => .{ .r = 0x00, .g = 0xFF, .b = 0x00 }, // green
        .unique => .{ .r = 0xC7, .g = 0xB3, .b = 0x77 }, // gold/tan
        .crafted, .tempered => .{ .r = 0xFF, .g = 0xA8, .b = 0x00 }, // orange
        .low => .{ .r = 0xA0, .g = 0xA0, .b = 0xA0 }, // grey (inferior)
        else => .{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, // white (normal/superior)
    };
}

/// Resolve the inventory graphic + quality colour for a rolled drop. Returns null
/// if the drop is not a real base item (gold, class-token residual, unknown code).
pub fn resolve(t: *const tables.Tables, d: *const model.Drop) ?Graphic {
    if (d.kind != .item) return null;
    const ref = t.itemRef(d.code()) orelse return null;
    const tbl = t.itemTable(ref.table);

    const invfile = tbl.str(ref.row, "invfile");
    if (invfile.len == 0) return null;

    const w = tbl.int(ref.row, "invwidth");
    const h = tbl.int(ref.row, "invheight");

    return .{
        .invfile = invfile,
        .inv_width = @intCast(std.math.clamp(w, 1, 6)),
        .inv_height = @intCast(std.math.clamp(h, 1, 6)),
        .color = qualityColor(d.quality),
    };
}

const testing = std.testing;

test "resolve invfile + dims for a known base item" {
    var t = try tables.Tables.load(testing.allocator);
    defer t.deinit();

    // Short Sword ("ssd") is a stable 1x3 weapon with invfile invssd.
    var d = model.Drop{ .kind = .item, .quality = .magic };
    @memcpy(d.item_code[0..3], "ssd");

    const g = resolve(&t, &d) orelse return error.NoGraphic;
    try testing.expectEqualStrings("invssd", g.invfile);
    try testing.expect(g.inv_width >= 1 and g.inv_height >= 1);
    // magic -> blue
    try testing.expectEqual(@as(u8, 0xFF), g.color.b);
}

test "qualityColor covers the name-colour convention" {
    try testing.expectEqual(@as(u8, 0x00), qualityColor(.set).r);
    try testing.expectEqual(@as(u8, 0xFF), qualityColor(.normal).r);
}
