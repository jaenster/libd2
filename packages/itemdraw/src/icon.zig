//! The inventory icon of an item, as the grid draw of 1.14d puts it on screen.
//!
//!   * The picture (GFXUTIL_SetItemGfxFile 0x004dabc0): an identified set item's SetItems `invfile`, else the
//!     base's `setinvfile`; an identified unique's UniqueItems `invfile` (never for unique row 0), else the
//!     base's `uniqueinvfile`; then the item type's `InvGfx` picked by the record's picture id when the type
//!     has `VarInvGfx`; else the base `invfile`. File `data/global/items/<name>.dc6`, frame 0.
//!   * Placement (DrawItemGfx 0x0046ee80): the frame's top-left at the item's top-left cell corner, no
//!     centring; cells are 29 px and the art 28 px per cell. Ethereal items draw at mode 1 (half).
//!   * Colour (GetItemColor 0x0062c100, PALETTE_GetItemPalette 0x00600c20): the base's `InvTrans` picks one
//!     of the item colour-map files, the item's colour (by quality: the affixes' `transformcolor`, the set or
//!     unique `invtransform`, the first socketed gem's `transform`, the automagic affix) picks the 256-byte
//!     row in it.
//!   * Sockets (INV_DrawSocketedItems 0x00483e40): only on the hovered item, only when it is identified:
//!     `gemsocket.dc6` at mode 0 at each position of a 48-row table, then the filler through its own icon.
//!   * Background (DrawItemSolidBackground 0x004839d0): a mode 0 tint over each 29 px cell, the palette
//!     colour nearest to blue (normal), green (hovered), red (unusable) or dull red (unidentified).

const std = @import("std");
const formats = @import("d2-formats");
const item = @import("d2-item");
const wire = item.wire;
const image = @import("image.zig");
const Image = image.Image;

pub const cell: i32 = 29;

/// The palette files the item colour maps come from, by `InvTrans` (PALETTE_InitItemPalettes 0x00600b80).
/// 3 and 4 load but PALETTE_GetItemPalette refuses them.
pub const palette_files = [9]?[]const u8{
    null,
    "data/global/items/palette/grey.dat",
    "data/global/items/palette/grey2.dat",
    null,
    null,
    "data/global/items/palette/greybrown.dat",
    "data/global/items/palette/invgrey.dat",
    "data/global/items/palette/invgrey2.dat",
    "data/global/items/palette/invgreybrown.dat",
};

pub const Background = enum {
    /// No tint: just the icon on transparency.
    none,
    /// Usable, identified (blue).
    normal,
    /// Under the cursor (green).
    hovered,
    /// The character cannot use it (red).
    unusable,
    /// Not identified (128, 64, 64).
    unidentified,

    pub fn rgb(b: Background) [3]u8 {
        return switch (b) {
            .unusable => .{ 128, 0, 0 },
            .hovered => .{ 0, 128, 0 },
            .normal, .none => .{ 0, 0, 128 },
            .unidentified => .{ 128, 64, 64 },
        };
    }
};

pub const Options = struct {
    background: Background = .none,
    /// Draw the sockets and what is in them, as the game does for the hovered item.
    sockets: bool = false,
};

/// The game's socket positions in half cells (gaSocketOffsets 0x006d91e8): row (n-1)*8 + (w-1)*4 + (h-1).
const socket_table = blk: {
    var t: [48][6][2]i8 = std.mem.zeroes([48][6][2]i8);
    const Set = struct { n: u8, w: u8, h: u8, p: []const [2]i8 };
    const sets = [_]Set{
        .{ .n = 1, .w = 1, .h = 1, .p = &.{.{ 1, 1 }} },
        .{ .n = 1, .w = 1, .h = 2, .p = &.{.{ 1, 2 }} },
        .{ .n = 1, .w = 1, .h = 3, .p = &.{.{ 1, 3 }} },
        .{ .n = 1, .w = 1, .h = 4, .p = &.{.{ 1, 4 }} },
        .{ .n = 1, .w = 2, .h = 1, .p = &.{.{ 2, 1 }} },
        .{ .n = 1, .w = 2, .h = 2, .p = &.{.{ 2, 2 }} },
        .{ .n = 1, .w = 2, .h = 3, .p = &.{.{ 2, 3 }} },
        .{ .n = 1, .w = 2, .h = 4, .p = &.{.{ 2, 4 }} },
        .{ .n = 2, .w = 1, .h = 2, .p = &.{ .{ 1, 1 }, .{ 1, 3 } } },
        .{ .n = 2, .w = 1, .h = 3, .p = &.{ .{ 1, 2 }, .{ 1, 4 } } },
        .{ .n = 2, .w = 1, .h = 4, .p = &.{ .{ 1, 3 }, .{ 1, 5 } } },
        .{ .n = 2, .w = 2, .h = 1, .p = &.{ .{ 1, 1 }, .{ 3, 1 } } },
        .{ .n = 2, .w = 2, .h = 2, .p = &.{ .{ 2, 1 }, .{ 2, 3 } } },
        .{ .n = 2, .w = 2, .h = 3, .p = &.{ .{ 2, 2 }, .{ 2, 4 } } },
        .{ .n = 2, .w = 2, .h = 4, .p = &.{ .{ 2, 2 }, .{ 2, 6 } } },
        .{ .n = 3, .w = 1, .h = 3, .p = &.{ .{ 1, 1 }, .{ 1, 3 }, .{ 1, 5 } } },
        .{ .n = 3, .w = 1, .h = 4, .p = &.{ .{ 1, 2 }, .{ 1, 4 }, .{ 1, 6 } } },
        .{ .n = 3, .w = 2, .h = 2, .p = &.{ .{ 1, 1 }, .{ 3, 1 }, .{ 2, 3 } } },
        .{ .n = 3, .w = 2, .h = 3, .p = &.{ .{ 2, 1 }, .{ 2, 3 }, .{ 2, 5 } } },
        .{ .n = 3, .w = 2, .h = 4, .p = &.{ .{ 2, 2 }, .{ 2, 4 }, .{ 2, 6 } } },
        .{ .n = 4, .w = 1, .h = 4, .p = &.{ .{ 1, 1 }, .{ 1, 3 }, .{ 1, 5 }, .{ 1, 7 } } },
        .{ .n = 4, .w = 2, .h = 2, .p = &.{ .{ 1, 1 }, .{ 3, 3 }, .{ 1, 3 }, .{ 3, 1 } } },
        .{ .n = 4, .w = 2, .h = 3, .p = &.{ .{ 1, 2 }, .{ 3, 4 }, .{ 1, 4 }, .{ 3, 2 } } },
        .{ .n = 4, .w = 2, .h = 4, .p = &.{ .{ 2, 1 }, .{ 2, 3 }, .{ 2, 5 }, .{ 2, 7 } } },
        .{ .n = 5, .w = 2, .h = 3, .p = &.{ .{ 2, 3 }, .{ 1, 1 }, .{ 3, 5 }, .{ 1, 5 }, .{ 3, 1 } } },
        .{ .n = 5, .w = 2, .h = 4, .p = &.{ .{ 2, 4 }, .{ 1, 2 }, .{ 3, 6 }, .{ 1, 6 }, .{ 3, 2 } } },
        .{ .n = 6, .w = 2, .h = 3, .p = &.{ .{ 1, 1 }, .{ 1, 3 }, .{ 1, 5 }, .{ 3, 1 }, .{ 3, 3 }, .{ 3, 5 } } },
        .{ .n = 6, .w = 2, .h = 4, .p = &.{ .{ 1, 2 }, .{ 1, 4 }, .{ 1, 6 }, .{ 3, 2 }, .{ 3, 4 }, .{ 3, 6 } } },
    };
    for (sets) |s| {
        const r = (@as(usize, s.n) - 1) * 8 + (@as(usize, s.w) - 1) * 4 + (s.h - 1);
        for (s.p, 0..) |p, i| t[r][i] = p;
    }
    break :blk t;
};

/// Where socket `i` of an item of `w` x `h` cells with `n` sockets sits, relative to the item's top-left
/// cell corner: x of the socket frame's left edge plus one, y of its bottom edge.
pub fn socketPosition(n: u8, w: u8, h: u8, i: usize) [2]i32 {
    const row = @as(i32, h) + 4 * (@as(i32, w) + 2 * @as(i32, n)) - 13;
    if (row < 0 or row >= 48 or i >= 6) return .{ 0, 0 };
    const p = socket_table[@intCast(row)][i];
    return .{ @divTrunc((@as(i32, p[0]) - 1) * cell, 2), @divTrunc((@as(i32, p[1]) + 1) * cell, 2) };
}

/// What the game draws for one item record.
pub const Gfx = struct {
    /// DC6 base name.
    file: []const u8,
    w: u8,
    h: u8,
    /// Item colour-map file (`InvTrans`) and row, when the item is drawn through one.
    remap: ?struct { set: u8, row: u8 },
    ethereal: bool,
};

pub const Ctx = struct {
    t: *const item.Tables,
    auto_magic: *const item.txt.Table,
    colors: item.txt.Table,
    unique_rows: []const usize,
    set_rows: []const usize,
    prefix_rows: []const usize,
    suffix_rows: []const usize,

    fn colorIndex(self: *const Ctx, code: []const u8) ?u8 {
        if (code.len == 0) return null;
        for (self.colors.rows, 0..) |r, i| {
            if (r.len > 1 and std.ascii.eqlIgnoreCase(r[1], code)) return @intCast(i);
        }
        return null;
    }

    /// GFXUTIL_SetItemGfxFile 0x004dabc0 and GetItemColor 0x0062c100 for an item on a grid page.
    pub fn gfx(self: *const Ctx, a: std.mem.Allocator, it: *const wire.Item, kids: []const wire.Item) !?Gfx {
        const ref = self.t.itemRef(it.codeSlice()) orelse return null;
        const bt = self.t.itemTable(ref.table);
        const row = ref.row;
        var file = bt.str(row, "invfile");
        const ident = it.identified();
        var picked = false;
        if (ident and it.quality == .set and it.set_id < self.set_rows.len) {
            const own = self.t.set_items.str(self.set_rows[it.set_id], "invfile");
            if (own.len != 0) {
                file = own;
                picked = true;
            } else if (bt.str(row, "setinvfile").len != 0) {
                file = bt.str(row, "setinvfile");
                picked = true;
            }
        } else if (ident and it.quality == .unique) {
            if (it.unique_id > 0 and it.unique_id < self.unique_rows.len and self.t.unique_items.str(self.unique_rows[it.unique_id], "invfile").len != 0) {
                file = self.t.unique_items.str(self.unique_rows[it.unique_id], "invfile");
                picked = true;
            } else if (bt.str(row, "uniqueinvfile").len != 0) {
                file = bt.str(row, "uniqueinvfile");
                picked = true;
            }
        }
        if (!picked) {
            if (self.t.itypeRow(bt.str(row, "type"))) |tr| {
                const n = self.t.item_types.int(tr, "VarInvGfx");
                if (n != 0) {
                    const v: i64 = if (it.has_variant) it.variant else 0;
                    const idx: i64 = if (v <= 0) 0 else @min(v, n - 1);
                    var col: [8]u8 = undefined;
                    const name = std.fmt.bufPrint(&col, "InvGfx{d}", .{idx + 1}) catch unreachable;
                    const g = self.t.item_types.str(tr, name);
                    if (g.len != 0) file = g;
                }
            }
        }
        const w: u8 = @intCast(std.math.clamp(bt.int(row, "invwidth"), 1, 4));
        const h: u8 = @intCast(std.math.clamp(bt.int(row, "invheight"), 1, 4));
        const color = try self.itemColor(a, it, kids, bt, row);
        const set = bt.int(row, "InvTrans");
        var remap: @FieldType(Gfx, "remap") = null;
        if (color) |c| {
            if (set > 0 and set < 9 and set != 3 and set != 4 and c < 21) remap = .{ .set = @intCast(set), .row = c };
        }
        return .{ .file = file, .w = w, .h = h, .remap = remap, .ethereal = it.ethereal() };
    }

    fn affixColor(self: *const Ctx, tbl: *const item.txt.Table, rows: ?[]const usize, id: u16) ?u8 {
        if (id == 0) return null;
        const r: usize = if (rows) |rs| (if (id - 1 < rs.len) rs[id - 1] else return null) else id - 1;
        if (r >= tbl.rowCount()) return null;
        return self.colorIndex(tbl.str(r, "transformcolor"));
    }

    fn itemColor(self: *const Ctx, a: std.mem.Allocator, it: *const wire.Item, kids: []const wire.Item, bt: *const item.txt.Table, row: usize) !?u8 {
        switch (it.quality) {
            .magic, .rare => {
                const sufs: [3]u16 = if (it.quality == .magic) .{ it.suffix, 0, 0 } else it.rare_suffixes;
                const pres: [3]u16 = if (it.quality == .magic) .{ it.prefix, 0, 0 } else it.rare_prefixes;
                for (sufs) |s| if (self.affixColor(&self.t.magic_suffix, self.suffix_rows, s)) |c| return c;
                for (pres) |p| if (self.affixColor(&self.t.magic_prefix, self.prefix_rows, p)) |c| return c;
                return self.affixColor(self.auto_magic, null, it.automagic);
            },
            .set => {
                if (it.set_id >= self.set_rows.len) return null;
                return self.colorIndex(self.t.set_items.str(self.set_rows[it.set_id], "invtransform"));
            },
            .unique => {
                if (it.unique_id >= self.unique_rows.len) return null;
                return self.colorIndex(self.t.unique_items.str(self.unique_rows[it.unique_id], "invtransform"));
            },
            else => {
                if (bt.int(row, "hasinv") != 0 and bt.int(row, "gemsockets") != 0 and it.flags & wire.flag.SOCKETED != 0 and kids.len != 0) {
                    const types = try item.itemtype.typesForItem(a, self.t, kids[0].codeSlice());
                    if (types.has("gem")) {
                        const gr = self.t.gems.findByStr("code", kids[0].codeSlice()) orelse return null;
                        const s = self.t.gems.str(gr, "transform");
                        if (s.len == 0) return null;
                        const v = std.fmt.parseInt(i32, s, 10) catch return null;
                        return if (v < 0 or v > 255) null else @intCast(v);
                    }
                }
                return self.affixColor(self.auto_magic, null, it.automagic);
            },
        }
    }
};
