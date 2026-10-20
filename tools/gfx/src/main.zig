//! `gfx`: draw a scene's views on the CPU (d2-gfx) and compare frames of a view block by block.
//!
//!   gfx stats   SCENE                                   the scene's draws by pass and its DT1s
//!   gfx view    SCENE --views X,Y[;X,Y..] --out DIR     view-X_Y.png per view
//!               [--gamma G,C | --gamma off] [--texels argb1555|rgba8] [--rect on|off]
//!               [--smooth on|off] [--margin N]
//!   gfx compare A.png B.png [--out SIDE.png] [--max-mean F] [--min-ssim F]
//!                                                      the 64 x 64 block gate; exit 1 when it fails
//!   gfx levels  FILE.png                                how many distinct values each channel takes
//!
//! Exit 0 on success, 1 when the work failed (or the comparison did), 2 on a usage error.
const std = @import("std");
const gfx = @import("d2-gfx");
const png = @import("d2-util").png;

const Dir = std.Io.Dir;

const usage =
    \\gfx stats SCENE
    \\gfx view SCENE --views X,Y[;X,Y..] --out DIR [--gamma G,C|off] [--texels argb1555|rgba8] [--rect on|off] [--smooth on|off] [--margin N]
    \\gfx compare A.png B.png [--out SIDE.png] [--max-mean F] [--min-ssim F]
    \\gfx levels FILE.png
    \\
;

const Args = struct {
    pos: std.ArrayListUnmanaged([]const u8) = .empty,
    opts: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn parse(gpa: std.mem.Allocator, argv: []const [:0]const u8) !Args {
        var a: Args = .{};
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const s: []const u8 = argv[i];
            if (std.mem.startsWith(u8, s, "--")) {
                if (i + 1 >= argv.len) return error.Usage;
                try a.opts.put(gpa, s[2..], argv[i + 1]);
                i += 1;
            } else try a.pos.append(gpa, s);
        }
        return a;
    }

    fn get(a: *const Args, k: []const u8) ?[]const u8 {
        return a.opts.get(k);
    }

    fn onOff(a: *const Args, k: []const u8, default: bool) !bool {
        const v = a.get(k) orelse return default;
        if (std.mem.eql(u8, v, "on")) return true;
        if (std.mem.eql(u8, v, "off")) return false;
        return error.Usage;
    }
};

pub fn main(init: std.process.Init) u8 {
    const gpa = init.arena.allocator();
    const argv = init.minimal.args.toSlice(gpa) catch return 1;
    if (argv.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const args = Args.parse(gpa, argv[2..]) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const r = run(gpa, init.io, argv[1], &args) catch |e| switch (e) {
        error.Usage => {
            std.debug.print("{s}", .{usage});
            return 2;
        },
        else => {
            std.debug.print("gfx: {s}\n", .{@errorName(e)});
            return 1;
        },
    };
    return r;
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try Dir.cwd().createDirPath(io, d);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn run(gpa: std.mem.Allocator, io: std.Io, cmd: []const u8, a: *const Args) !u8 {
    if (std.mem.eql(u8, cmd, "stats")) return stats(gpa, io, a);
    if (std.mem.eql(u8, cmd, "view")) return view(gpa, io, a);
    if (std.mem.eql(u8, cmd, "compare")) return compare(gpa, io, a);
    if (std.mem.eql(u8, cmd, "levels")) return levels(gpa, io, a);
    return error.Usage;
}

fn stats(gpa: std.mem.Allocator, io: std.Io, a: *const Args) !u8 {
    if (a.pos.items.len != 1) return error.Usage;
    const bytes = try readFile(gpa, io, a.pos.items[0]);
    var s = try gfx.scene.parse(gpa, bytes);
    var n = [_]usize{0} ** 5;
    for (s.draws) |d| n[@intFromEnum(d.pass)] += 1;
    std.debug.print("draws: under {d}, floor {d}, shadow {d}, wall {d}, roof {d}; units {d}; light {d}x{d} at {d},{d}\n", .{ n[4], n[0], n[1], n[2], n[3], s.units.len, s.light.w, s.light.h, s.light.x0, s.light.y0 });
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (s.light.cells) |c| {
        lo = @min(lo, c.i);
        hi = @max(hi, c.i);
    }
    std.debug.print("light intensity {d}..{d}; level {d}\n", .{ lo, hi, s.world.level });
    for (s.files, 0..) |f, k| {
        const act = gfx.tilepal.originAct(f.name, &gfx.tilepal.stock_folders);
        if (act) |v| std.debug.print("  {d:>3} act {d} {s}\n", .{ k, v + 1, f.name }) else std.debug.print("  {d:>3} -     {s}\n", .{ k, f.name });
    }
    s.deinit(gpa);
    return 0;
}

fn parseView(v: []const u8) ![2]i32 {
    var it = std.mem.splitScalar(u8, v, ',');
    const x = try std.fmt.parseInt(i32, it.next() orelse return error.Usage, 10);
    const y = try std.fmt.parseInt(i32, it.next() orelse return error.Usage, 10);
    return .{ x, y };
}

fn view(gpa: std.mem.Allocator, io: std.Io, a: *const Args) !u8 {
    if (a.pos.items.len != 1) return error.Usage;
    const views = a.get("views") orelse return error.Usage;
    const out = a.get("out") orelse return error.Usage;
    var opts: gfx.view.Options = .{};
    opts.smooth = try a.onOff("smooth", true);
    opts.rect_textures = try a.onOff("rect", true);
    if (a.get("texels")) |t| opts.texels = std.meta.stringToEnum(gfx.view.TexelFormat, t) orelse return error.Usage;
    if (a.get("margin")) |m| opts.bottom_margin = try std.fmt.parseInt(i32, m, 10);
    // the host's palette data: DIR/palN.dat (pal.dat as shipped, B, G, R) for the acts it has
    if (a.get("act-palettes")) |dir| {
        for (0..gfx.tilepal.acts) |k| {
            const p = try std.fmt.allocPrint(gpa, "{s}/pal{d}.dat", .{ dir, k + 1 });
            const pal = readFile(gpa, io, p) catch continue;
            if (pal.len < 768) return error.ShortPalette;
            var ramp: [gfx.tilepal.count][3]u8 = undefined;
            for (0..gfx.tilepal.count) |i| {
                const e = pal[(gfx.tilepal.first + i) * 3 ..][0..3];
                ramp[i] = .{ e[2], e[1], e[0] };
            }
            opts.ramps[k] = ramp;
        }
    }
    // a mod's tile folder: NAME=ACT (1-based), e.g. act6=3
    if (a.get("folder")) |f| {
        const eq = std.mem.indexOfScalar(u8, f, '=') orelse return error.Usage;
        const act = try std.fmt.parseInt(u8, f[eq + 1 ..], 10);
        if (act < 1 or act > gfx.tilepal.acts) return error.Usage;
        const list = try gpa.alloc(gfx.tilepal.Folder, gfx.tilepal.stock_folders.len + 1);
        @memcpy(list[0..gfx.tilepal.stock_folders.len], &gfx.tilepal.stock_folders);
        list[list.len - 1] = .{ .name = try std.ascii.allocLowerString(gpa, f[0..eq]), .act = act - 1 };
        opts.folders = list;
    }
    var lut: ?[256]u8 = gfx.gamma.table(155, 49);
    if (a.get("gamma")) |g| {
        if (std.mem.eql(u8, g, "off")) lut = null else {
            const gc = try parseView(g);
            lut = gfx.gamma.table(gc[0], gc[1]);
        }
    }

    const bytes = try readFile(gpa, io, a.pos.items[0]);
    var s = try gfx.scene.parse(gpa, bytes);
    defer s.deinit(gpa);
    var r = try gfx.view.Renderer.init(gpa, &s, opts);
    defer r.deinit();
    var tg = try gfx.raster.Target.init(gpa, opts.w, opts.h);
    defer tg.deinit(gpa);
    var it = std.mem.splitScalar(u8, views, ';');
    while (it.next()) |v| {
        if (v.len == 0) continue;
        const xy = try parseView(v);
        try r.frame(&tg, xy[0], xy[1]);
        if (lut) |*t| gfx.gamma.apply(tg.px, t);
        const enc = try png.encodeRgbaDeflate(gpa, tg.px, tg.w, tg.h);
        defer gpa.free(enc);
        const name = try std.fmt.allocPrint(gpa, "{s}/view-{d}_{d}.png", .{ out, xy[0], xy[1] });
        try writeFile(io, name, enc);
        std.debug.print("{s} {d}x{d}\n", .{ name, tg.w, tg.h });
    }
    return 0;
}

fn compare(gpa: std.mem.Allocator, io: std.Io, a: *const Args) !u8 {
    if (a.pos.items.len != 2) return error.Usage;
    const ia = try png.decodeRgba(gpa, try readFile(gpa, io, a.pos.items[0]));
    const ib = try png.decodeRgba(gpa, try readFile(gpa, io, a.pos.items[1]));
    if (ia.w != ib.w or ia.h != ib.h) {
        std.debug.print("gfx: the frames differ in size ({d}x{d}, {d}x{d})\n", .{ ia.w, ia.h, ib.w, ib.h });
        return 1;
    }
    var lim: gfx.compare.Limits = .{};
    if (a.get("max-mean")) |v| lim.max_mean = try std.fmt.parseFloat(f64, v);
    if (a.get("min-ssim")) |v| lim.min_ssim = try std.fmt.parseFloat(f64, v);
    var rep = try gfx.compare.compare(gpa, ia.px, ib.px, ia.w, ia.h, null, lim);
    defer rep.deinit(gpa);
    var far: u64 = 0;
    for (rep.blocks) |bl| far += bl.far;
    std.debug.print("{s}: {d} blocks judged, {d} failed; mean {d:.3}, worst block mean {d:.3}, worst SSIM {d:.4}; {d} pixels off by more than 8\n", .{ if (rep.pass()) "pass" else "FAIL", rep.judged, rep.failed, rep.mean, rep.worst_mean, rep.worst_ssim, far });
    for (rep.blocks) |bl| if (!bl.pass) std.debug.print("  block {d},{d}: mean {d:.3} SSIM {d:.4} far {d}\n", .{ bl.x, bl.y, bl.mean, bl.ssim, bl.far });
    if (a.get("out")) |o| {
        const side = try gfx.compare.sideBySide(gpa, ia.px, ib.px, ia.w, ia.h, &rep);
        try writeFile(io, o, try png.encodeRgbaDeflate(gpa, side, ia.w * 3, ia.h));
    }
    return if (rep.pass()) 0 else 1;
}

fn levels(gpa: std.mem.Allocator, io: std.Io, a: *const Args) !u8 {
    if (a.pos.items.len != 1) return error.Usage;
    const im = try png.decodeRgba(gpa, try readFile(gpa, io, a.pos.items[0]));
    var seen = [_][256]bool{[_]bool{false} ** 256} ** 3;
    for (0..@as(usize, im.w) * im.h) |i| for (0..3) |k| {
        seen[k][im.px[i * 4 + k]] = true;
    };
    for (0..3) |k| {
        var n: usize = 0;
        var on5: usize = 0;
        for (seen[k], 0..) |s, v| if (s) {
            n += 1;
            // a value a 5-bit channel expands to
            const q = (v * 31 + 127) / 255;
            if ((q * 255 + 15) / 31 == v) on5 += 1;
        };
        std.debug.print("channel {d}: {d} values, {d} of them 5-bit levels\n", .{ k, n, on5 });
    }
    return 0;
}
