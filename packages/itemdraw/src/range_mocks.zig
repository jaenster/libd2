//! range-mocks: item tooltips with the range each stat rolls in, in the looks to choose from.
//!
//!   range-mocks --mpq Patch_D2.mpq --mpq d2exp.mpq --mpq d2data.mpq --out DIR
//!
//! For each item of the list below and each look (none, grey, dark blue, rolled): `NN-name-LOOK-1x.png` and `-2x.png`,
//! the tooltip on the dark ground it sits on in the game, and `overview.png` with every item in a row and the looks side
//! by side. The items are made by the character kit (d2-save kititem), their values rolled as a drop rolls them.
const std = @import("std");
const itemdraw = @import("d2-itemdraw");
const save = @import("d2-save");
const ranges = itemdraw.itemdesc.range;

const Look = struct { name: []const u8, title: []const u8, style: ranges.Style };
const looks = [_]Look{
    .{ .name = "none", .title = "As now", .style = .off },
    .{ .name = "A-grey", .title = "A: grey, every stat", .style = .grey },
    .{ .name = "B-darkblue", .title = "B: dark blue, every stat", .style = .dark_blue },
    .{ .name = "C-rolled", .title = "C: rolled stats only, gold = perfect", .style = .rolled },
};

const Mock = struct {
    file: []const u8,
    kit: []const u8,
    scope: save.kititem.Scope = .expansion,
    seed: u32 = 7,
    /// a Classic rare rolled the 1.06 way: item version 0, values min..max-1, the name purple
    prepatch: bool = false,
};

const mocks = [_]Mock{
    .{ .file = "stone-of-jordan", .kit = "unique:The Stone of Jordan;nomax", .seed = 11 },
    .{ .file = "harlequin-crest", .kit = "unique:Harlequin Crest;nomax", .seed = 5 },
    .{ .file = "rare-amulet", .kit = "rare:amu;prefix=Summoner's,Prismatic,Great Wyrm's;suffix=of Perfection,of the Apprentice;nomax", .seed = 2 },
    .{ .file = "tal-rasha-armor", .kit = "set:Tal Rasha's Howling Wind;nomax", .seed = 3 },
    .{ .file = "spirit-sword", .kit = "base:crs;runeword=Spirit;nomax", .seed = 9 },
    .{ .file = "classic-azurewrath", .kit = "unique:Azurewrath;nomax", .scope = .classic, .seed = 4 },
    .{ .file = "prepatch-rare-ring", .kit = "rare:rin;prefix=Ruby,Meteoric;suffix=of Precision,of the Apprentice;nomax", .scope = .classic, .seed = 6, .prepatch = true },
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

/// Colour 12 stands for the darker blue of look B: drawn as the stat lines' blue at 70 %.
const DarkBlue = struct {
    drawer: *itemdraw.Drawer,
    fn draw(ctx: *anyopaque, font: []const u8, g: *const itemdraw.layout.Glyph, rgb: [3]u8, scale: u32, t: itemdraw.Tile) bool {
        const self: *DarkBlue = @ptrCast(@alignCast(ctx));
        if (g.color != 12) return false;
        var blue = g.*;
        blue.color = 3;
        const p = self.drawer.defaults().glyph.?;
        if (!p.draw(p.ctx, font, &blue, rgb, scale, t)) return false;
        var i: usize = 0;
        while (i + 3 < t.rgba.len) : (i += 4) {
            for (0..3) |c| t.rgba[i + c] = @intCast(@as(u32, t.rgba[i + c]) * 70 / 100);
        }
        return true;
    }
};

const ground = [3]u8{ 18, 16, 14 };

/// The tooltip on the ground, with a margin.
fn onGround(gpa: std.mem.Allocator, img: *const itemdraw.Image, margin: u32) !itemdraw.Image {
    var out = try itemdraw.Image.init(gpa, img.w + 2 * margin, img.h + 2 * margin);
    var i: usize = 0;
    while (i < out.px.len) : (i += 4) {
        out.px[i] = ground[0];
        out.px[i + 1] = ground[1];
        out.px[i + 2] = ground[2];
        out.px[i + 3] = 255;
    }
    blitOver(&out, img, margin, margin);
    return out;
}

fn blitOver(dst: *itemdraw.Image, src: *const itemdraw.Image, x0: u32, y0: u32) void {
    var y: u32 = 0;
    while (y < src.h) : (y += 1) {
        if (y0 + y >= dst.h) break;
        var x: u32 = 0;
        while (x < src.w) : (x += 1) {
            if (x0 + x >= dst.w) break;
            const s = (y * src.w + x) * 4;
            const d = ((y0 + y) * dst.w + x0 + x) * 4;
            const a: u32 = src.px[s + 3];
            for (0..3) |c| dst.px[d + c] = @intCast((@as(u32, src.px[s + c]) * a + @as(u32, dst.px[d + c]) * (255 - a)) / 255);
            dst.px[d + 3] = 255;
        }
    }
}

fn countAffixes(w: *const save.wire.Item) usize {
    var n: usize = 0;
    for (w.rare_prefixes) |p| n += @intFromBool(p != 0);
    for (w.rare_suffixes) |s| n += @intFromBool(s != 0);
    return n;
}

/// The name block's colour (the last code of the string, the top line) as purple, as d2up draws a pre-patch rare's.
fn purpleName(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const cc = itemdraw.itemdesc.color_code;
    const at = std.mem.lastIndexOf(u8, text, cc) orelse return text;
    const out = try a.dupe(u8, text);
    out[at + cc.len] = ';'; // colour 11
    return out;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    var mpqs: std.ArrayListUnmanaged([]const u8) = .empty;
    var out_dir: []const u8 = ".";
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--mpq")) {
            try mpqs.append(gpa, args.next() orelse fatal("--mpq needs a path", .{}));
        } else if (std.mem.eql(u8, a, "--out")) {
            out_dir = args.next() orelse fatal("--out needs a directory", .{});
        } else fatal("unknown argument {s}", .{a});
    }
    var assets = itemdraw.Assets.init(gpa);
    defer assets.deinit();
    for (mpqs.items) |m| {
        const b = std.Io.Dir.cwd().readFileAlloc(io, m, gpa, .limited(1 << 30)) catch fatal("cannot read {s}", .{m});
        assets.addArchive(b) catch fatal("{s} is not an MPQ", .{m});
    }
    const drawer = itemdraw.Drawer.init(gpa, &assets, .{ .act = 1 }) catch |e| fatal("cannot load the art: {s}", .{@errorName(e)});
    defer drawer.deinit();
    var dark = DarkBlue{ .drawer = drawer };
    const primary = itemdraw.Providers{ .glyph = .{ .ctx = &dark, .draw = DarkBlue.draw } };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    std.Io.Dir.cwd().createDirPath(io, out_dir) catch {};

    // every tooltip at 2x, kept for the overview: [mock][look]
    var cells: [mocks.len][looks.len]itemdraw.Image = undefined;
    var listing: std.ArrayListUnmanaged(u8) = .empty;

    for (mocks, 0..) |m, mi| {
        var seed = m.seed;
        var made: save.kititem.Made = undefined;
        var recs: []save.wire.Item = undefined;
        while (true) : (seed += 1) {
            var maker = try save.kititem.Maker.init(gpa, m.scope, seed);
            defer maker.deinit();
            if (m.prepatch) maker.version = 0;
            made = maker.makeKit(m.kit) catch |e| fatal("{s}: {s}", .{ m.kit, @errorName(e) });
            recs = try itemdraw.parseRecords(a, made.rec, 16);
            const wanted = std.mem.startsWith(u8, m.kit, "rare:");
            if (!wanted) break;
            const n = countAffixes(&recs[0]);
            if (n >= 4 and n <= 5) break;
            made.deinit(gpa);
        }
        defer made.deinit(gpa);
        if (m.prepatch) clampPrepatch(drawer, a, recs);

        for (looks, 0..) |lk, li| {
            var desc = try drawer.describe(a, recs, .{ .ranges = lk.style });
            if (m.prepatch) desc.text = try purpleName(a, desc.text);
            if (li == 0 or li == 1) {
                try listing.print(a, "== {s} ({s}) [{s}]\n{s}\n\n", .{ m.file, m.kit, lk.name, try itemdraw.itemdesc.plain(a, desc) });
            }
            var l = try drawer.layoutTooltip(desc);
            defer l.deinit();
            for ([_]u32{ 1, 2 }) |scale| {
                var img = try itemdraw.rasterize(gpa, &l, primary, drawer.defaults(), scale);
                defer img.deinit(gpa);
                var g = try onGround(gpa, &img, 8 * scale);
                const png = try itemdraw.png(gpa, &g);
                defer gpa.free(png);
                const name = try std.fmt.allocPrint(a, "{s}/{d:0>2}-{s}-{s}-{d}x.png", .{ out_dir, mi + 1, m.file, lk.name, scale });
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = png });
                if (scale == 2) cells[mi][li] = g else g.deinit(gpa);
            }
        }
    }

    // the overview: a title row, then one row per item, the looks left to right
    var col_w = [_]u32{0} ** looks.len;
    var row_h = [_]u32{0} ** mocks.len;
    for (0..mocks.len) |mi| for (0..looks.len) |li| {
        col_w[li] = @max(col_w[li], cells[mi][li].w);
        row_h[mi] = @max(row_h[mi], cells[mi][li].h);
    };
    var titles: [looks.len]itemdraw.Image = undefined;
    var title_h: u32 = 0;
    for (looks, 0..) |lk, li| {
        const t = try std.fmt.allocPrint(a, "\xc3\xbfc4{s}", .{lk.title});
        var l = try drawer.layoutTooltip(.{ .text = t });
        defer l.deinit();
        var img = try itemdraw.rasterize(gpa, &l, primary, drawer.defaults(), 2);
        defer img.deinit(gpa);
        titles[li] = try onGround(gpa, &img, 16);
        title_h = @max(title_h, titles[li].h);
        col_w[li] = @max(col_w[li], titles[li].w);
    }
    var total_w: u32 = 0;
    for (col_w) |w| total_w += w;
    var total_h: u32 = title_h;
    for (row_h) |h| total_h += h;
    var ov = try itemdraw.Image.init(gpa, total_w, total_h);
    defer ov.deinit(gpa);
    var i: usize = 0;
    while (i < ov.px.len) : (i += 4) {
        ov.px[i] = ground[0];
        ov.px[i + 1] = ground[1];
        ov.px[i + 2] = ground[2];
        ov.px[i + 3] = 255;
    }
    var x: u32 = 0;
    for (0..looks.len) |li| {
        blitOver(&ov, &titles[li], x + (col_w[li] - titles[li].w) / 2, 0);
        titles[li].deinit(gpa);
        var y: u32 = title_h;
        for (0..mocks.len) |mi| {
            const c = &cells[mi][li];
            blitOver(&ov, c, x + (col_w[li] - c.w) / 2, y);
            y += row_h[mi];
            c.deinit(gpa);
        }
        x += col_w[li];
    }
    const png = try itemdraw.png(gpa, &ov);
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/overview.png", .{out_dir}), .data = png });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/items.txt", .{out_dir}), .data = listing.items });
    std.debug.print("wrote {d} items x {d} looks into {s}\n", .{ mocks.len, looks.len, out_dir });
}

/// The kit rolls a Classic rare as the expansion rolls it, top of the range included; a pre-patch rare never reached
/// the top, so a value at the top is taken one down, as 1.06 could have rolled it.
fn clampPrepatch(drawer: *itemdraw.Drawer, a: std.mem.Allocator, recs: []save.wire.Item) void {
    const r = drawer.describer.rangesFor(a, &recs[0], recs[1..]) catch return;
    const h = &recs[0];
    for (h.stats[0..h.n_stats]) |*st| {
        if (st.list != 0) continue;
        const rg = r.get(st.id, @truncate(st.param)) orelse continue;
        if (st.value > rg.hi) st.value = rg.hi;
    }
}
