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
const canvas = formats.canvas;
const DrawMode = canvas.DrawMode;
const layout = @import("layout.zig");
const raster = @import("raster.zig");
const icon_mod = @import("icon.zig");
const Assets = @import("assets.zig").Assets;
const Image = canvas.Canvas;
const itemdesc = item.itemdesc;

pub const Options = struct {
    /// The act whose palette the art is drawn in (1..5); the stash and inventory use the current act's.
    act: u8 = 1,
};

pub const Error = error{ MissingPalette, MissingFont };

/// Font16 (aFontNames[1]), the item tooltip's font.
const font_dir = "data/local/font/latin/";


pub const Drawer = struct {
    gpa: std.mem.Allocator,
    assets: *const Assets,
    t: *item.Tables,
    s: *item.strings.Strings,
    describer: itemdesc.Describer,
    icons: icon_mod.Ctx,
    pal: formats.palette.Palette,
    pl2: []u8,
    font: formats.font.Font,
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
        d.font = .{ .table = table, .sheet = formats.dc6.parse(gpa, sheet_bytes) catch return Error.MissingFont };

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
        self.font.deinit(gpa);
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

    /// A DC6 by its game path, loaded once.
    fn sheetAt(self: *Drawer, path: []const u8) ?*const formats.dc6.Dc6 {
        if (self.sprites.getPtr(path)) |s| return s;
        const bytes = self.assets.read(self.gpa, path) catch return null;
        defer self.gpa.free(bytes);
        const sheet = formats.dc6.parse(self.gpa, bytes) catch return null;
        const key = self.gpa.dupe(u8, path) catch return null;
        self.sprites.put(self.gpa, key, sheet) catch return null;
        return self.sprites.getPtr(path);
    }

    fn remapOf(self: *const Drawer, cm: ?layout.ColorMap) ?[]const u8 {
        const r = cm orelse return null;
        const p = self.item_palettes[r.set] orelse return null;
        const at = @as(usize, r.row) * 256;
        if (at + 256 > p.len) return null;
        return p[at..][0..256];
    }

    // ---------------------------------------------------------------------------------------------
    // layout

    /// DrawItemGfx 0x0046ee80: the item's frame with its top-left cell corner at (x, y). The rectangle is
    /// the frame's own (every 1.14d inventory frame is 28 px per cell with no offset); without the art it
    /// is that 28 px per cell.
    fn itemSprite(self: *Drawer, a: std.mem.Allocator, it: *const wire.Item, kids: []const wire.Item, x: i32, y: i32, role: layout.Role) !?layout.Sprite {
        const g = (try self.icons.gfx(a, it, kids)) orelse return null;
        const path = try std.fmt.allocPrint(a, "data/global/items/{s}.dc6", .{g.file});
        var rect = layout.Rect{ .x = x, .y = y, .w = 28 * @as(i32, g.w), .h = 28 * @as(i32, g.h) };
        if (self.sheetAt(path)) |sheet| {
            if (sheet.frames.len == 0) return null;
            const f = &sheet.frames[0];
            rect = .{ .x = x + f.offset_x, .y = y + f.offset_y, .w = @intCast(f.width), .h = @intCast(f.height) };
        }
        return .{
            .rect = rect,
            .ref = .{ .path = path, .frame = 0, .colormap = if (g.remap) |r| .{ .set = r.set, .row = r.row } else null, .role = role },
            .alpha = if (g.ethereal) DrawMode.transparent.alpha() else DrawMode.solid.alpha(),
            .ethereal = g.ethereal,
        };
    }

    /// The grid part of a layout: the cell tints, the icon, the sockets and their fillers.
    fn placeItem(self: *Drawer, a: std.mem.Allocator, l: *layout.Layout, records: []const wire.Item, opts: icon_mod.Options, x: i32, y: i32) !void {
        const it = &records[0];
        const kids = records[1..];
        const g = (try self.icons.gfx(a, it, kids)) orelse return;
        if (opts.background != .none) {
            const c = self.pal.rgb(formats.palette.nearest(&self.pal, opts.background.rgb()));
            var cells: std.ArrayListUnmanaged(layout.Fill) = .empty;
            var row: i32 = 0;
            while (row < g.h) : (row += 1) {
                var col: i32 = 0;
                while (col < g.w) : (col += 1) try cells.append(a, .{ .rect = .{ .x = x + col * icon_mod.cell, .y = y + row * icon_mod.cell, .w = icon_mod.cell, .h = icon_mod.cell }, .rgb = c, .alpha = DrawMode.very_transparent.alpha() });
            }
            l.cells = cells.items;
        }
        l.icon = try self.itemSprite(a, it, kids, x, y, .item);
        if (!opts.sockets or !it.identified() or it.flags & wire.flag.SOCKETED == 0) return;
        const ref = self.t.itemRef(it.codeSlice()) orelse return;
        const bt = self.t.itemTable(ref.table);
        if (bt.int(ref.row, "hasinv") == 0 or bt.int(ref.row, "gemsockets") == 0) return;
        var socks: std.ArrayListUnmanaged(layout.Sprite) = .empty;
        var k: usize = 0;
        var i: usize = 0;
        while (i < it.sockets) : (i += 1) {
            const p = icon_mod.socketPosition(it.sockets, g.w, g.h, i);
            const px = x + p[0];
            const py = y + p[1];
            // gemsocket.dc6 hangs from (px - 1, py)
            var r = layout.Rect{ .x = px - 1, .y = py - 28, .w = 28, .h = 28 };
            if (self.socket) |*s| if (s.frames.len != 0) {
                const f = &s.frames[0];
                r = .{ .x = px - 1 + f.offset_x, .y = py + f.offset_y - @as(i32, @intCast(f.height)), .w = @intCast(f.width), .h = @intCast(f.height) };
            };
            try socks.append(a, .{ .rect = r, .ref = .{ .path = socket_path, .role = .socket }, .alpha = DrawMode.very_transparent.alpha() });
            if (k < kids.len) {
                if (try self.itemSprite(a, &kids[k], &.{}, px, py - icon_mod.cell, .filler)) |s| try socks.append(a, s);
                k += 1;
            }
        }
        l.sockets = socks.items;
    }

    fn newLayout(self: *Drawer, kind: layout.Kind) layout.Layout {
        var l = layout.Layout{ .arena = std.heap.ArenaAllocator.init(self.gpa), .kind = kind, .width = 1, .height = 1 };
        for (&l.text_rgb, 0..) |*c, i| c.* = formats.pl2.textColor(self.pl2, @enumFromInt(i)) catch .{ 0, 0, 0 };
        l.line_pitch = self.metrics().pitch;
        return l;
    }

    /// The icon's display list: the item's cells (29 px each) plus the one column left of them the
    /// leftmost sockets reach; `origin_x/y` is the top-left cell corner.
    pub fn layoutIcon(self: *Drawer, records: []const wire.Item, opts: icon_mod.Options) !layout.Layout {
        var l = self.newLayout(.icon);
        errdefer l.deinit();
        const a = l.arena.allocator();
        if (records.len == 0) return l;
        const g = (try self.icons.gfx(a, &records[0], records[1..])) orelse return l;
        const margin: i32 = 1;
        l.width = @as(i32, g.w) * icon_mod.cell + margin;
        l.height = @as(i32, g.h) * icon_mod.cell;
        l.origin_x = margin;
        try self.placeItem(a, &l, records, opts, margin, 0);
        return l;
    }

    const Box = struct { w: i32, h: i32, over: i32, lines: []const []const u8 };

    fn boxOf(self: *const Drawer, a: std.mem.Allocator, desc: itemdesc.Desc) !Box {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, desc.text, '\n');
        while (it.next()) |l| try lines.append(a, l);
        const m = self.metrics();
        var widest: i32 = 0;
        for (lines.items) |l| widest = @max(widest, self.lineWidth(l));
        const box_h = @divTrunc(m.height_per_line * @as(i32, @intCast(lines.items.len)), 10);
        // glyph cells are taller than the line pitch; room for the top line's cell
        const cell_h: i32 = if (self.font.sheet.frames.len != 0) @intCast(self.font.sheet.frames[0].height) else 16;
        const over = @max(0, cell_h - (box_h - m.lift - (@as(i32, @intCast(lines.items.len)) - 1) * m.pitch));
        return .{ .w = widest + 8, .h = box_h, .over = over, .lines = lines.items };
    }

    /// The tooltip's display list. `origin_x/y` is the box's top-left, which sits lower than the top
    /// when glyph cells reach above the box.
    pub fn layoutTooltip(self: *Drawer, desc: itemdesc.Desc) !layout.Layout {
        var l = self.newLayout(.tooltip);
        errdefer l.deinit();
        const a = l.arena.allocator();
        if (desc.text.len == 0) return l;
        const b = try self.boxOf(a, desc);
        l.width = b.w;
        l.height = b.h + b.over;
        l.origin_y = b.over;
        try self.placeText(a, &l, desc, b, 0, b.over);
        return l;
    }

    /// The box and the lines of the D2Win tooltip draw 0x00503000, the box's top-left at (left, top).
    fn placeText(self: *Drawer, a: std.mem.Allocator, l: *layout.Layout, desc: itemdesc.Desc, b: Box, left: i32, top: i32) !void {
        const m = self.metrics();
        l.box = .{ .rect = .{ .x = left, .y = top, .w = b.w, .h = b.h }, .rgb = self.pal.rgb(0), .alpha = DrawMode.less_transparent.alpha() };
        l.centered = desc.centered;
        l.base_color = desc.base_color;
        var out = try a.alloc(layout.Line, b.lines.len);
        var color: u8 = desc.base_color;
        const bottom = top + b.h;
        for (b.lines, 0..) |text, k| {
            const y = bottom - m.lift - @as(i32, @intCast(k)) * m.pitch;
            const lw = self.lineWidth(text);
            const x0 = if (desc.centered) left + ((b.w - lw) >> 1) else left;
            var x = x0;
            var spans: std.ArrayListUnmanaged(layout.Span) = .empty;
            var glyphs: std.ArrayListUnmanaged(layout.Glyph) = .empty;
            var chars: std.ArrayListUnmanaged(u8) = .empty;
            var span_x = x;
            var span_color = color;
            const flush = struct {
                fn f(al: std.mem.Allocator, sp: *std.ArrayListUnmanaged(layout.Span), gl: *std.ArrayListUnmanaged(layout.Glyph), ch: *std.ArrayListUnmanaged(u8), c: u8, sx: i32, end: i32) !void {
                    if (ch.items.len == 0) return;
                    try sp.append(al, .{ .color = c, .text = try ch.toOwnedSlice(al), .x = sx, .width = end - sx, .glyphs = try gl.toOwnedSlice(al) });
                }
            }.f;
            var view = std.unicode.Utf8View.initUnchecked(text);
            var cps = view.iterator();
            while (cps.nextCodepoint()) |cp| {
                if (cp == 0xff) {
                    const save = cps.i;
                    if (cps.nextCodepoint()) |n1| {
                        if (n1 == 'c') {
                            const v: i32 = if (cps.nextCodepoint()) |dg| @as(i32, @intCast(dg)) - '0' else 0;
                            const nc: u8 = if (v > 12 or v < 0) 0 else @intCast(v);
                            if (nc != color) {
                                try flush(a, &spans, &glyphs, &chars, span_color, span_x, x);
                                span_x = x;
                                span_color = nc;
                            }
                            color = nc;
                            continue;
                        }
                    } else {
                        color = 0;
                        break;
                    }
                    cps.i = save;
                }
                if (chars.items.len == 0) {
                    span_x = x;
                    span_color = color;
                }
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &enc) catch 1;
                try chars.appendSlice(a, enc[0..n]);
                const g = self.font.table.latin(cp);
                if (g.frame < self.font.sheet.frames.len) {
                    const f = &self.font.sheet.frames[g.frame];
                    try glyphs.append(a, .{
                        .code = cp,
                        .frame = g.frame,
                        .rect = .{ .x = x + f.offset_x, .y = y + f.offset_y - @as(i32, @intCast(f.height)), .w = @intCast(f.width), .h = @intCast(f.height) },
                        .color = color,
                        .advance = g.width,
                    });
                }
                x += g.width;
            }
            try flush(a, &spans, &glyphs, &chars, span_color, span_x, x);
            // the description's first line is the bottom one
            out[b.lines.len - 1 - k] = .{ .x = x0, .baseline = y, .width = lw, .spans = spans.items };
        }
        l.lines = out;
    }

    /// The hover card's display list: the item as it sits in the grid when hovered (green cells, icon,
    /// sockets) and its tooltip centred above it, the box bottom 2 px into the item's top edge.
    pub fn layoutCard(self: *Drawer, records: []const wire.Item, opts: itemdesc.Options) !layout.Layout {
        var l = self.newLayout(.card);
        errdefer l.deinit();
        const a = l.arena.allocator();
        if (records.len == 0) return l;
        const g = (try self.icons.gfx(a, &records[0], records[1..])) orelse return l;
        const desc = try self.describe(a, records, opts);
        const b = try self.boxOf(a, desc);
        const item_w = @as(i32, g.w) * icon_mod.cell;
        const item_h = @as(i32, g.h) * icon_mod.cell;
        const box_left_rel = @divTrunc(item_w, 2) - (b.w >> 1);
        const min_x = @min(box_left_rel, -1);
        const max_x = @max(box_left_rel + b.w, item_w);
        const box_top_rel = 2 - b.h;
        const min_y = box_top_rel - b.over;
        l.width = max_x - min_x;
        l.height = item_h - min_y;
        const ox = -min_x;
        const oy = -min_y;
        l.origin_x = ox;
        l.origin_y = oy;
        try self.placeItem(a, &l, records, .{ .background = .hovered, .sockets = true }, ox, oy);
        try self.placeText(a, &l, desc, b, ox + box_left_rel, oy + box_top_rel);
        return l;
    }

    // ---------------------------------------------------------------------------------------------
    // the default providers: the 1.14d DC6 art from the assets

    pub fn defaults(self: *Drawer) raster.Providers {
        return .{
            .glyph = .{ .ctx = self, .draw = drawGlyph },
            .sprite = .{ .ctx = self, .draw = drawSprite },
        };
    }

    /// One DC6 frame into a tile, point-sampled to the tile's scale.
    fn frameIntoTile(self: *const Drawer, f: *const formats.dc6.Frame, remap: ?[]const u8, scale: u32, t: raster.Tile) void {
        var view = Image{ .w = t.w, .h = t.h, .px = t.rgba };
        view.blitAlpha(f.indices, f.width, f.height, &self.pal, 0, 0, remap, 255, scale);
    }

    fn drawGlyph(ctx: *anyopaque, font: []const u8, g: *const layout.Glyph, scale: u32, t: raster.Tile) bool {
        const self: *Drawer = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, font, layout.font_name) or g.frame >= self.font.sheet.frames.len) return false;
        const shift = formats.pl2.textShift(self.pl2, @enumFromInt(g.color)) catch null;
        self.frameIntoTile(&self.font.sheet.frames[g.frame], shift, scale, t);
        return true;
    }

    fn drawSprite(ctx: *anyopaque, sp: *const layout.Sprite, scale: u32, t: raster.Tile) bool {
        const self: *Drawer = @ptrCast(@alignCast(ctx));
        const sheet: *const formats.dc6.Dc6 = if (sp.ref.role == .socket) (if (self.socket) |*s| s else return false) else (self.sheetAt(sp.ref.path) orelse return false);
        if (sp.ref.frame >= sheet.frames.len) return false;
        self.frameIntoTile(&sheet.frames[sp.ref.frame], self.remapOf(sp.ref.colormap), scale, t);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // the pictures: a layout drawn by the default providers

    /// The grid icon (see `layoutIcon`).
    pub fn icon(self: *Drawer, records: []const wire.Item, opts: icon_mod.Options) !Image {
        var l = try self.layoutIcon(records, opts);
        defer l.deinit();
        return raster.rasterize(self.gpa, &l, .{}, self.defaults(), 1);
    }

    /// The tooltip box for a description (see `layoutTooltip`).
    pub fn tooltip(self: *Drawer, desc: itemdesc.Desc) !Image {
        var l = try self.layoutTooltip(desc);
        defer l.deinit();
        return raster.rasterize(self.gpa, &l, .{}, self.defaults(), 1);
    }

    /// The hover card (see `layoutCard`).
    pub fn card(self: *Drawer, records: []const wire.Item, opts: itemdesc.Options) !Image {
        var l = try self.layoutCard(records, opts);
        defer l.deinit();
        return raster.rasterize(self.gpa, &l, .{}, self.defaults(), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // text metrics

    const Metrics = struct { pitch: i32, height_per_line: i32, lift: i32 };

    fn metrics(self: *const Drawer) Metrics {
        const lh: i32 = self.font.table.height;
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
                if (n1 == 'm' or n1 == 'M') w += self.font.table.latin('m').width;
                _ = cps.nextCodepoint();
                continue;
            }
            w += self.font.table.latin(cp).width;
        }
        return w;
    }
};

const socket_path = "data/global/ui/panel/gemsocket.dc6";
