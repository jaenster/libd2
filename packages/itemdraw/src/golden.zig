//! Golden tests over real items: the two engine-played saves (EpicSorc, EpicAma) and a kit character
//! (src/testdata/golden.kit, built with `charkit build golden.kit golden.d2s --name ItemDraw --seed 0x5eed`)
//! that adds set pieces worn and carried, a paladin shield, an ethereal runeword with charges, gemmed
//! and socketed white items, loose runes, gems and jewels, a tome, a key and the cube.
//!
//! The text of every item is compared, top to bottom with its colours, with and without a viewer,
//! against src/testdata/golden-text.txt; that needs no art. With -Dd2dir (the 1.14d MPQs) the icon, the
//! tooltip and the card of every item are drawn as well, their RGBA hashed against
//! src/testdata/golden-images.txt, and with -Dout written there as PNGs to look at.
//!
//! -Dupdate-golden rewrites both files; the diff is the review.

const std = @import("std");
const build_options = @import("build_options");
const item = @import("d2-item");
const save = @import("d2-save");
const itemdraw = @import("lib.zig");

const Character = struct { file: []const u8, bytes: []const u8, viewer: itemdraw.Viewer };

const characters = [_]Character{
    .{ .file = "EpicSorc", .bytes = @embedFile("testdata/EpicSorc.d2s"), .viewer = .{ .class = 1, .level = 99, .strength = 88, .dexterity = 25 } },
    .{ .file = "EpicAma", .bytes = @embedFile("testdata/EpicAma.d2s"), .viewer = .{ .class = 0, .level = 91, .strength = 28, .dexterity = 81 } },
    .{ .file = "golden", .bytes = @embedFile("testdata/golden.d2s"), .viewer = .{ .class = 3, .level = 90, .strength = 208, .dexterity = 80 } },
};

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
    for (characters) |c| {
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
    for (characters) |c| {
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
                    const png = try p.png(gpa);
                    defer gpa.free(png);
                    try writeFile(io, try std.fmt.allocPrint(a, "{s}/{s}-{d:0>2}-{s}-{s}.png", .{ build_options.out, c.file, i, g.records[0].codeSlice(), k }), png);
                }
            }
        }
    }
    try compareOrUpdate(io, a, "golden-images.txt", out.items);
}

/// Items the language bindings check themselves against: their records and the text the C ABI gives for
/// them (mode 2), neutral and seen by a level 80 sorceress with 100 strength and 50 dexterity. The Go
/// and .NET tests carry copies of src/testdata/bindings/ and must reproduce these files byte for byte.
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

test "the binding fixtures: records and the C ABI's text for them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const ctx = capi.d2itemdraw_create() orelse return error.NoContext;
    defer capi.d2itemdraw_destroy(ctx);
    if (build_options.update_golden) std.Io.Dir.cwd().createDirPath(io, build_options.testdata ++ "/bindings") catch {};
    for (binding_items) |b| {
        const gs = try groups(a, characters[b.char].bytes);
        const g = gs[b.index];
        const neutral = try capiText(ctx, a, g.bytes, null);
        const seen = try capiText(ctx, a, g.bytes, &binding_viewer);
        const base = try std.fmt.allocPrint(a, "bindings/{s}", .{b.name});
        if (build_options.update_golden) {
            try writeFile(io, try std.fmt.allocPrint(a, "{s}/{s}.items", .{ build_options.testdata, base }), g.bytes);
        } else {
            const want = try readFile(io, a, try std.fmt.allocPrint(a, "{s}/{s}.items", .{ build_options.testdata, base }));
            try std.testing.expectEqualSlices(u8, want, g.bytes);
        }
        try compareOrUpdate(io, a, try std.fmt.allocPrint(a, "{s}.txt", .{base}), neutral);
        try compareOrUpdate(io, a, try std.fmt.allocPrint(a, "{s}.viewer.txt", .{base}), seen);
    }
}
