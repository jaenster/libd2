//! The C ABI of d2-itemdraw (d2itemdraw.h): C, the combined wasm, Go and .NET call this. No Zig type
//! crosses: handles are opaque, options are an `extern struct`, text and pictures come back as bytes.
//!
//! Lifetime: an archive added with `d2itemdraw_add_archive` is borrowed and must stay valid until the
//! context is destroyed (MPQs are large; copying them would double the memory). Loose files are copied.
//! Hosts that cannot hand out their own memory (wasm) get it from `d2itemdraw_alloc`.

const std = @import("std");
const lib = @import("lib.zig");
const item = @import("d2-item");

pub const abi_version: u32 = 1;

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
    if (i.png == null) i.png = i.img.png(gpa) catch return null;
    if (out_len) |l| l.* = i.png.?.len;
    return i.png.?.ptr;
}

pub export fn d2itemdraw_image_free(img: ?*Image) void {
    const i = img orelse return;
    if (i.png) |p| gpa.free(p);
    i.img.deinit(gpa);
    gpa.destroy(i);
}

test "text without art: the description of a record built from the stock tables" {
    const c = d2itemdraw_create() orelse return error.NoContext;
    defer d2itemdraw_destroy(c);
    try std.testing.expectEqual(abi_version, d2itemdraw_abi_version());
    // no records: an error, not a crash
    try std.testing.expect(d2itemdraw_text(c, null, 0, null, 1, null, 0) < 0);
}
