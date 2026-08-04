//! render-items demo: roll N drops off a monster treasure class + mlvl + seed,
//! resolve each item's real inventory sprite + quality colour, decode the DC6, and
//! composite them into ONE PNG grid (quality-coloured cell borders).
//!
//! Usage: render-items <seed> <treasureclass> <mlvl> <out.png> [magicfind]
//! Needs the gitignored assets/ dir (run tools/extract_assets first).

const std = @import("std");
const lib = @import("lib.zig");
const render = @import("render.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // argv[0]
    const a_seed = it.next();
    const a_tc = it.next();
    const a_mlvl = it.next();
    const a_out = it.next();
    const a_mf = it.next();

    if (a_seed == null or a_tc == null or a_mlvl == null or a_out == null) {
        std.debug.print(
            \\render-items — roll a drop + render real item graphics to a PNG grid
            \\usage: render-items <seed> <treasureclass> <mlvl> <out.png> [magicfind]
            \\  e.g. render-items 12345 "Act 1 H2H B" 30 out.png 300
            \\
        , .{});
        return;
    }

    const seed_val = try std.fmt.parseInt(u32, a_seed.?, 10);
    const tc_name = a_tc.?;
    const mlvl = try std.fmt.parseInt(i32, a_mlvl.?, 10);
    const out_path = a_out.?;
    const mf: i32 = if (a_mf) |m| try std.fmt.parseInt(i32, m, 10) else 0;

    var t = try lib.Tables.load(gpa);
    defer t.deinit();
    var set = try lib.treasure.build(gpa, &t);
    defer set.deinit();

    // Roll multiple times so we get a full grid (each roll = one monster kill).
    var drops: std.ArrayListUnmanaged(lib.Drop) = .empty;
    defer drops.deinit(gpa);
    var k: u32 = 0;
    while (k < 24 and drops.items.len < 15) : (k += 1) {
        var drop_seed = lib.Seed.init(seed_val +% k, 0x29a);
        const rolled = try lib.rollDrop(gpa, &drop_seed, &t, &set, tc_name, mlvl, .{
            .magic_find = mf,
            .item_seed_base = (seed_val +% k) ^ 0x5eed,
        });
        defer gpa.free(rolled);
        for (rolled) |d| {
            if (d.kind == .item and t.itemRef(d.code()) != null) try drops.append(gpa, d);
        }
    }

    std.debug.print("rolled {d} renderable item(s) from tc=\"{s}\" mlvl={d} mf={d}\n", .{ drops.items.len, tc_name, mlvl, mf });
    for (drops.items) |d| std.debug.print("  {s} quality={s}\n", .{ d.code(), @tagName(d.quality) });

    const png_bytes = try render.renderDropsToPng(gpa, &t, drops.items, "assets");
    defer gpa.free(png_bytes);

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = png_bytes });
    std.debug.print("wrote {s} ({d} bytes)\n", .{ out_path, png_bytes.len });
}
