//! The drawer: the art loaded once from the caller's assets, and the three pictures.
//!
//!   * `icon`: the grid icon (icon.zig).
//!   * `tooltip`: the hover box as the D2Win tooltip draw (0x00503000) puts it on screen: Font16, a black
//!     rectangle at mode 2 (alpha 0xC0) the widest line plus 8 wide and 16 px per line high (the Latin
//!     line metrics of D2WINFONT_InitFontSystem 0x00502c60 over the font's 10 px height), every line centred
//!     on its own, the FIRST line of the description at the bottom, each glyph drawn through the pl2
//!     text-colour shift its `ÿcN` code selects (D2WINFONT_DrawWideString 0x00501a80).
//!   * `card`: both as on hover: the item's cells tinted green, its icon and sockets, and the box centred
//!     above it with its bottom 2 px into the item (LoadItemDesc 0x0048ed34 and the draw's clamp).

const std = @import("std");
const formats = @import("d2-formats");
const item = @import("d2-item");
const wire = item.wire;
const image = @import("image.zig");
const icon_mod = @import("icon.zig");
const Assets = @import("assets.zig").Assets;
const Image = image.Image;
const itemdesc = item.itemdesc;

pub const Options = struct {
    /// The act whose palette the art is drawn in (1..5); the stash and inventory use the current act's.
    act: u8 = 1,
};

pub const Error = error{ MissingPalette, MissingFont };

/// Font16 (aFontNames[1]), the item tooltip's font.
const font_dir = "data/local/font/latin/";

const Font = struct {
    glyphs: []formats.font.Glyph,
    sheet: formats.dc6.Dc6,
    /// The table header's byte at +10: the font height the line metrics scale.
    height: u8,

    /// FONT_GetCharWidthCallback 0x00501650: a code up to 0xFF is its own table entry, anything above
    /// uses entry 0.
    fn glyph(self: *const Font, code: u21) formats.font.Glyph {
        const i: usize = if (code <= 0xff) code else 0;
        return if (i < self.glyphs.len) self.glyphs[i] else self.glyphs[0];
    }
};

pub const Drawer = struct {
    gpa: std.mem.Allocator,
    assets: *const Assets,
    t: *item.Tables,
    s: *item.strings.Strings,
    describer: itemdesc.Describer,
    icons: icon_mod.Ctx,
    pal: formats.palette.Palette,
    pl2: []u8,
    font: Font,
    item_palettes: [9]?[]u8,
    socket: ?formats.dc6.Dc6,
    animdata: ?[]u8,
    sprites: std.StringHashMapUnmanaged(formats.dc6.Dc6) = .{},

    pub fn init(gpa: std.mem.Allocator, assets: *const Assets, opts: Options) !*Drawer {
        const d = try gpa.create(Drawer);
        errdefer gpa.destroy(d);
        d.* = undefined;
        d.gpa = gpa;
        d.assets = assets;
        d.sprites = .{};
        d.t = try gpa.create(item.Tables);
        errdefer gpa.destroy(d.t);
        d.t.* = try item.Tables.load(gpa);
        errdefer d.t.deinit();
        d.s = try gpa.create(item.strings.Strings);
        errdefer gpa.destroy(d.s);
        d.s.* = try item.strings.Strings.load(gpa);
        errdefer d.s.deinit();
        d.describer = try itemdesc.Describer.init(gpa, d.t, d.s);
        errdefer d.describer.deinit();
        d.icons = .{
            .t = d.t,
            .auto_magic = &d.describer.auto_magic,
            .colors = try item.txt.Table.parse(gpa, @import("d2-data").current("Colors")),
            .unique_rows = d.describer.unique_rows,
            .set_rows = d.describer.set_rows,
            .prefix_rows = d.describer.prefix_rows,
            .suffix_rows = d.describer.suffix_rows,
        };
        errdefer d.icons.colors.deinit();

        var path_buf: [64]u8 = undefined;
        const act = std.math.clamp(opts.act, 1, 5);
        const pal_bytes = assets.read(gpa, std.fmt.bufPrint(&path_buf, "data/global/palette/act{d}/pal.dat", .{act}) catch unreachable) catch return Error.MissingPalette;
        defer gpa.free(pal_bytes);
        d.pal = formats.palette.parseDat(pal_bytes) catch return Error.MissingPalette;
        d.pl2 = assets.read(gpa, std.fmt.bufPrint(&path_buf, "data/global/palette/act{d}/pal.pl2", .{act}) catch unreachable) catch return Error.MissingPalette;
        errdefer gpa.free(d.pl2);

        const tbl = assets.read(gpa, font_dir ++ "font16.tbl") catch return Error.MissingFont;
        defer gpa.free(tbl);
        var table = formats.font.parseTable(gpa, tbl) catch return Error.MissingFont;
        errdefer table.deinit(gpa);
        const sheet_bytes = assets.read(gpa, font_dir ++ "font16.dc6") catch return Error.MissingFont;
        defer gpa.free(sheet_bytes);
        d.font = .{ .glyphs = table.glyphs, .sheet = formats.dc6.parse(gpa, sheet_bytes) catch return Error.MissingFont, .height = if (tbl.len > 10) tbl[10] else 10 };

        for (icon_mod.palette_files, 0..) |f, i| {
            d.item_palettes[i] = if (f) |p| assets.read(gpa, p) catch null else null;
        }
        d.socket = blk: {
            const b = assets.read(gpa, "data/global/ui/panel/gemsocket.dc6") catch break :blk null;
            defer gpa.free(b);
            break :blk formats.dc6.parse(gpa, b) catch null;
        };
        d.animdata = assets.read(gpa, "data/global/animdata.d2") catch null;
        return d;
    }

    pub fn deinit(self: *Drawer) void {
        const gpa = self.gpa;
        var it = self.sprites.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.sprites.deinit(gpa);
        if (self.animdata) |a| gpa.free(a);
        if (self.socket) |*s| s.deinit();
        for (self.item_palettes) |p| if (p) |b| gpa.free(b);
        self.font.sheet.deinit();
        gpa.free(self.font.glyphs);
        gpa.free(self.pl2);
        self.icons.colors.deinit();
        self.describer.deinit();
        self.s.deinit();
        gpa.destroy(self.s);
        self.t.deinit();
        gpa.destroy(self.t);
        gpa.destroy(self);
    }

    /// The description of an item (host record first, then the records socketed into it).
    pub fn describe(self: *const Drawer, arena: std.mem.Allocator, records: []const wire.Item, opts: itemdesc.Options) !itemdesc.Desc {
        if (records.len == 0) return .{ .text = "" };
        var o = opts;
        if (o.animdata == null) o.animdata = self.animdata;
        return self.describer.describe(arena, &records[0], records[1..], o);
    }

    fn sprite(self: *Drawer, name: []const u8) ?*const formats.dc6.Dc6 {
        if (self.sprites.getPtr(name)) |s| return s;
        var path_buf: [96]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "data/global/items/{s}.dc6", .{name}) catch return null;
        const bytes = self.assets.read(self.gpa, path) catch return null;
        defer self.gpa.free(bytes);
        const sheet = formats.dc6.parse(self.gpa, bytes) catch return null;
        const key = self.gpa.dupe(u8, name) catch return null;
        self.sprites.put(self.gpa, key, sheet) catch return null;
        return self.sprites.getPtr(name);
    }

    fn remapOf(self: *const Drawer, g: icon_mod.Gfx) ?[]const u8 {
        const r = g.remap orelse return null;
        const p = self.item_palettes[r.set] orelse return null;
        const at = @as(usize, r.row) * 256;
        if (at + 256 > p.len) return null;
        return p[at..][0..256];
    }

    /// DrawItemGfx 0x0046ee80: the icon with its top-left cell corner at (x, y).
    fn drawItem(self: *Drawer, a: std.mem.Allocator, img: *Image, it: *const wire.Item, kids: []const wire.Item, x: i32, y: i32) !void {
        const g = (try self.icons.gfx(a, it, kids)) orelse return;
        const sheet = self.sprite(g.file) orelse return;
        if (sheet.frames.len == 0) return;
        const f = &sheet.frames[0];
        // DrawItemGfx hands the draw the cell top plus the frame height: the baseline the frame hangs from
        const base_y = y + @as(i32, @intCast(f.height));
        img.blitBaseline(f, &self.pal, x, base_y, self.remapOf(g), if (g.ethereal) image.alpha_transparent else image.alpha_solid);
    }

    /// The grid icon. The picture covers the item's cells (29 px each) plus the one column left of them
    /// the leftmost sockets reach; `origin_x/y` is the top-left cell corner inside it.
    pub fn icon(self: *Drawer, records: []const wire.Item, opts: icon_mod.Options) !Image {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (records.len == 0) return Image.init(self.gpa, 1, 1);
        const it = &records[0];
        const kids = records[1..];
        const g = (try self.icons.gfx(a, it, kids)) orelse return Image.init(self.gpa, 1, 1);
        const margin: i32 = 1;
        var img = try Image.init(self.gpa, @intCast(@as(i32, g.w) * icon_mod.cell + margin), @intCast(@as(i32, g.h) * icon_mod.cell));
        img.origin_x = margin;
        try self.drawAt(a, &img, records, opts, margin, 0);
        return img;
    }

    fn drawAt(self: *Drawer, a: std.mem.Allocator, img: *Image, records: []const wire.Item, opts: icon_mod.Options, x: i32, y: i32) !void {
        const it = &records[0];
        const kids = records[1..];
        const g = (try self.icons.gfx(a, it, kids)) orelse return;
        if (opts.background != .none) {
            const c = self.pal.rgb(image.nearest(&self.pal, opts.background.rgb()));
            var row: i32 = 0;
            while (row < g.h) : (row += 1) {
                var col: i32 = 0;
                while (col < g.w) : (col += 1) img.fill(x + col * icon_mod.cell, y + row * icon_mod.cell, icon_mod.cell, icon_mod.cell, c, image.alpha_very_transparent);
            }
        }
        try self.drawItem(a, img, it, kids, x, y);
        if (!opts.sockets or !it.identified() or it.flags & wire.flag.SOCKETED == 0) return;
        const ref = self.t.itemRef(it.codeSlice()) orelse return;
        const bt = self.t.itemTable(ref.table);
        if (bt.int(ref.row, "hasinv") == 0 or bt.int(ref.row, "gemsockets") == 0) return;
        var k: usize = 0;
        var i: usize = 0;
        while (i < it.sockets) : (i += 1) {
            const p = icon_mod.socketPosition(it.sockets, g.w, g.h, i);
            const px = x + p[0];
            const py = y + p[1];
            if (self.socket) |*s| if (s.frames.len != 0) {
                const f = &s.frames[0];
                img.blitBaseline(f, &self.pal, px - 1, py, null, image.alpha_very_transparent);
            };
            if (k < kids.len) {
                try self.drawItem(a, img, &kids[k], &.{}, px, py - icon_mod.cell);
                k += 1;
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // text

    const Metrics = struct { pitch: i32, height_per_line: i32, lift: i32 };

    fn metrics(self: *const Drawer) Metrics {
        const lh: i32 = self.font.height;
        return .{ .pitch = @divTrunc(lh * 16, 10), .height_per_line = lh * 16, .lift = @divTrunc(lh * 3, 10) };
    }

    /// TEXT_CalculateTextWidth 0x00501840 for one line: a `ÿ` skips itself and the next two characters
    /// (and adds the width of `m` when the next is an m).
    fn lineWidth(self: *const Drawer, line: []const u8) i32 {
        var w: i32 = 0;
        var view = std.unicode.Utf8View.initUnchecked(line);
        var cps = view.iterator();
        while (cps.nextCodepoint()) |cp| {
            if (cp == 0xff) {
                const n1 = cps.nextCodepoint() orelse break;
                if (n1 == 'm' or n1 == 'M') w += self.font.glyph('m').width;
                _ = cps.nextCodepoint();
                continue;
            }
            w += self.font.glyph(cp).width;
        }
        return w;
    }

    /// The tooltip box for a description. `origin_x/y` is the box's top-left in the picture, which may
    /// be larger than the box where glyph cells reach past it.
    pub fn tooltip(self: *Drawer, desc: itemdesc.Desc) !Image {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer lines.deinit(self.gpa);
        var it = std.mem.splitScalar(u8, desc.text, '\n');
        while (it.next()) |l| try lines.append(self.gpa, l);
        if (desc.text.len == 0) return Image.init(self.gpa, 1, 1);
        const m = self.metrics();
        var widest: i32 = 0;
        for (lines.items) |l| widest = @max(widest, self.lineWidth(l));
        const box_w = widest + 8;
        const box_h = @divTrunc(m.height_per_line * @as(i32, @intCast(lines.items.len)), 10);
        // glyph cells are taller than the line pitch; leave room for the top line's cell
        const cell_h: i32 = if (self.font.sheet.frames.len != 0) @intCast(self.font.sheet.frames[0].height) else 16;
        const over = @max(0, cell_h - (box_h - m.lift - (@as(i32, @intCast(lines.items.len)) - 1) * m.pitch));
        var img = try Image.init(self.gpa, @intCast(box_w), @intCast(box_h + over));
        img.origin_y = over;
        try self.drawTooltip(&img, desc, lines.items, 0, over, box_w, box_h);
        return img;
    }

    fn drawTooltip(self: *Drawer, img: *Image, desc: itemdesc.Desc, lines: []const []const u8, left: i32, top: i32, box_w: i32, box_h: i32) !void {
        const m = self.metrics();
        img.fill(left, top, box_w, box_h, self.pal.rgb(0), image.alpha_less_transparent);
        var color: u8 = desc.base_color;
        const bottom = top + box_h;
        for (lines, 0..) |l, k| {
            const y = bottom - m.lift - @as(i32, @intCast(k)) * m.pitch;
            const lw = self.lineWidth(l);
            var x = if (desc.centered) left + ((box_w - lw) >> 1) else left;
            var view = std.unicode.Utf8View.initUnchecked(l);
            var cps = view.iterator();
            while (cps.nextCodepoint()) |cp| {
                if (cp == 0xff) {
                    const save = cps.i;
                    if (cps.nextCodepoint()) |n1| {
                        if (n1 == 'c') {
                            if (cps.nextCodepoint()) |dg| {
                                const v: i32 = @as(i32, @intCast(dg)) - '0';
                                color = if (v > 12 or v < 0) 0 else @intCast(v);
                            } else color = 0;
                            continue;
                        }
                    } else {
                        color = 0;
                        break;
                    }
                    cps.i = save;
                }
                const g = self.font.glyph(cp);
                if (g.frame < self.font.sheet.frames.len) {
                    const f = &self.font.sheet.frames[g.frame];
                    const shift = formats.pl2.textShift(self.pl2, @enumFromInt(color)) catch null;
                    img.blitBaseline(f, &self.pal, x, y, shift, image.alpha_solid);
                }
                x += g.width;
            }
        }
    }

    /// The hover card: the item as it sits in the grid when hovered (green cells, icon, sockets) and its
    /// tooltip above it.
    pub fn card(self: *Drawer, records: []const wire.Item, opts: itemdesc.Options) !Image {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (records.len == 0) return Image.init(self.gpa, 1, 1);
        const g = (try self.icons.gfx(a, &records[0], records[1..])) orelse return Image.init(self.gpa, 1, 1);
        const desc = try self.describe(a, records, opts);
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, desc.text, '\n');
        while (it.next()) |l| try lines.append(a, l);
        const m = self.metrics();
        var widest: i32 = 0;
        for (lines.items) |l| widest = @max(widest, self.lineWidth(l));
        const box_w = widest + 8;
        const box_h = @divTrunc(m.height_per_line * @as(i32, @intCast(lines.items.len)), 10);
        const item_w = @as(i32, g.w) * icon_mod.cell;
        const item_h = @as(i32, g.h) * icon_mod.cell;
        // placed as on hover: centred on the item, the box bottom two pixels below the item's top edge
        const cell_h: i32 = if (self.font.sheet.frames.len != 0) @intCast(self.font.sheet.frames[0].height) else 16;
        const over = @max(0, cell_h - (box_h - m.lift - (@as(i32, @intCast(lines.items.len)) - 1) * m.pitch));
        const item_x0: i32 = 0;
        const box_left_rel = @divTrunc(item_w, 2) - (box_w >> 1);
        const min_x = @min(box_left_rel, item_x0 - 1);
        const max_x = @max(box_left_rel + box_w, item_w);
        const box_top_rel = 2 - box_h;
        const min_y = box_top_rel - over;
        const W: u32 = @intCast(max_x - min_x);
        const H: u32 = @intCast(item_h - min_y);
        var img = try Image.init(self.gpa, W, H);
        const ox = -min_x;
        const oy = -min_y;
        img.origin_x = ox;
        img.origin_y = oy;
        try self.drawAt(a, &img, records, .{ .background = .hovered, .sockets = true }, ox, oy);
        try self.drawTooltip(&img, desc, lines.items, ox + box_left_rel, oy + box_top_rel, box_w, box_h);
        return img;
    }
};
