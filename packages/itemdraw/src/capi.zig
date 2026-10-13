//! The C ABI of d2-itemdraw (d2itemdraw.h): C, the combined wasm, Go and .NET call this. No Zig type
//! crosses: handles are opaque, options are an `extern struct`, text and pictures come back as bytes.
//!
//! Lifetime: an archive added with `d2itemdraw_add_archive` is borrowed and must stay valid until the
//! context is destroyed (MPQs are large; copying them would double the memory). Loose files are copied.
//! Hosts that cannot hand out their own memory (wasm) get it from `d2itemdraw_alloc`.

const std = @import("std");
const lib = @import("lib.zig");
const item = @import("d2-item");

pub const abi_version: u32 = 2;

/// d2-core's process heap: smp_allocator natively, the coalescing free list on wasm.
const gpa = @import("d2-core").heap.default;

/// Who looks at the item. `has_viewer == 0`: the neutral character (every requirement met, no class).
pub const D2ItemDrawOptions = extern struct {
    has_viewer: i32 = 0,
    /// 0 Amazon, 1 Sorceress, 2 Necromancer, 3 Paladin, 4 Barbarian, 5 Druid, 6 Assassin.
    class_id: i32 = 0,
    level: i32 = 99,
    strength: i32 = 0,
    dexterity: i32 = 0,
    /// The act whose palette pictures are drawn in (1..5); read when the art is loaded.
    act: i32 = 1,
};

comptime {
    std.debug.assert(@sizeOf(D2ItemDrawOptions) == 24);
}

pub const Ctx = struct {
    assets: lib.Assets,
    drawer: ?*lib.Drawer = null,
    act: u8 = 1,
    t: item.Tables,
    s: item.strings.Strings,
    describer: item.itemdesc.Describer,
};

pub const Image = struct {
    img: lib.Image,
    png: ?[]u8 = null,
};

fn descOptions(o: ?*const D2ItemDrawOptions) item.itemdesc.Options {
    const opts = o orelse return .{};
    if (opts.has_viewer == 0) return .{ .level = opts.level };
    return .{ .viewer = .{
        .class = @intCast(std.math.clamp(opts.class_id, 0, 6)),
        .level = opts.level,
        .strength = opts.strength,
        .dexterity = opts.dexterity,
    } };
}

pub export fn d2itemdraw_abi_version() u32 {
    return abi_version;
}

/// Memory the host fills (archive or record bytes in a wasm host). Null on failure.
pub export fn d2itemdraw_alloc(len: usize) ?[*]u8 {
    const s = gpa.alloc(u8, len) catch return null;
    return s.ptr;
}

pub export fn d2itemdraw_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}

pub export fn d2itemdraw_create() ?*Ctx {
    const c = gpa.create(Ctx) catch return null;
    c.assets = lib.Assets.init(gpa);
    c.drawer = null;
    c.act = 1;
    c.t = item.Tables.load(gpa) catch {
        gpa.destroy(c);
        return null;
    };
    c.s = item.strings.Strings.load(gpa) catch {
        c.t.deinit();
        gpa.destroy(c);
        return null;
    };
    c.describer = item.itemdesc.Describer.init(gpa, &c.t, &c.s) catch {
        c.s.deinit();
        c.t.deinit();
        gpa.destroy(c);
        return null;
    };
    return c;
}

pub export fn d2itemdraw_destroy(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    if (c.drawer) |d| d.deinit();
    c.describer.deinit();
    c.s.deinit();
    c.t.deinit();
    c.assets.deinit();
    gpa.destroy(c);
}

/// Add an MPQ, searched after those added before it (add Patch_D2, then d2exp, then d2data). 0 on success.
pub export fn d2itemdraw_add_archive(ctx: ?*Ctx, bytes: ?[*]const u8, len: usize) i32 {
    const c = ctx orelse return -1;
    const b = bytes orelse return -2;
    c.assets.addArchive(b[0..len]) catch return -3;
    return 0;
}

/// Add one file under its game path (`data/global/items/invamu1.dc6`); it wins over the archives.
pub export fn d2itemdraw_add_file(ctx: ?*Ctx, name: ?[*:0]const u8, bytes: ?[*]const u8, len: usize) i32 {
    const c = ctx orelse return -1;
    const n = name orelse return -2;
    const b = bytes orelse return -2;
    c.assets.addFile(std.mem.span(n), b[0..len]) catch return -3;
    return 0;
}

fn drawer(c: *Ctx, act: i32) ?*lib.Drawer {
    const want: u8 = @intCast(std.math.clamp(act, 1, 5));
    if (c.drawer) |d| {
        if (c.act == want) return d;
        d.deinit();
        c.drawer = null;
    }
    c.drawer = lib.Drawer.init(gpa, &c.assets, .{ .act = want }) catch return null;
    c.act = want;
    return c.drawer;
}

fn records(arena: std.mem.Allocator, bytes: ?[*]const u8, len: usize) ?[]const item.wire.Item {
    const b = bytes orelse return null;
    const r = lib.parseRecords(arena, b[0..len], 64) catch return null;
    if (r.len == 0) return null;
    return r;
}

/// The description of the item whose records (`JM` host record, then its socketed records) are `bytes`.
/// mode 0: the engine's own string (UTF-8, first line at the bottom, `ÿcN` colour codes);
/// mode 1: plain text top to bottom; mode 2: top to bottom with each colour run as `{N}text`.
/// Writes at most `cap` bytes and returns the full length, or a negative error.
pub export fn d2itemdraw_text(ctx: ?*Ctx, bytes: ?[*]const u8, len: usize, opts: ?*const D2ItemDrawOptions, mode: i32, out: ?[*]u8, cap: usize) i32 {
    const c = ctx orelse return -1;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const recs = records(a, bytes, len) orelse return -2;
    var o = descOptions(opts);
    o.animdata = if (c.drawer) |d| d.animdata else null;
    const desc = c.describer.describe(a, &recs[0], recs[1..], o) catch return -3;
    const text: []const u8 = switch (mode) {
        0 => desc.text,
        1 => item.itemdesc.plain(a, desc) catch return -3,
        else => blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            const ls = item.itemdesc.lines(a, desc) catch return -3;
            for (ls, 0..) |l, i| {
                if (i != 0) buf.append(a, '\n') catch return -3;
                for (l.spans) |sp| buf.print(a, "{{{d}}}{s}", .{ sp.color, sp.text }) catch return -3;
            }
            break :blk buf.items;
        },
    };
    if (out) |dst| {
        const n = @min(cap, text.len);
        @memcpy(dst[0..n], text[0..n]);
    }
    return @intCast(text.len);
}

fn finish(img: lib.Image) ?*Image {
    const h = gpa.create(Image) catch {
        var i = img;
        i.deinit(gpa);
        return null;
    };
    h.* = .{ .img = img };
    return h;
}

/// The grid icon. background: 0 none, 1 normal (blue), 2 hovered (green), 3 unusable (red),
/// 4 unidentified; sockets: non-zero draws the sockets and their fillers as for the hovered item.
pub export fn d2itemdraw_icon(ctx: ?*Ctx, bytes: ?[*]const u8, len: usize, opts: ?*const D2ItemDrawOptions, background: i32, sockets: i32) ?*Image {
    const c = ctx orelse return null;
    const d = drawer(c, if (opts) |o| o.act else 1) orelse return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const recs = records(arena.allocator(), bytes, len) orelse return null;
    const bg: lib.Background = switch (background) {
        1 => .normal,
        2 => .hovered,
        3 => .unusable,
        4 => .unidentified,
        else => .none,
    };
    return finish(d.icon(recs, .{ .background = bg, .sockets = sockets != 0 }) catch return null);
}

/// The hover tooltip box alone.
pub export fn d2itemdraw_tooltip(ctx: ?*Ctx, bytes: ?[*]const u8, len: usize, opts: ?*const D2ItemDrawOptions) ?*Image {
    const c = ctx orelse return null;
    const d = drawer(c, if (opts) |o| o.act else 1) orelse return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const recs = records(a, bytes, len) orelse return null;
    const desc = d.describe(a, recs, descOptions(opts)) catch return null;
    return finish(d.tooltip(desc) catch return null);
}

/// The item as on hover: its cells tinted, the icon with its sockets and the tooltip above it.
pub export fn d2itemdraw_card(ctx: ?*Ctx, bytes: ?[*]const u8, len: usize, opts: ?*const D2ItemDrawOptions) ?*Image {
    const c = ctx orelse return null;
    const d = drawer(c, if (opts) |o| o.act else 1) orelse return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const recs = records(arena.allocator(), bytes, len) orelse return null;
    return finish(d.card(recs, descOptions(opts)) catch return null);
}

pub export fn d2itemdraw_image_width(img: ?*const Image) u32 {
    return if (img) |i| i.img.w else 0;
}

pub export fn d2itemdraw_image_height(img: ?*const Image) u32 {
    return if (img) |i| i.img.h else 0;
}

/// width*height*4 bytes of straight-alpha RGBA, rows top-down. Valid until the image is freed.
pub export fn d2itemdraw_image_rgba(img: ?*const Image) ?[*]const u8 {
    return if (img) |i| i.img.px.ptr else null;
}

/// The picture as a PNG, encoded on first use. Valid until the image is freed.
pub export fn d2itemdraw_image_png(img: ?*Image, out_len: ?*usize) ?[*]const u8 {
    const i = img orelse return null;
    if (i.png == null) i.png = lib.png(gpa, &i.img) catch return null;
    if (out_len) |l| l.* = i.png.?.len;
    return i.png.?.ptr;
}

pub export fn d2itemdraw_image_free(img: ?*Image) void {
    const i = img orelse return;
    if (i.png) |p| gpa.free(p);
    i.img.deinit(gpa);
    gpa.destroy(i);
}

// -------------------------------------------------------------------------------------------------
// layout and providers

pub const kind_icon: i32 = 0;
pub const kind_tooltip: i32 = 1;
pub const kind_card: i32 = 2;

pub const Layout = struct {
    l: lib.Layout,
    json: ?[]u8 = null,
};

pub const D2ItemDrawRect = extern struct { x: i32, y: i32, w: i32, h: i32 };

/// The glyph a provider paints: font name (NUL-terminated), code point, Font16 frame, text colour id
/// (0..12) and the glyph cell in layout pixels.
pub const D2ItemDrawGlyphRef = extern struct {
    font: [*:0]const u8,
    code: u32,
    frame: u32,
    color: u32,
    cell: D2ItemDrawRect,
};

/// The inventory frame a provider paints: game path (NUL-terminated), frame, colour map (-1: none),
/// role (0 item, 1 socket frame, 2 socketed filler), ethereal, and the rectangle in layout pixels.
pub const D2ItemDrawSpriteRef = extern struct {
    path: [*:0]const u8,
    frame: u32,
    colormap_set: i32,
    colormap_row: i32,
    role: i32,
    ethereal: u32,
    rect: D2ItemDrawRect,
};

/// Paint into `rgba` (w*h*4 bytes, zeroed, straight alpha): the cell (or rectangle) at `scale`.
/// Return non-zero when painted; zero hands the tile to libd2's own 1.14d provider.
pub const GlyphFn = *const fn (user: ?*anyopaque, glyph: *const D2ItemDrawGlyphRef, scale: u32, w: u32, h: u32, rgba: [*]u8) callconv(.c) i32;
pub const SpriteFn = *const fn (user: ?*anyopaque, sprite: *const D2ItemDrawSpriteRef, scale: u32, w: u32, h: u32, rgba: [*]u8) callconv(.c) i32;

pub const D2ItemDrawProviders = extern struct {
    user: ?*anyopaque = null,
    glyph: ?GlyphFn = null,
    sprite: ?SpriteFn = null,
};

/// The display list of an item: kind 0 icon (with `background` and `sockets` as in d2itemdraw_icon),
/// 1 tooltip, 2 card. Needs the art (the font's metrics and the palette); NULL without it.
pub export fn d2itemdraw_layout(ctx: ?*Ctx, bytes: ?[*]const u8, len: usize, opts: ?*const D2ItemDrawOptions, kind: i32, background: i32, sockets: i32) ?*Layout {
    const c = ctx orelse return null;
    const d = drawer(c, if (opts) |o| o.act else 1) orelse return null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const recs = records(a, bytes, len) orelse return null;
    const l = switch (kind) {
        kind_icon => d.layoutIcon(recs, .{ .background = background_of(background), .sockets = sockets != 0 }),
        kind_tooltip => blk: {
            const desc = d.describe(a, recs, descOptions(opts)) catch return null;
            break :blk d.layoutTooltip(desc);
        },
        else => d.layoutCard(recs, descOptions(opts)),
    } catch return null;
    const h = gpa.create(Layout) catch {
        var x = l;
        x.deinit();
        return null;
    };
    h.* = .{ .l = l };
    return h;
}

fn background_of(b: i32) lib.Background {
    return switch (b) {
        1 => .normal,
        2 => .hovered,
        3 => .unusable,
        4 => .unidentified,
        else => .none,
    };
}

/// The display list as JSON (UTF-8). Valid until the layout is freed.
pub export fn d2itemdraw_layout_json(layout: ?*Layout, out_len: ?*usize) ?[*]const u8 {
    const h = layout orelse return null;
    if (h.json == null) h.json = h.l.json(gpa) catch return null;
    if (out_len) |l| l.* = h.json.?.len;
    return h.json.?.ptr;
}

pub export fn d2itemdraw_layout_width(layout: ?*const Layout) i32 {
    return if (layout) |h| h.l.width else 0;
}

pub export fn d2itemdraw_layout_height(layout: ?*const Layout) i32 {
    return if (layout) |h| h.l.height else 0;
}

/// The layout's text, top to bottom, at most `limit` bytes (<= 0: 1024, what Discord takes as alt text).
/// Writes at most `cap` bytes, returns the full length or a negative error.
pub export fn d2itemdraw_layout_text(layout: ?*const Layout, limit: i32, out: ?[*]u8, cap: usize) i32 {
    const h = layout orelse return -1;
    return copyOut(h.l.text(gpa, limitOf(limit)) catch return -3, out, cap);
}

pub export fn d2itemdraw_layout_free(layout: ?*Layout) void {
    const h = layout orelse return;
    if (h.json) |j| gpa.free(j);
    h.l.deinit();
    gpa.destroy(h);
}

fn limitOf(limit: i32) usize {
    return if (limit <= 0) 1024 else @intCast(limit);
}

fn copyOut(text: []u8, out: ?[*]u8, cap: usize) i32 {
    defer gpa.free(text);
    if (out) |dst| {
        const n = @min(cap, text.len);
        @memcpy(dst[0..n], text[0..n]);
    }
    return @intCast(text.len);
}

/// The alt text of an item: its description top to bottom, whole lines up to `limit` bytes (<= 0: 1024).
/// The same lines the layout positions; it needs no art.
pub export fn d2itemdraw_alt_text(ctx: ?*Ctx, bytes: ?[*]const u8, len: usize, opts: ?*const D2ItemDrawOptions, limit: i32, out: ?[*]u8, cap: usize) i32 {
    const c = ctx orelse return -1;
    var l = lib.Layout{ .arena = std.heap.ArenaAllocator.init(gpa), .kind = .tooltip, .width = 0, .height = 0 };
    defer l.deinit();
    const a = l.arena.allocator();
    const recs = records(a, bytes, len) orelse return -2;
    const desc = c.describer.describe(a, &recs[0], recs[1..], descOptions(opts)) catch return -3;
    const ls = item.itemdesc.lines(a, desc) catch return -3;
    var lines = a.alloc(lib.layout.Line, ls.len) catch return -3;
    for (ls, 0..) |dl, i| {
        var spans = a.alloc(lib.layout.Span, dl.spans.len) catch return -3;
        for (dl.spans, 0..) |s, k| spans[k] = .{ .color = s.color, .text = s.text, .x = 0, .width = 0, .glyphs = &.{} };
        lines[i] = .{ .x = 0, .baseline = 0, .width = 0, .spans = spans };
    }
    l.lines = lines;
    return copyOut(l.text(gpa, limitOf(limit)) catch return -3, out, cap);
}

const Bridge = struct {
    p: D2ItemDrawProviders,
    path_buf: [256]u8 = undefined,

    fn glyph(ctx: *anyopaque, font: []const u8, g: *const lib.layout.Glyph, scale: u32, t: lib.Tile) bool {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const f = self.p.glyph orelse return false;
        _ = font;
        const ref = D2ItemDrawGlyphRef{
            .font = lib.layout.font_name,
            .code = g.code,
            .frame = g.frame,
            .color = g.color,
            .cell = .{ .x = g.rect.x, .y = g.rect.y, .w = g.rect.w, .h = g.rect.h },
        };
        return f(self.p.user, &ref, scale, t.w, t.h, t.rgba.ptr) != 0;
    }

    fn sprite(ctx: *anyopaque, s: *const lib.layout.Sprite, scale: u32, t: lib.Tile) bool {
        const self: *Bridge = @ptrCast(@alignCast(ctx));
        const f = self.p.sprite orelse return false;
        const n = @min(s.ref.path.len, self.path_buf.len - 1);
        @memcpy(self.path_buf[0..n], s.ref.path[0..n]);
        self.path_buf[n] = 0;
        const ref = D2ItemDrawSpriteRef{
            .path = self.path_buf[0..n :0],
            .frame = s.ref.frame,
            .colormap_set = if (s.ref.colormap) |c| c.set else -1,
            .colormap_row = if (s.ref.colormap) |c| c.row else -1,
            .role = @intFromEnum(s.ref.role),
            .ethereal = @intFromBool(s.ethereal),
            .rect = .{ .x = s.rect.x, .y = s.rect.y, .w = s.rect.w, .h = s.rect.h },
        };
        return f(self.p.user, &ref, scale, t.w, t.h, t.rgba.ptr) != 0;
    }
};

/// Draw a layout at `scale` through `providers` (NULL, or a NULL callback: libd2's 1.14d DC6 art from
/// the context's archives). A callback returning 0 also falls back to it.
pub export fn d2itemdraw_rasterize(ctx: ?*Ctx, layout: ?*const Layout, providers: ?*const D2ItemDrawProviders, scale: u32) ?*Image {
    const c = ctx orelse return null;
    const h = layout orelse return null;
    const fallback: lib.Providers = if (c.drawer) |d| d.defaults() else .{};
    var bridge = Bridge{ .p = if (providers) |p| p.* else .{} };
    const primary = lib.Providers{
        .glyph = if (bridge.p.glyph != null) .{ .ctx = &bridge, .draw = Bridge.glyph } else null,
        .sprite = if (bridge.p.sprite != null) .{ .ctx = &bridge, .draw = Bridge.sprite } else null,
    };
    return finish(lib.rasterize(gpa, &h.l, primary, fallback, scale) catch return null);
}

test "text without art: the description of a record built from the stock tables" {
    const c = d2itemdraw_create() orelse return error.NoContext;
    defer d2itemdraw_destroy(c);
    try std.testing.expectEqual(abi_version, d2itemdraw_abi_version());
    // no records: an error, not a crash
    try std.testing.expect(d2itemdraw_text(c, null, 0, null, 1, null, 0) < 0);
}
