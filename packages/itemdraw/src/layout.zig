//! The display list: where 1.14d puts every part of an item's icon, tooltip and hover card, in the
//! game's own pixel units, with nothing drawn yet.
//!
//! Positions follow the same functions the pictures do (icon.zig and draw.zig name them): the 29 px
//! cells, the frame of each item at its cell corner, the socket table, the tooltip box (widest line plus
//! 8, 16 px per Latin line) and every glyph's cell, measured with the Font16 widths of the font table.
//! The engine does not wrap item text, so neither does this; lines break only where the description does.
//!
//! A glyph is a cell, not a picture: a renderer draws whatever it likes INTO that cell (the DC6 glyph,
//! a vector face), so the layout is the same whatever font draws it. Likewise a sprite is a frame
//! reference and a rectangle. `raster.zig` draws a display list through providers; `json` writes it as
//! plain data for a renderer elsewhere (a web page drawing it as HTML/CSS).

const std = @import("std");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Kind = enum { icon, tooltip, card };

/// A solid fill: a grid cell's tint, or the tooltip box.
pub const Fill = struct { rect: Rect, rgb: [3]u8, alpha: u8 };

pub const ColorMap = struct { set: u8, row: u8 };

pub const Role = enum { item, socket, filler };

/// One inventory frame: the DC6 the game draws, which frame, through which colour map.
pub const SpriteRef = struct {
    /// Game path of the DC6, `data/global/items/invamu1.dc6`.
    path: []const u8,
    frame: u32 = 0,
    /// Item colour map: `InvTrans` file (set) and the row in it.
    colormap: ?ColorMap = null,
    role: Role = .item,
};

pub const Sprite = struct {
    rect: Rect,
    ref: SpriteRef,
    /// The draw mode as alpha: 255 solid, 0x80 ethereal, 0x40 the socket frame.
    alpha: u8,
    ethereal: bool = false,
};

/// One glyph: its code, the Font16 frame the game draws for it, the cell that frame covers, its colour
/// (the text colour id, 0..12) and how far the pen moves after it.
pub const Glyph = struct { code: u21, frame: u16, rect: Rect, color: u8, advance: u8 };

/// A run of one colour on a line.
pub const Span = struct { color: u8, text: []const u8, x: i32, width: i32, glyphs: []Glyph };

pub const Line = struct { x: i32, baseline: i32, width: i32, spans: []Span };

pub const font_name = "font16";

pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    width: i32,
    height: i32,
    /// The item's top-left grid cell corner (icon, card), or the box's top-left (tooltip).
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    cells: []Fill = &.{},
    icon: ?Sprite = null,
    /// Socket frames and the items in them, in draw order (each socket's frame, then its filler).
    sockets: []Sprite = &.{},
    box: ?Fill = null,
    /// Top to bottom.
    lines: []Line = &.{},
    centered: bool = true,
    /// The colour the description starts in.
    base_color: u8 = 0,
    /// Nominal RGB of the 13 text colours (the pl2's own table); glyphs are drawn through the colour's
    /// shift, this is for renderers that colour text themselves.
    text_rgb: [13][3]u8 = std.mem.zeroes([13][3]u8),
    line_pitch: i32 = 16,

    pub fn deinit(self: *Layout) void {
        self.arena.deinit();
    }

    /// The description as plain text, top to bottom, from the same lines. At most `limit` bytes (0: no
    /// limit): whole lines while they fit, and a first line too long for it cut at a character.
    pub fn text(self: *const Layout, gpa: std.mem.Allocator, limit: usize) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.lines, 0..) |l, i| {
            var line: std.ArrayListUnmanaged(u8) = .empty;
            defer line.deinit(gpa);
            for (l.spans) |s| try line.appendSlice(gpa, s.text);
            const sep: usize = if (i == 0) 0 else 1;
            if (limit != 0 and out.items.len + sep + line.items.len > limit) {
                if (out.items.len == 0) try out.appendSlice(gpa, cutUtf8(line.items, limit));
                break;
            }
            if (sep == 1) try out.append(gpa, '\n');
            try out.appendSlice(gpa, line.items);
        }
        return out.toOwnedSlice(gpa);
    }

    /// The display list as JSON.
    pub fn json(self: *const Layout, gpa: std.mem.Allocator) ![]u8 {
        var w = Json{ .gpa = gpa };
        errdefer w.buf.deinit(gpa);
        try w.raw("{\"kind\":");
        try w.str(@tagName(self.kind));
        try w.raw(",\"width\":");
        try w.int(self.width);
        try w.raw(",\"height\":");
        try w.int(self.height);
        try w.raw(",\"origin\":[");
        try w.int(self.origin_x);
        try w.raw(",");
        try w.int(self.origin_y);
        try w.raw("],\"font\":");
        try w.str(font_name);
        try w.raw(",\"linePitch\":");
        try w.int(self.line_pitch);
        try w.raw(",\"centered\":");
        try w.raw(if (self.centered) "true" else "false");
        try w.raw(",\"baseColor\":");
        try w.int(self.base_color);
        try w.raw(",\"textColors\":[");
        for (self.text_rgb, 0..) |c, i| {
            if (i != 0) try w.raw(",");
            try w.rgb(c);
        }
        try w.raw("],\"cells\":[");
        for (self.cells, 0..) |f, i| {
            if (i != 0) try w.raw(",");
            try w.fill(f);
        }
        try w.raw("],\"icon\":");
        if (self.icon) |s| try w.sprite(s) else try w.raw("null");
        try w.raw(",\"sockets\":[");
        for (self.sockets, 0..) |s, i| {
            if (i != 0) try w.raw(",");
            try w.sprite(s);
        }
        try w.raw("],\"box\":");
        if (self.box) |b| try w.fill(b) else try w.raw("null");
        try w.raw(",\"lines\":[");
        for (self.lines, 0..) |l, i| {
            if (i != 0) try w.raw(",");
            try w.raw("{\"x\":");
            try w.int(l.x);
            try w.raw(",\"baseline\":");
            try w.int(l.baseline);
            try w.raw(",\"width\":");
            try w.int(l.width);
            try w.raw(",\"spans\":[");
            for (l.spans, 0..) |s, k| {
                if (k != 0) try w.raw(",");
                try w.raw("{\"color\":");
                try w.int(s.color);
                try w.raw(",\"text\":");
                try w.str(s.text);
                try w.raw(",\"x\":");
                try w.int(s.x);
                try w.raw(",\"width\":");
                try w.int(s.width);
                try w.raw(",\"glyphs\":[");
                for (s.glyphs, 0..) |g, j| {
                    if (j != 0) try w.raw(",");
                    try w.raw("{\"code\":");
                    try w.int(g.code);
                    try w.raw(",\"frame\":");
                    try w.int(g.frame);
                    try w.raw(",");
                    try w.rectFields(g.rect);
                    try w.raw(",\"advance\":");
                    try w.int(g.advance);
                    try w.raw("}");
                }
                try w.raw("]}");
            }
            try w.raw("]}");
        }
        try w.raw("],\"text\":");
        const t = try self.text(gpa, 0);
        defer gpa.free(t);
        try w.str(t);
        try w.raw("}");
        return w.buf.toOwnedSlice(gpa);
    }
};

/// The longest prefix of `s` of at most `limit` bytes that ends on a character boundary.
fn cutUtf8(s: []const u8, limit: usize) []const u8 {
    if (s.len <= limit) return s;
    var n = limit;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

const Json = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn raw(self: *Json, s: []const u8) !void {
        try self.buf.appendSlice(self.gpa, s);
    }
    fn int(self: *Json, v: i64) !void {
        try self.buf.print(self.gpa, "{d}", .{v});
    }
    fn str(self: *Json, s: []const u8) !void {
        try self.buf.append(self.gpa, '"');
        for (s) |c| switch (c) {
            '"' => try self.raw("\\\""),
            '\\' => try self.raw("\\\\"),
            '\n' => try self.raw("\\n"),
            0...9, 11...0x1f => try self.buf.print(self.gpa, "\\u{x:0>4}", .{c}),
            else => try self.buf.append(self.gpa, c),
        };
        try self.buf.append(self.gpa, '"');
    }
    fn rgb(self: *Json, c: [3]u8) !void {
        try self.buf.print(self.gpa, "[{d},{d},{d}]", .{ c[0], c[1], c[2] });
    }
    fn rectFields(self: *Json, r: Rect) !void {
        try self.buf.print(self.gpa, "\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}", .{ r.x, r.y, r.w, r.h });
    }
    fn fill(self: *Json, f: Fill) !void {
        try self.raw("{");
        try self.rectFields(f.rect);
        try self.raw(",\"rgb\":");
        try self.rgb(f.rgb);
        try self.raw(",\"alpha\":");
        try self.int(f.alpha);
        try self.raw("}");
    }
    fn sprite(self: *Json, s: Sprite) !void {
        try self.raw("{");
        try self.rectFields(s.rect);
        try self.raw(",\"alpha\":");
        try self.int(s.alpha);
        try self.raw(",\"ethereal\":");
        try self.raw(if (s.ethereal) "true" else "false");
        try self.raw(",\"role\":");
        try self.str(@tagName(s.ref.role));
        try self.raw(",\"path\":");
        try self.str(s.ref.path);
        try self.raw(",\"frame\":");
        try self.int(s.ref.frame);
        try self.raw(",\"colormap\":");
        if (s.ref.colormap) |c| try self.buf.print(self.gpa, "{{\"set\":{d},\"row\":{d}}}", .{ c.set, c.row }) else try self.raw("null");
        try self.raw("}");
    }
};

test "text keeps whole lines under the limit and cuts a long first line at a character" {
    var l = Layout{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .kind = .tooltip, .width = 0, .height = 0 };
    defer l.deinit();
    const a = l.arena.allocator();
    var lines = try a.alloc(Line, 2);
    var s1 = try a.alloc(Span, 1);
    s1[0] = .{ .color = 4, .text = "Griff\xc3\xb6n", .x = 0, .width = 0, .glyphs = &.{} };
    var s2 = try a.alloc(Span, 1);
    s2[0] = .{ .color = 0, .text = "Diadem", .x = 0, .width = 0, .glyphs = &.{} };
    lines[0] = .{ .x = 0, .baseline = 0, .width = 0, .spans = s1 };
    lines[1] = .{ .x = 0, .baseline = 0, .width = 0, .spans = s2 };
    l.lines = lines;
    const gpa = std.testing.allocator;
    const all = try l.text(gpa, 0);
    defer gpa.free(all);
    try std.testing.expectEqualStrings("Griff\xc3\xb6n\nDiadem", all);
    const one = try l.text(gpa, 10);
    defer gpa.free(one);
    try std.testing.expectEqualStrings("Griff\xc3\xb6n", one);
    const cut = try l.text(gpa, 6);
    defer gpa.free(cut);
    try std.testing.expectEqualStrings("Griff", cut);
}
