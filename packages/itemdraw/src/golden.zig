//! Golden tests over real items: the two engine-played saves (EpicSorc, EpicAma) and a kit character
//! (testdata/kits/golden.kit at the repository root, built into a save here)
//! that adds set pieces worn and carried, a paladin shield, an ethereal runeword with charges, gemmed
//! and socketed white items, loose runes, gems and jewels, a tome, a key and the cube.
//!
//! The text of every item is compared, top to bottom with its colours, with and without a viewer,
//! against testdata/itemdraw/golden-text.txt; that needs no art. With -Dd2dir (the 1.14d MPQs) the icon, the
//! tooltip and the card of every item are drawn as well, their RGBA hashed against
//! testdata/itemdraw/golden-images.txt, and with -Dout written there as PNGs to look at.
//!
//! -Dupdate-golden rewrites both files; the diff is the review.

const std = @import("std");
const build_options = @import("build_options");
const item = @import("d2-item");
const save = @import("d2-save");
const itemdraw = @import("lib.zig");

const Character = struct { file: []const u8, bytes: []const u8, viewer: itemdraw.Viewer };

const testdata = @import("libd2-testdata");

/// The kit character's save, built from its spec the way `charkit build golden.kit --name ItemDraw
/// --seed 0x5eed` builds it (the build is deterministic), once per test run.
var golden_save: ?[]u8 = null;

fn goldenSave() ![]const u8 {
    if (golden_save) |s| return s;
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const spec = try save.charkit.parseSpec(arena.allocator(), testdata.golden_kit);
    var maker = try save.kititem.Maker.init(gpa, .expansion, 0x5eed);
    defer maker.deinit();
    golden_save = try save.charkit.compose(gpa, spec, "ItemDraw", .{}, save.charkit.kitSource(&maker));
    return golden_save.?;
}

fn chars() ![3]Character {
    return .{
        .{ .file = "EpicSorc", .bytes = testdata.epic_sorc, .viewer = .{ .class = 1, .level = 99, .strength = 88, .dexterity = 25 } },
        .{ .file = "EpicAma", .bytes = testdata.epic_ama, .viewer = .{ .class = 0, .level = 91, .strength = 28, .dexterity = 81 } },
        .{ .file = "golden", .bytes = try goldenSave(), .viewer = .{ .class = 3, .level = 90, .strength = 208, .dexterity = 80 } },
    };
}

test "the kit character builds to the same save every time" {
    const a = try goldenSave();
    try std.testing.expectEqual(@as(usize, 1675), a.len);
    try std.testing.expect(save.charkit.itemListFault((try save.parse(a)).items.bytes) == null);
}

const Group = struct { records: []const save.wire.Item, bytes: []const u8 };

fn groups(a: std.mem.Allocator, bytes: []const u8) ![]Group {
    const s = try save.parse(bytes);
    var flat: std.ArrayListUnmanaged(save.wire.Item) = .empty;
    var starts: std.ArrayListUnmanaged(usize) = .empty;
    var it = s.items.iterator();
    while (it.next()) |w| {
        try flat.append(a, w);
        try starts.append(a, it.pos - (w.bit_len + 7) / 8);
    }
    try starts.append(a, it.pos);
    var out: std.ArrayListUnmanaged(Group) = .empty;
    var i: usize = 0;
    while (i < flat.items.len) {
        const n = 1 + @min(flat.items[i].socketed_count, flat.items.len - i - 1);
        try out.append(a, .{ .records = flat.items[i .. i + n], .bytes = s.items.bytes[starts.items[i]..starts.items[i + n]] });
        i += n;
    }
    return out.items;
}

/// The viewer of a character, with its set pieces: every set item in the save owned, the equipped ones worn.
fn viewerOf(a: std.mem.Allocator, c: Character, gs: []const Group) !itemdraw.Viewer {
    var v = c.viewer;
    var owned: std.ArrayListUnmanaged(u16) = .empty;
    var worn: std.ArrayListUnmanaged(u16) = .empty;
    for (gs) |g| {
        const w = g.records[0];
        if (w.quality != .set or !w.identified()) continue;
        try owned.append(a, w.set_id);
        if (w.dest == save.wire.Mode.equipped) try worn.append(a, w.set_id);
    }
    v.set_items_owned = owned.items;
    v.set_items_worn = worn.items;
    return v;
}

/// One description as text: each line top to bottom, each colour run as `{N}text`.
fn render(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), d: itemdraw.Desc) !void {
    const ls = try item.itemdesc.lines(a, d);
    for (ls) |l| {
        try out.appendSlice(a, "  ");
        for (l.spans) |sp| try out.print(a, "{{{d}}}{s}", .{ sp.color, sp.text });
        try out.append(a, '\n');
    }
}

fn readFile(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 30));
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn compareOrUpdate(io: std.Io, a: std.mem.Allocator, name: []const u8, got: []const u8) !void {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ build_options.testdata, name });
    if (build_options.update_golden) return writeFile(io, path, got);
    const want = try readFile(io, a, path);
    if (!std.mem.eql(u8, want, got)) {
        // show the first differing line
        var wl = std.mem.splitScalar(u8, want, '\n');
        var gl = std.mem.splitScalar(u8, got, '\n');
        var n: usize = 1;
        while (true) : (n += 1) {
            const x = wl.next();
            const y = gl.next();
            if (x == null and y == null) break;
            if (x == null or y == null or !std.mem.eql(u8, x.?, y.?)) {
                std.debug.print("{s}:{d}\n  want: {s}\n  got:  {s}\n", .{ name, n, x orelse "(end)", y orelse "(end)" });
                break;
            }
        }
        return error.GoldenMismatch;
    }
}

test "every item of the golden characters describes as frozen, with and without its character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var t = try item.Tables.load(std.testing.allocator);
    defer t.deinit();
    var s = try item.strings.Strings.load(std.testing.allocator);
    defer s.deinit();
    var d = try item.itemdesc.Describer.init(std.testing.allocator, &t, &s);
    defer d.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (try chars()) |c| {
        const gs = try groups(a, c.bytes);
        const viewer = try viewerOf(a, c, gs);
        for (gs, 0..) |g, i| {
            const host = &g.records[0];
            try out.print(a, "== {s} {d:0>2} {s}\n", .{ c.file, i, host.codeSlice() });
            try render(a, &out, try d.describe(a, host, g.records[1..], .{}));
            try out.print(a, "-- as the {s}'s level {d} character\n", .{ c.file, viewer.level });
            try render(a, &out, try d.describe(a, host, g.records[1..], .{ .viewer = viewer }));
        }
    }
    try compareOrUpdate(io, a, "golden-text.txt", out.items);
}

test "every item of the golden characters draws as frozen (needs -Dd2dir)" {
    if (build_options.d2dir.len == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var assets = itemdraw.Assets.init(gpa);
    defer assets.deinit();
    for ([_][]const u8{ "Patch_D2.mpq", "d2exp.mpq", "d2data.mpq" }) |m| {
        const bytes = try readFile(io, a, try std.fmt.allocPrint(a, "{s}/{s}", .{ build_options.d2dir, m }));
        try assets.addArchive(bytes);
    }
    const drawer = try itemdraw.Drawer.init(gpa, &assets, .{});
    defer drawer.deinit();
    if (build_options.out.len != 0) std.Io.Dir.cwd().createDirPath(io, build_options.out) catch {};

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (try chars()) |c| {
        const gs = try groups(a, c.bytes);
        const viewer = try viewerOf(a, c, gs);
        for (gs, 0..) |g, i| {
            const opts = itemdraw.DescOptions{ .viewer = viewer };
            const desc = try drawer.describe(a, g.records, opts);
            var pics = [3]itemdraw.Image{
                try drawer.icon(g.records, .{ .background = .normal }),
                try drawer.tooltip(desc),
                try drawer.card(g.records, opts),
            };
            defer for (&pics) |*p| p.deinit(gpa);
            const kinds = [3][]const u8{ "icon", "tooltip", "card" };
            for (pics, kinds) |p, k| {
                var h: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(p.px, &h, .{});
                try out.print(a, "{s} {d:0>2} {s} {s} {d}x{d} {x}\n", .{ c.file, i, g.records[0].codeSlice(), k, p.w, p.h, h[0..8] });
                if (build_options.out.len != 0) {
                    const png = try itemdraw.png(gpa, &p);
                    defer gpa.free(png);
                    try writeFile(io, try std.fmt.allocPrint(a, "{s}/{s}-{d:0>2}-{s}-{s}.png", .{ build_options.out, c.file, i, g.records[0].codeSlice(), k }), png);
                }
            }
        }
    }
    try compareOrUpdate(io, a, "golden-images.txt", out.items);
}

/// Items the language bindings check themselves against: their records and the text the C ABI gives for
/// them (mode 2), neutral and seen by a level 80 sorceress with 100 strength and 50 dexterity. The text
/// itself is frozen by golden-text.txt; these files are generated (`zig build fixtures` writes them to
/// testdata/itemdraw/bindings/, which git ignores), and the Rust, Go, .NET and npm tests must reproduce
/// them byte for byte through their own binding. Their layouts are goldens, in testdata/itemdraw/layouts/.
const binding_items = [_]struct { char: usize, index: usize, name: []const u8 }{
    .{ .char = 1, .index = 8, .name = "thunderstroke" },
    .{ .char = 1, .index = 20, .name = "griffons-eye" },
    .{ .char = 1, .index = 41, .name = "call-to-arms" },
    .{ .char = 2, .index = 1, .name = "tal-rasha-guardianship" },
    .{ .char = 2, .index = 12, .name = "zod-rune" },
};

pub const binding_viewer = capi.D2ItemDrawOptions{ .has_viewer = 1, .class_id = 1, .level = 80, .strength = 100, .dexterity = 50 };

const capi = @import("capi.zig");

fn capiText(ctx: *capi.Ctx, a: std.mem.Allocator, bytes: []const u8, opts: ?*const capi.D2ItemDrawOptions) ![]const u8 {
    const n = capi.d2itemdraw_text(ctx, bytes.ptr, bytes.len, opts, 2, null, 0);
    if (n < 0) return error.TextFailed;
    const buf = try a.alloc(u8, @intCast(n));
    _ = capi.d2itemdraw_text(ctx, bytes.ptr, bytes.len, opts, 2, buf.ptr, buf.len);
    return buf;
}

test "the binding fixtures: records and the C ABI's text for them, written for the bindings' tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const ctx = capi.d2itemdraw_create() orelse return error.NoContext;
    defer capi.d2itemdraw_destroy(ctx);
    try std.Io.Dir.cwd().createDirPath(io, build_options.testdata ++ "/bindings");
    for (binding_items) |b| {
        const gs = try groups(a, (try chars())[b.char].bytes);
        const g = gs[b.index];
        const neutral = try capiText(ctx, a, g.bytes, null);
        const seen = try capiText(ctx, a, g.bytes, &binding_viewer);
        const base = try std.fmt.allocPrint(a, "{s}/bindings/{s}", .{ build_options.testdata, b.name });
        try writeFile(io, try std.fmt.allocPrint(a, "{s}.items", .{base}), g.bytes);
        try writeFile(io, try std.fmt.allocPrint(a, "{s}.txt", .{base}), neutral);
        try writeFile(io, try std.fmt.allocPrint(a, "{s}.viewer.txt", .{base}), seen);
    }
}

fn archiveDrawer(gpa: std.mem.Allocator, a: std.mem.Allocator, io: std.Io, assets: *itemdraw.Assets) !*itemdraw.Drawer {
    for ([_][]const u8{ "Patch_D2.mpq", "d2exp.mpq", "d2data.mpq" }) |m| {
        const bytes = try readFile(io, a, try std.fmt.allocPrint(a, "{s}/{s}", .{ build_options.d2dir, m }));
        try assets.addArchive(bytes);
    }
    return itemdraw.Drawer.init(gpa, assets, .{});
}

test "the display lists of the binding items as JSON, and their text from the same layout (needs -Dd2dir)" {
    if (build_options.d2dir.len == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var assets = itemdraw.Assets.init(gpa);
    defer assets.deinit();
    const drawer = try archiveDrawer(gpa, a, io, &assets);
    defer drawer.deinit();
    for (binding_items) |b| {
        const g = (try groups(a, (try chars())[b.char].bytes))[b.index];
        var l = try drawer.layoutCard(g.records, .{});
        defer l.deinit();
        const js = try l.json(gpa);
        defer gpa.free(js);
        try compareOrUpdate(io, a, try std.fmt.allocPrint(a, "layouts/{s}.json", .{b.name}), js);
        // the alt text is the layout's lines, the same as the description read top down
        const t = try l.text(gpa, 0);
        defer gpa.free(t);
        try std.testing.expectEqualStrings(try item.itemdesc.plain(a, try drawer.describe(a, g.records, .{})), t);
        const capped = try l.text(gpa, 1024);
        defer gpa.free(capped);
        try std.testing.expect(capped.len <= 1024);
    }
}

/// A provider that paints only the top-left `scale` x `scale` block of each glyph cell, in a colour made
/// from the glyph's code, and each sprite's whole rectangle magenta: enough to see every cell land where
/// the layout put it at any scale.
const BoxProvider = struct {
    fn glyphRgb(code: u21) [3]u8 {
        return .{ @truncate(code *% 37), 200, @truncate(code *% 11) };
    }
    fn glyph(_: *anyopaque, _: []const u8, g: *const itemdraw.layout.Glyph, _: [3]u8, scale: u32, t: itemdraw.Tile) bool {
        const c = glyphRgb(g.code);
        var y: u32 = 0;
        while (y < @min(scale, t.h)) : (y += 1) {
            var x: u32 = 0;
            while (x < @min(scale, t.w)) : (x += 1) {
                const o = (y * t.w + x) * 4;
                t.rgba[o] = c[0];
                t.rgba[o + 1] = c[1];
                t.rgba[o + 2] = c[2];
                t.rgba[o + 3] = 255;
            }
        }
        return true;
    }
    fn sprite(_: *anyopaque, _: *const itemdraw.layout.Sprite, _: u32, t: itemdraw.Tile) bool {
        var i: usize = 0;
        while (i < t.rgba.len) : (i += 4) {
            t.rgba[i] = 255;
            t.rgba[i + 1] = 0;
            t.rgba[i + 2] = 255;
            t.rgba[i + 3] = 255;
        }
        return true;
    }
};

test "custom providers draw into the same layout at scale 2 and 4 (needs -Dd2dir)" {
    if (build_options.d2dir.len == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var assets = itemdraw.Assets.init(gpa);
    defer assets.deinit();
    const drawer = try archiveDrawer(gpa, a, io, &assets);
    defer drawer.deinit();
    var dummy: u8 = 0;
    const custom = itemdraw.Providers{
        .glyph = .{ .ctx = &dummy, .draw = BoxProvider.glyph },
        .sprite = .{ .ctx = &dummy, .draw = BoxProvider.sprite },
    };
    const g = (try groups(a, (try chars())[1].bytes))[41]; // Call to Arms, with five runes
    var l = try drawer.layoutCard(g.records, .{});
    defer l.deinit();
    const before = try l.json(gpa);
    defer gpa.free(before);
    for ([_]u32{ 2, 4 }) |scale| {
        var img = try itemdraw.rasterize(gpa, &l, custom, .{}, scale);
        defer img.deinit(gpa);
        const s: i32 = @intCast(scale);
        try std.testing.expectEqual(@as(u32, @intCast(l.width * s)), img.w);
        try std.testing.expectEqual(@as(u32, @intCast(l.height * s)), img.h);
        var glyphs: usize = 0;
        for (l.lines) |line| for (line.spans) |sp| for (sp.glyphs) |gl| {
            const x: usize = @intCast(gl.rect.x * s);
            const y: usize = @intCast(gl.rect.y * s);
            const o = (y * img.w + x) * 4;
            const want = BoxProvider.glyphRgb(gl.code);
            try std.testing.expectEqualSlices(u8, &want, img.px[o..][0..3]);
            try std.testing.expectEqual(@as(u8, 255), img.px[o + 3]);
            glyphs += 1;
        };
        try std.testing.expect(glyphs > 100);
        // the icon's rectangle is magenta under the box's overlap, at the bottom row of the item
        const ic = l.icon.?;
        const bx: usize = @intCast((ic.rect.x + 1) * s);
        const by: usize = @intCast((ic.rect.y + ic.rect.h - 1) * s);
        const ob = (by * img.w + bx) * 4;
        try std.testing.expectEqual(@as(u8, 255), img.px[ob]);
        try std.testing.expectEqual(@as(u8, 0), img.px[ob + 1]);
        if (build_options.out.len != 0) {
            const png = try itemdraw.png(gpa, &img);
            defer gpa.free(png);
            try writeFile(io, try std.fmt.allocPrint(a, "{s}/custom-provider-x{d}.png", .{ build_options.out, scale }), png);
        }
    }
    // drawing does not touch the layout
    const after = try l.json(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
}

const CBox = struct {
    var glyphs: usize = 0;
    var pad: u32 = 0;
    fn glyph(_: ?*anyopaque, g: *const capi.D2ItemDrawGlyphRef, scale: u32, w: u32, h: u32, rgba: [*]u8) callconv(.c) i32 {
        if (w != @as(u32, @intCast(g.cell.w)) * scale + 2 * pad or h != @as(u32, @intCast(g.cell.h)) * scale + 2 * pad) return 0;
        glyphs += 1;
        @memset(rgba[0 .. w * h * 4], 255);
        return 1;
    }
};

test "the C ABI's layout, text and callback providers (needs -Dd2dir)" {
    if (build_options.d2dir.len == 0) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const ctx = capi.d2itemdraw_create() orelse return error.NoContext;
    defer capi.d2itemdraw_destroy(ctx);
    for ([_][]const u8{ "Patch_D2.mpq", "d2exp.mpq", "d2data.mpq" }) |m| {
        const bytes = try readFile(io, a, try std.fmt.allocPrint(a, "{s}/{s}", .{ build_options.d2dir, m }));
        try std.testing.expectEqual(@as(i32, 0), capi.d2itemdraw_add_archive(ctx, bytes.ptr, bytes.len));
    }
    const g = (try groups(a, (try chars())[1].bytes))[20];
    const l = capi.d2itemdraw_layout(ctx, g.bytes.ptr, g.bytes.len, null, capi.kind_card, 0, 0) orelse return error.NoLayout;
    defer capi.d2itemdraw_layout_free(l);
    var jl: usize = 0;
    const jp = capi.d2itemdraw_layout_json(l, &jl) orelse return error.NoJson;
    try std.testing.expectEqualStrings(try readFile(io, a, build_options.testdata ++ "/layouts/griffons-eye.json"), jp[0..jl]);
    var t1: [2048]u8 = undefined;
    var t2: [2048]u8 = undefined;
    const n1 = capi.d2itemdraw_layout_text(l, 0, &t1, t1.len);
    const n2 = capi.d2itemdraw_alt_text(ctx, g.bytes.ptr, g.bytes.len, null, 0, &t2, t2.len);
    try std.testing.expect(n1 > 0);
    try std.testing.expectEqualStrings(t1[0..@intCast(n1)], t2[0..@intCast(n2)]);
    // the default raster through the ABI is the card the drawer makes
    const img = capi.d2itemdraw_rasterize(ctx, l, null, 1) orelse return error.NoImage;
    defer capi.d2itemdraw_image_free(img);
    const card = capi.d2itemdraw_card(ctx, g.bytes.ptr, g.bytes.len, null) orelse return error.NoImage;
    defer capi.d2itemdraw_image_free(card);
    try std.testing.expectEqualSlices(u8, card.img.px, img.img.px);
    // a C glyph callback at scale 4, sprites left to libd2
    CBox.glyphs = 0;
    const prov = capi.D2ItemDrawProviders{ .glyph = CBox.glyph };
    const big = capi.d2itemdraw_rasterize(ctx, l, &prov, 4) orelse return error.NoImage;
    defer capi.d2itemdraw_image_free(big);
    try std.testing.expectEqual(@as(u32, @intCast(capi.d2itemdraw_layout_width(l) * 4)), capi.d2itemdraw_image_width(big));
    try std.testing.expect(CBox.glyphs > 100);
}

test "a padded glyph provider gets the cell plus its pad on every side (needs -Dd2dir)" {
    if (build_options.d2dir.len == 0) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const ctx = capi.d2itemdraw_create() orelse return error.NoContext;
    defer capi.d2itemdraw_destroy(ctx);
    for ([_][]const u8{ "Patch_D2.mpq", "d2exp.mpq", "d2data.mpq" }) |m| {
        const bytes = try readFile(io, a, try std.fmt.allocPrint(a, "{s}/{s}", .{ build_options.d2dir, m }));
        _ = capi.d2itemdraw_add_archive(ctx, bytes.ptr, bytes.len);
    }
    const g = (try groups(a, (try chars())[1].bytes))[8];
    const l = capi.d2itemdraw_layout(ctx, g.bytes.ptr, g.bytes.len, null, capi.kind_tooltip, 0, 0) orelse return error.NoLayout;
    defer capi.d2itemdraw_layout_free(l);
    CBox.glyphs = 0;
    CBox.pad = 3;
    defer CBox.pad = 0;
    const prov = capi.D2ItemDrawProviders{ .glyph = CBox.glyph, .glyph_pad = 3 };
    const img = capi.d2itemdraw_rasterize(ctx, l, &prov, 2) orelse return error.NoImage;
    defer capi.d2itemdraw_image_free(img);
    try std.testing.expect(CBox.glyphs > 100);
}
