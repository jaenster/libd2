//! Smoke/demo CLI: roll an item drop for a seed + treasure class + monster level.
//! Usage: d2-items <seed> <treasureclass> <mlvl> [magicfind]

const std = @import("std");
const lib = @import("lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // argv[0]
    const a_seed = it.next();
    const a_tc = it.next();
    const a_mlvl = it.next();
    const a_mf = it.next();

    var t = try lib.Tables.load(gpa);
    defer t.deinit();
    var set = try lib.treasure.build(gpa, &t);
    defer set.deinit();

    if (a_seed == null or a_tc == null or a_mlvl == null) {
        std.debug.print(
            \\d2-items — faithful D2 1.14d drop roller
            \\loaded {d} treasure classes, {d} magic prefixes, {d} suffixes
            \\usage: d2-items <seed> <treasureclass> <mlvl> [magicfind]
            \\  e.g. d2-items 12345 "Act 1 Equip A" 12 200
            \\
        , .{ t.treasure.rowCount(), t.magic_prefix.rowCount(), t.magic_suffix.rowCount() });
        return;
    }

    const seed_val = try std.fmt.parseInt(u32, a_seed.?, 10);
    const tc_name = a_tc.?;
    const mlvl = try std.fmt.parseInt(i32, a_mlvl.?, 10);
    const mf: i32 = if (a_mf) |m| try std.fmt.parseInt(i32, m, 10) else 0;

    var drop_seed = lib.Seed.init(seed_val, 0x29a);
    const drops = try lib.rollDrop(gpa, &drop_seed, &t, &set, tc_name, mlvl, .{
        .magic_find = mf,
        .item_seed_base = seed_val ^ 0x5eed,
    });
    defer gpa.free(drops);

    std.debug.print("seed={d} tc=\"{s}\" mlvl={d} mf={d} -> {d} drop(s):\n", .{ seed_val, tc_name, mlvl, mf, drops.len });
    for (drops, 0..) |d, i| {
        switch (d.kind) {
            .gold => std.debug.print("  [{d}] gold\n", .{i}),
            .item => std.debug.print(
                "  [{d}] {s} quality={s} pfx={d} sfx={d} rare_pfx={any} rare_sfx={any} sockets={d}\n",
                .{ i, d.code(), @tagName(d.quality), d.prefix_id, d.suffix_id, d.rare_prefix_ids, d.rare_suffix_ids, d.sockets },
            ),
            else => std.debug.print("  [{d}] {s}\n", .{ i, @tagName(d.kind) }),
        }
    }
}
