//! bake_objects — composite the object sprites an act actually spawns into PNGs +
//! a per-act manifest the web tile viewer fetches (mirrors the /dt1 serving path).
//!
//! For each act (0..4): generate the seeded objects (generateActObjects), collect
//! the unique engine class ids, resolve each to its Objects.txt token, composite
//! its neutral sprite (mode NU, fallback OP/first-present) through THAT act's
//! palette (DCC/COF/objgfx), and write:
//!   web/public/obj/act<N>/<token>.png            straight RGBA8888 sprite
//!   web/public/obj/act<N>/manifest.json          classId -> {token,mode,w,h,ox,oy,png}
//! `ox/oy` are the sprite-local pixel offset of the top-left (object floor pivot at
//! 0,0) — the web adds them to the tile-projected screen anchor. Copyrighted art is
//! NEVER committed (web/public/obj is gitignored, like /dt1).
//!
//! Assets: needs assets/objects/<TOK>/ (run tools/extract_objects for the tokens
//! this tool reports as MISSING) + assets/automap/ACT<n>.pal. Run: `zig build bake-objects`.

const std = @import("std");
const drlg = @import("d2-drlg");
const objgfx = @import("objgfx");

// Neutral-first mode preference: NU (idle) is the resting visual; OP (open) or the
// first present mode is used only when a class has no NU frames.
const MODE_ORDER = [_][]const u8{ "NU", "OP", "ON", "S1", "S2", "S3", "S4", "S5" };
// A few seeds unioned so seed-varying populate spawns (chests/scatter) are covered.
const SEEDS = [_]u32{ 0x12345678, 0x1EF61ADD, 0x0BADF00D };

fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const objtxt = try readFile(io, alloc, "src/excel/Objects.txt");
    var objs = try objgfx.loadObjects(alloc, objtxt);
    defer objs.deinit();

    var ctx = try drlg.Ctx.init(std.heap.c_allocator);
    defer ctx.deinit();

    var total_ok: usize = 0;
    var missing = std.StringHashMap(void).init(alloc);

    var act: i32 = 0;
    while (act < 5) : (act += 1) {
        const pal_path = try std.fmt.allocPrint(alloc, "assets/automap/ACT{d}.pal", .{act + 1});
        const palette = readFile(io, alloc, pal_path) catch {
            std.debug.print("act {d}: no palette {s}\n", .{ act, pal_path });
            continue;
        };
        if (palette.len != 768) continue;

        // Union the class ids this act spawns across a few seeds.
        var ids = std.AutoHashMap(i32, void).init(alloc);
        for (SEEDS) |seed| {
            var res = drlg.generateActObjects(&ctx, alloc, act, seed, .normal) catch continue;
            defer res.deinit(alloc);
            for (res.levels) |l| for (l.objs) |o| {
                if (o.class_id >= 0) try ids.put(o.class_id, {});
            };
        }

        const dir = try std.fmt.allocPrint(alloc, "web/public/obj/act{d}", .{act});
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};

        var man: std.ArrayList(u8) = .empty;
        try man.appendSlice(alloc, "{\n");
        var first = true;
        var baked: usize = 0;

        var id_it = ids.keyIterator();
        while (id_it.next()) |class_id_ptr| {
            const class_id = class_id_ptr.*;
            const row = objs.byId(@intCast(class_id)) orelse continue;
            if (row.token.len == 0) continue;

            // Pick the first present mode (NU preferred). frame_cnt indexes NU..S5.
            var mode: []const u8 = "NU";
            var have = false;
            for (MODE_ORDER, 0..) |m, mi| {
                if (row.frame_cnt[mi] > 0) {
                    mode = m;
                    have = true;
                    break;
                }
            }
            if (!have) continue;

            var sprite = objgfx.composite(alloc, "assets", row.token, mode, "HTH", 0, 0, palette) catch |e| {
                if (e == error.CofNotFound) {
                    var lb: [16]u8 = undefined;
                    const lt = std.ascii.lowerString(&lb, row.token);
                    if (!missing.contains(lt)) try missing.put(try alloc.dupe(u8, lt), {});
                }
                continue;
            };
            defer sprite.deinit();
            if (sprite.width == 0 or sprite.height == 0) continue;

            var lb: [16]u8 = undefined;
            const ltok = std.ascii.lowerString(&lb, row.token);
            const png = try std.fmt.allocPrint(alloc, "{s}/{s}.png", .{ dir, ltok });
            try writePng(alloc, io, png, sprite.width, sprite.height, sprite.rgba);

            if (!first) try man.appendSlice(alloc, ",\n");
            first = false;
            const entry = try std.fmt.allocPrint(
                alloc,
                "  \"{d}\": {{\"token\":\"{s}\",\"mode\":\"{s}\",\"w\":{d},\"h\":{d},\"ox\":{d},\"oy\":{d},\"png\":\"{s}.png\"}}",
                .{ class_id, ltok, mode, sprite.width, sprite.height, sprite.offset_x, sprite.offset_y, ltok },
            );
            try man.appendSlice(alloc, entry);
            baked += 1;
            total_ok += 1;
        }
        try man.appendSlice(alloc, "\n}\n");
        const man_path = try std.fmt.allocPrint(alloc, "{s}/manifest.json", .{dir});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = man_path, .data = man.items });
        std.debug.print("act {d}: {d} class ids, {d} sprites baked -> {s}\n", .{ act, ids.count(), baked, dir });
    }

    if (missing.count() > 0) {
        var buf: std.ArrayList(u8) = .empty;
        var it = missing.keyIterator();
        var f = true;
        while (it.next()) |k| {
            if (!f) try buf.append(alloc, ',');
            f = false;
            try buf.appendSlice(alloc, k.*);
        }
        std.debug.print("\nMISSING art for tokens (extract via D2_OBJ_TOKENS): {s}\n", .{buf.items});
    }
    std.debug.print("total sprites baked: {d}\n", .{total_ok});
}

// -------- minimal PNG writer (RGBA8888, stored/uncompressed zlib) --------
// (same as tools/objgfx_verify.zig — a self-contained encoder, no deps.)

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (data) |b| {
        crc ^= b;
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = @bitCast(-@as(i32, @intCast(crc & 1)));
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return ~crc;
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writePng(alloc: std.mem.Allocator, io: std.Io, path: []const u8, w: u32, h: u32, rgba: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(alloc, &out, "IHDR", &ihdr);

    const raw_len = (@as(usize, w) * 4 + 1) * h;
    const raw = try alloc.alloc(u8, raw_len);
    defer alloc.free(raw);
    {
        var y: usize = 0;
        var o: usize = 0;
        while (y < h) : (y += 1) {
            raw[o] = 0;
            o += 1;
            const src = rgba[y * w * 4 .. (y + 1) * w * 4];
            @memcpy(raw[o .. o + w * 4], src);
            o += w * 4;
        }
    }

    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(alloc);
    try zlib.appendSlice(alloc, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (off < raw.len) {
        const chunk = @min(raw.len - off, 65535);
        const final: u8 = if (off + chunk >= raw.len) 1 else 0;
        try zlib.append(alloc, final);
        var lenb: [2]u8 = undefined;
        std.mem.writeInt(u16, &lenb, @intCast(chunk), .little);
        try zlib.appendSlice(alloc, &lenb);
        std.mem.writeInt(u16, &lenb, ~@as(u16, @intCast(chunk)), .little);
        try zlib.appendSlice(alloc, &lenb);
        try zlib.appendSlice(alloc, raw[off .. off + chunk]);
        off += chunk;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, adler32(raw), .big);
    try zlib.appendSlice(alloc, &adler);

    try writeChunk(alloc, &out, "IDAT", zlib.items);
    try writeChunk(alloc, &out, "IEND", &.{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

fn writeChunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, data: []const u8) !void {
    var lenb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenb, @intCast(data.len), .big);
    try out.appendSlice(alloc, &lenb);
    try out.appendSlice(alloc, tag);
    try out.appendSlice(alloc, data);
    const crc_input = try alloc.alloc(u8, tag.len + data.len);
    defer alloc.free(crc_input);
    @memcpy(crc_input[0..tag.len], tag);
    @memcpy(crc_input[tag.len..], data);
    var crcb: [4]u8 = undefined;
    std.mem.writeInt(u32, &crcb, crc32(crc_input), .big);
    try out.appendSlice(alloc, &crcb);
}
