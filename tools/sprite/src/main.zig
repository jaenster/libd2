//! `sprite` — DC6, DCC and COF art out of Diablo II's archives and back in, from a script.
//!
//! Every command is non-interactive, writes data to stdout and diagnostics to stderr, and exits
//! 0 on success, 1 when the work failed (a file would not decode, a round trip differed) and 2 on
//! a usage error. Output bytes depend only on the input and the options: names are sorted, PNGs
//! use fixed filtering and compression, and JSON keys come out in a fixed order.

const std = @import("std");
const formats = @import("d2-formats");
const source = @import("source.zig");
const sprite = @import("sprite.zig");
const pngx = @import("d2-util").png;
const scale_mod = @import("scale.zig");
const compose_mod = @import("compose.zig");
const pack_mod = @import("pack.zig");

const Source = source.Source;
const Dir = std.Io.Dir;

pub const usage =
    \\sprite — DC6/DCC/COF from Diablo II archives, headless
    \\
    \\  sprite list    [--match GLOB] [--json]                 names the archives' listfiles know
    \\  sprite info    NAME [--json]                           dirs, frames, boxes and frame hashes
    \\  sprite extract NAME --out FILE                         the member's raw bytes
    \\  sprite render  NAME --out FILE.png [--dir N] [--frame N | --all] [--scale K] [--filter mmpx|nearest]
    \\                 [--palette P] [--shift SPEC] [--indexed]
    \\  sprite compose --token TK --mode MD --wclass WC --out FILE.png [--class chars|monsters|objects]
    \\                 [--var COMP=VAR]... [--layer-shift COMP=SPEC]... [--dir N] [--frame N | --all]
    \\                 [--scale K] [--filter F] [--palette P] [--indexed] [--json]
    \\  sprite unpack  NAME --out DIR [--scale K] [--filter F] [--palette P] [--by-hash]
    \\  sprite pack    DIR --out FILE.dc6|.dcc|.cof            back from sprite.json/cof.json + indexed PNGs
    \\  sprite upscale NAME --scale K --out FILE.dc6|.dcc|.png [--filter F] [--palette P]
    \\  sprite batch   --match GLOB --out DIR [--scale K] [--filter F] [--palette P] [--rgba] [--by-hash]
    \\                 [--manifest FILE]
    \\  sprite verify  [--match GLOB] [--json]                 decode/encode round trip of every match
    \\
    \\Sources (every command):
    \\  --mpq PATH       an archive, repeatable; searched in the order given. Default: patch_d2,
    \\                   d2exp, d2data, d2char from $D2_DIR, else the current folder
    \\  --listfile PATH  extra member names, one per line (archives' own (listfile)s are read too)
    \\  NAME             an archive member (case and / vs \ do not matter) or a file on disk
    \\
    \\Palettes: act1..act5, a palette directory name (units, fechar, sky, ...), or a pal.dat path.
    \\Shifts:   pl2:TABLE:N  a transform from the palette's pal.pl2 (light, inv_colour, selected,
    \\                       hue, red, green, blue, darkened, ...)
    \\          map:NAME:N   the Nth 256-byte table of a colour map (e.g. an items/palette/*.dat,
    \\                       a monster's cof/palshift.dat)
    \\
    \\Scaling: --filter mmpx (default) or nearest; --edge zero (default: outside a frame is a hole)
    \\         or clamp (repeat the border, for tiled UI blocks). 3x is MMPX 4x point-sampled.
    \\Indexed PNGs carry the palette in PLTE with index 0 transparent; the pixels are the indices.
    \\Exit: 0 ok, 1 failed, 2 usage.
    \\
;

pub const UsageError = error{Usage};

/// Parsed command line: positionals, `--key value` options (repeatable) and bare flags.
pub const Args = struct {
    pos: std.ArrayListUnmanaged([]const u8) = .empty,
    opts: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,
    flags: std.StringArrayHashMapUnmanaged(void) = .empty,

    const bare = [_][]const u8{ "json", "indexed", "rgba", "all", "by-hash" };

    pub fn parse(gpa: std.mem.Allocator, argv: []const []const u8) !Args {
        var a: Args = .{};
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const s = argv[i];
            if (!std.mem.startsWith(u8, s, "--")) {
                try a.pos.append(gpa, s);
                continue;
            }
            const key = s[2..];
            if (isBare(key)) {
                try a.flags.put(gpa, key, {});
                continue;
            }
            if (i + 1 >= argv.len) return fail("--{s} needs a value", .{key});
            i += 1;
            const gop = try a.opts.getOrPut(gpa, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(gpa, argv[i]);
        }
        return a;
    }

    fn isBare(key: []const u8) bool {
        for (bare) |b| if (std.mem.eql(u8, b, key)) return true;
        return false;
    }

    pub fn flag(a: *const Args, key: []const u8) bool {
        return a.flags.contains(key);
    }

    pub fn get(a: *const Args, key: []const u8) ?[]const u8 {
        const l = a.opts.get(key) orelse return null;
        return l.items[l.items.len - 1];
    }

    pub fn all(a: *const Args, key: []const u8) []const []const u8 {
        const l = a.opts.getPtr(key) orelse return &.{};
        return l.items;
    }

    pub fn int(a: *const Args, key: []const u8, default: u32) !u32 {
        const v = a.get(key) orelse return default;
        return std.fmt.parseInt(u32, v, 10) catch fail("--{s} wants a non-negative integer, got '{s}'", .{ key, v });
    }

    pub fn need(a: *const Args, key: []const u8) ![]const u8 {
        return a.get(key) orelse fail("--{s} is required", .{key});
    }

    pub fn arg(a: *const Args, i: usize, what: []const u8) ![]const u8 {
        if (i >= a.pos.items.len) return fail("missing {s}", .{what});
        return a.pos.items[i];
    }
};

pub fn fail(comptime fmt: []const u8, args: anytype) UsageError {
    std.debug.print("sprite: " ++ fmt ++ "\n", args);
    return error.Usage;
}

/// What every command shares: the allocator, I/O, the archives and the chosen palette.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    args: Args,
    env: *const std.process.Environ.Map,
    src: ?Source = null,

    pub fn source_(c: *Ctx) !*Source {
        if (c.src == null) {
            var paths = c.args.all("mpq");
            if (paths.len == 0) {
                const dir = c.env.get("D2_DIR") orelse ".";
                paths = try source.defaultArchives(c.gpa, c.io, dir);
            }
            c.src = try Source.open(c.gpa, c.io, paths, c.args.all("listfile"));
        }
        return &c.src.?;
    }

    pub fn out(c: *Ctx, bytes: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(c.io, bytes);
    }

    pub fn writeFile(c: *Ctx, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try Dir.cwd().createDirPath(c.io, d);
        try Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = data });
    }

    pub fn filter(c: *Ctx) !scale_mod.Filter {
        if (c.args.get("edge")) |e| {
            scale_mod.edge = std.meta.stringToEnum(scale_mod.Edge, e) orelse return fail("--edge is zero or clamp, got '{s}'", .{e});
        }
        const f = c.args.get("filter") orelse return .mmpx;
        return std.meta.stringToEnum(scale_mod.Filter, f) orelse fail("--filter is mmpx or nearest, got '{s}'", .{f});
    }

    pub fn scaleFactor(c: *Ctx) !u32 {
        const k = try c.args.int("scale", 1);
        if (k < 1 or k > 4) return fail("--scale is 1, 2, 3 or 4", .{});
        return k;
    }
};

/// A palette as the game stores it and as everything else wants it.
pub const Palette = struct {
    bgr: formats.palette.Palette,
    rgb: [768]u8,
    /// The pal.pl2 beside it, when there is one.
    pl2: ?[]const u8,

    pub fn fromBgr(bgr: formats.palette.Palette, pl2: ?[]const u8) Palette {
        var p: Palette = .{ .bgr = bgr, .rgb = undefined, .pl2 = pl2 };
        for (0..256) |i| {
            const c = bgr.rgb(@intCast(i));
            p.rgb[i * 3 ..][0..3].* = c;
        }
        return p;
    }
};

pub fn loadPalette(c: *Ctx) !Palette {
    const spec = c.args.get("palette") orelse "act1";
    const is_file = std.mem.endsWith(u8, spec, ".dat") and (Dir.cwd().statFile(c.io, spec, .{}) catch null) != null;
    if (is_file) {
        const bytes = try source.readFile(c.gpa, c.io, spec);
        const pl2_path = try std.fmt.allocPrint(c.gpa, "{s}.pl2", .{spec[0 .. spec.len - 4]});
        const pl2 = source.readFile(c.gpa, c.io, pl2_path) catch null;
        return Palette.fromBgr(try formats.palette.parseDat(bytes), pl2);
    }
    const s = try c.source_();
    const dat = try std.fmt.allocPrint(c.gpa, "data/global/palette/{s}/pal.dat", .{spec});
    const bytes = s.read(c.gpa, dat) catch return fail("no palette '{s}' ({s})", .{ spec, dat });
    const pl2_name = try std.fmt.allocPrint(c.gpa, "data/global/palette/{s}/pal.pl2", .{spec});
    const pl2 = s.read(c.gpa, pl2_name) catch null;
    return Palette.fromBgr(try formats.palette.parseDat(bytes), pl2);
}

/// `pl2:TABLE:N` or `map:NAME:N` -> a 256-entry index map.
pub fn loadShift(c: *Ctx, pal: *const Palette, spec: []const u8) !*const [256]u8 {
    var it = std.mem.splitScalar(u8, spec, ':');
    const kind = it.next() orelse "";
    const what = it.next() orelse return fail("shift '{s}' is pl2:TABLE:N or map:NAME:N", .{spec});
    const n_str = it.next() orelse return fail("shift '{s}' is missing its table number", .{spec});
    const n = std.fmt.parseInt(usize, n_str, 10) catch return fail("shift '{s}': bad table number", .{spec});
    if (std.mem.eql(u8, kind, "pl2")) {
        const pl2 = pal.pl2 orelse return fail("the palette has no pal.pl2 for '{s}'", .{spec});
        const table = std.meta.stringToEnum(formats.pl2.Table, what) orelse return fail("no pl2 table '{s}'", .{what});
        const t = formats.pl2.transform(pl2, table, n) catch |e| return fail("shift '{s}': {s}", .{ spec, @errorName(e) });
        return t[0..256];
    }
    if (std.mem.eql(u8, kind, "map")) {
        const bytes = (try c.source_()).read(c.gpa, what) catch return fail("no colour map '{s}'", .{what});
        if ((n + 1) * 256 > bytes.len) return fail("colour map '{s}' has {d} tables", .{ what, bytes.len / 256 });
        return bytes[n * 256 ..][0..256];
    }
    return fail("shift '{s}' is pl2:TABLE:N or map:NAME:N", .{spec});
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.arena.allocator();
    const argv = init.minimal.args.toSlice(gpa) catch return 1;
    if (argv.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const args = Args.parse(gpa, argv[2..]) catch return 2;
    var ctx: Ctx = .{ .gpa = gpa, .io = init.io, .args = args, .env = init.environ_map };
    run(&ctx, argv[1]) catch |e| switch (e) {
        error.Usage => return 2,
        error.Failed => return 1,
        else => {
            std.debug.print("sprite: {s}\n", .{@errorName(e)});
            return 1;
        },
    };
    return 0;
}

fn run(c: *Ctx, cmd: []const u8) !void {
    const Cmd = enum { list, info, extract, render, compose, unpack, pack, upscale, batch, verify, help };
    const which = std.meta.stringToEnum(Cmd, cmd) orelse {
        std.debug.print("{s}", .{usage});
        return error.Usage;
    };
    switch (which) {
        .help => std.debug.print("{s}", .{usage}),
        .list => try list(c),
        .info => try info(c),
        .extract => try extract(c),
        .render => try render(c),
        .compose => try compose_mod.run(c),
        .unpack => try pack_mod.unpackCmd(c),
        .pack => try pack_mod.packCmd(c),
        .upscale => try pack_mod.upscaleCmd(c),
        .batch => try pack_mod.batchCmd(c),
        .verify => try pack_mod.verifyCmd(c),
    }
}

/// Names that match `--match` (default everything), in sorted order.
pub fn matching(c: *Ctx, default_pattern: []const u8) ![]const []const u8 {
    const s = try c.source_();
    const pattern = c.args.get("match") orelse default_pattern;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (s.names.items) |n| if (source.globMatch(pattern, n)) try out.append(c.gpa, n);
    return out.items;
}

fn list(c: *Ctx) !void {
    const names = try matching(c, "**");
    var aw: std.Io.Writer.Allocating = .init(c.gpa);
    if (c.args.flag("json")) {
        try std.json.Stringify.value(names, .{ .whitespace = .indent_2 }, &aw.writer);
        try aw.writer.writeByte('\n');
    } else {
        for (names) |n| try aw.writer.print("{s}\n", .{n});
    }
    try c.out(aw.written());
}

fn extract(c: *Ctx) !void {
    const name = try c.args.arg(0, "NAME");
    const bytes = (try c.source_()).read(c.gpa, name) catch |e| return fail("{s}: {s}", .{ name, @errorName(e) });
    try c.writeFile(try c.args.need("out"), bytes);
}

pub fn kindOf(name: []const u8) !sprite.Kind {
    return sprite.Kind.fromName(name) orelse fail("{s}: not a .dc6 or .dcc", .{name});
}

pub fn loadSprite(c: *Ctx, name: []const u8) !sprite.Sprite {
    const kind = try kindOf(name);
    const bytes = (try c.source_()).read(c.gpa, name) catch |e| return fail("{s}: {s}", .{ name, @errorName(e) });
    return sprite.load(c.gpa, kind, bytes) catch |e| {
        std.debug.print("sprite: {s}: {s}\n", .{ name, @errorName(e) });
        return error.Failed;
    };
}

fn info(c: *Ctx) !void {
    const name = try c.args.arg(0, "NAME");
    if (std.ascii.endsWithIgnoreCase(name, ".cof")) {
        const bytes = (try c.source_()).read(c.gpa, name) catch |e| return fail("{s}: {s}", .{ name, @errorName(e) });
        const cof = formats.cof.parse(c.gpa, bytes) catch return error.Failed;
        const json = try pack_mod.cofJson(c.gpa, name, &cof);
        return c.out(json);
    }
    const sp = try loadSprite(c, name);
    const doc = try pack_mod.describe(c.gpa, name, &sp, 1, null, false);
    if (c.args.flag("json")) {
        try c.out(try std.json.Stringify.valueAlloc(c.gpa, doc, .{ .whitespace = .indent_2 }));
        try c.out("\n");
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(c.gpa);
    try aw.writer.print("{s}: {s}, {d} dirs x {d} frames\n", .{ name, @tagName(sp.kind), sp.dirs, sp.fpd });
    for (doc.frames) |f| try aw.writer.print("  d{d} f{d}  {d}x{d} at ({d},{d})  {s}\n", .{ f.dir, f.frame, f.w, f.h, f.x, f.y, f.hash });
    try c.out(aw.written());
}

fn render(c: *Ctx) !void {
    const name = try c.args.arg(0, "NAME");
    const out_path = try c.args.need("out");
    const sp = try loadSprite(c, name);
    const pal = try loadPalette(c);
    const shift: ?*const [256]u8 = if (c.args.get("shift")) |s| try loadShift(c, &pal, s) else null;
    const k = try c.scaleFactor();
    const filt = try c.filter();

    var cells: std.ArrayListUnmanaged(compose_mod.Cell) = .empty;
    var cols: u32 = 1;
    if (c.args.flag("all")) {
        cols = sp.fpd;
        for (0..sp.dirs) |d| for (0..sp.fpd) |f| {
            try cells.append(c.gpa, try compose_mod.single(c.gpa, sp.at(@intCast(d), @intCast(f)), k, filt, &pal, shift));
        };
    } else {
        const d = try c.args.int("dir", 0);
        const f = try c.args.int("frame", 0);
        if (d >= sp.dirs or f >= sp.fpd) return fail("{s} has {d} dirs x {d} frames", .{ name, sp.dirs, sp.fpd });
        try cells.append(c.gpa, try compose_mod.single(c.gpa, sp.at(d, f), k, filt, &pal, shift));
    }
    const png = try compose_mod.renderGrid(c.gpa, cells.items, cols, &pal, c.args.flag("indexed"));
    try c.writeFile(out_path, png);
}

test {
    _ = source;
    _ = sprite;
    _ = pngx;
    _ = pack_mod;
    _ = compose_mod;
}
