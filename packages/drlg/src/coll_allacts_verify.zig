//! All-acts collision golden verify. A single d2probe capture of seed 1 across every
//! act (Act I–V, all non-town levels) — the runtime CollMap (Room1.pColl.pMapStart,
//! u16/subtile) dumped before monster spawn, so it's pure DT1 terrain collision. Stored
//! gzip'd (23.6 MB JSONL -> 371 KB) and decompressed here, then handed to the same
//! verifyActCollision the per-act tests use; it auto-detects which acts appear from the
//! golden's level ids and generates each. Reports per-act masked-0x1F fidelity.
//!
//! Difficulty: every per-cell golden here is a NIGHTMARE capture, so we verify at .nightmare.
//! Not by choice originally — d2probe wrote its bGameIsSetup flag onto D2GameStrc+109, which is
//! nDifficulty, so the engine ran at Nightmare whatever --diff asked for. That is fixed, and a
//! re-capture at --diff=1 reproduces these goldens exactly; the cross-seed CRC gate in
//! coll_crc_verify.zig is where all three difficulties are covered.

const std = @import("std");
const lib = @import("lib.zig");

const GOLDEN_GZ = @embedFile("golden/coll_seed1_all.jsonl.gz");
const GOLDEN_777_GZ = @embedFile("golden/coll_seed777_all.jsonl.gz");
/// A THIRD per-cell seed, and the one that earns its keep: seeds 1 and 777 happen to be
/// clean on the Sewers rooms whose DS1 variant this port used to roll instead of pin, so
/// only seed 2 could see that defect per-cell. Captured 2026-08-02 with the same d2probe
/// build as the other two.
const GOLDEN_2_GZ = @embedFile("golden/coll_seed2_all.jsonl.gz");
/// Two more per-cell seeds. They were the last two the 25-seed CRC holdout flagged (L56 on
/// one, L67 on the other) — captured to read the residual as coordinates instead of a
/// checksum, and kept as gates now that they are byte-exact.
const GOLDEN_17_GZ = @embedFile("golden/coll_seed17_all.jsonl.gz");
const GOLDEN_18_GZ = @embedFile("golden/coll_seed18_all.jsonl.gz");
/// A BLIND holdout: seed 1033089920, drawn at random from /dev/urandom AFTER collision went
/// byte-exact, captured once, and never looked at while developing anything. Nothing in this
/// port has ever been tuned against it, so it is the only gate here that can answer "does this
/// generalise" rather than "does this still pass".
const GOLDEN_HOLDOUT_GZ = @embedFile("golden/coll_seed_holdout.jsonl.gz");
/// Second blind draw (seed 2097937279), same rules — two independent draws rather than one, so
/// a single lucky seed cannot be mistaken for generalisation.
const GOLDEN_HOLDOUT2_GZ = @embedFile("golden/coll_seed_holdout2.jsonl.gz");

fn decompressGolden(gpa: std.mem.Allocator) ![]u8 {
    return decompressGz(gpa, GOLDEN_GZ);
}

fn decompressGz(gpa: std.mem.Allocator, gz: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var in: std.Io.Reader = .fixed(gz);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var dec = flate.Decompress.init(&in, .gzip, window);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const n = dec.reader.readSliceShort(&buf) catch break;
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

test "coll: all-acts golden (seed 1, Act I–V)" {
    const gpa = std.testing.allocator;
    const golden = decompressGolden(gpa) catch return;
    defer gpa.free(golden);

    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();

    lib.dump_mismatch_cells = true;
    defer lib.dump_mismatch_cells = false;
    const r = try lib.verifyActCollision(gpa, &ctx, golden, .nightmare, true);
    const pct: u64 = if (r.total_cells > 0) @as(u64, r.masked_ok) * 100 / r.total_cells else 0;
    std.debug.print(
        "\n[coll all-acts seed 1] cells={d} | walkable off {d} | masked off {d} | exact off {d} | pct {d}\n",
        .{ r.total_cells, r.total_cells - r.walk_ok, r.total_cells - r.masked_ok, r.total_cells - r.exact_ok, pct },
    );
    try std.testing.expect(r.matched_rooms > 0);
    // BYTE-EXACT against the engine. The goldens are ALL-ROOMS-ACTIVE REBUILT captures
    // (2026-07-08): the engine builds each room's CollMap once at activation, seeing only
    // the neighbors active at that moment, so a plain activate+dump walk bakes the
    // activation ORDER into the capture (645 cells / 36 rooms at seed 1). The capture
    // frees + re-allocs every room's grid after the full level walk, giving the
    // steady-state map the port targets. Equality, not a floor — there is nothing left to
    // concede, so any drift at all is a regression.
    try std.testing.expectEqual(r.total_cells, r.walk_ok);
    try std.testing.expectEqual(r.total_cells, r.masked_ok);
    try std.testing.expectEqual(r.total_cells, r.exact_ok);
}

test "coll: all-acts golden (seed 2, maze cross-seed probe)" {
    const gpa = std.testing.allocator;
    const golden = decompressGz(gpa, GOLDEN_2_GZ) catch return;
    defer gpa.free(golden);
    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    const r = try lib.verifyActCollision(gpa, &ctx, golden, .nightmare, false);
    std.debug.print("[coll all-acts seed 2] cells={d} | walkable off {d} | masked off {d} | exact off {d}\n", .{ r.total_cells, r.total_cells - r.walk_ok, r.total_cells - r.masked_ok, r.total_cells - r.exact_ok });
    try std.testing.expectEqual(@as(u32, 2), r.seed);
    try std.testing.expectEqual(@as(u32, 0), r.dim_mismatch);
    // Byte-exact. The bulk used to be one L47 Sewers room whose DS1 variant came from a
    // roll instead of the engine's pinned File[0] (AllocRoomExAndPickPreset variant 0).
    try std.testing.expectEqual(r.total_cells, r.walk_ok);
    try std.testing.expectEqual(r.total_cells, r.masked_ok);
    try std.testing.expectEqual(r.total_cells, r.exact_ok);
}

test "coll: all-acts golden (seed 777, cross-seed regression)" {
    // Second, independent seed captured 2026-07-08 (d2probe --spawn --seedstart=777).
    // Guards the fidelity chain against seed-1-specific fitting: every mechanism fix
    // must hold here without ever having been measured against this seed.
    const gpa = std.testing.allocator;
    const golden = decompressGz(gpa, GOLDEN_777_GZ) catch return;
    defer gpa.free(golden);

    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();

    const r = try lib.verifyActCollision(gpa, &ctx, golden, .nightmare, false);
    std.debug.print(
        "[coll all-acts seed 777] cells={d} | walkable off {d} | masked off {d} | exact off {d}\n",
        .{ r.total_cells, r.total_cells - r.walk_ok, r.total_cells - r.masked_ok, r.total_cells - r.exact_ok },
    );
    try std.testing.expectEqual(@as(u32, 777), r.seed);
    try std.testing.expect(r.matched_rooms > 0);
    try std.testing.expectEqual(@as(usize, 0), r.dim_mismatch);
    // Rebuilt (all-rooms-active) golden, byte-exact.
    try std.testing.expectEqual(r.total_cells, r.walk_ok);
    try std.testing.expectEqual(r.total_cells, r.masked_ok);
    try std.testing.expectEqual(r.total_cells, r.exact_ok);
}

test "coll: all-acts golden (seeds 17 + 18, the former CRC holdouts)" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ GOLDEN_17_GZ, GOLDEN_18_GZ }) |gz| {
        const golden = decompressGz(gpa, gz) catch continue;
        defer gpa.free(golden);
        var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
        defer ctx.deinit();
        lib.dump_mismatch_cells = true;
        defer lib.dump_mismatch_cells = false;
        const r = try lib.verifyActCollision(gpa, &ctx, golden, .nightmare, false);
        std.debug.print("[coll all-acts seed {d}] cells={d} | walkable off {d} | masked off {d} | exact off {d}\n", .{ r.seed, r.total_cells, r.total_cells - r.walk_ok, r.total_cells - r.masked_ok, r.total_cells - r.exact_ok });
        try std.testing.expectEqual(@as(u32, 0), r.dim_mismatch);
        try std.testing.expectEqual(r.total_cells, r.walk_ok);
        try std.testing.expectEqual(r.total_cells, r.masked_ok);
        try std.testing.expectEqual(r.total_cells, r.exact_ok);
    }
}

test "coll: BLIND holdout seed (never used to develop anything)" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ GOLDEN_HOLDOUT_GZ, GOLDEN_HOLDOUT2_GZ }) |gz| {
        const golden = decompressGz(gpa, gz) catch continue;
        defer gpa.free(golden);
        var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
        defer ctx.deinit();
        lib.dump_mismatch_cells = true;
        defer lib.dump_mismatch_cells = false;
        const r = try lib.verifyActCollision(gpa, &ctx, golden, .nightmare, false);
        std.debug.print("[coll HOLDOUT seed {d}] cells={d} | walkable off {d} | masked off {d} | exact off {d}\n", .{ r.seed, r.total_cells, r.total_cells - r.walk_ok, r.total_cells - r.masked_ok, r.total_cells - r.exact_ok });
        try std.testing.expect(r.matched_rooms > 0);
        try std.testing.expectEqual(@as(u32, 0), r.dim_mismatch);
        try std.testing.expectEqual(r.total_cells, r.walk_ok);
        try std.testing.expectEqual(r.total_cells, r.masked_ok);
        try std.testing.expectEqual(r.total_cells, r.exact_ok);
    }
}

test "coll: composite raw grid must not alter the per-room cells" {
    // The whole-level composite is what drlg-server serves (generateActFull ->
    // compositeLevelRaw) and what the DBM consumers read, but nothing verified it: every
    // collision gate here checks the PER-ROOM grids. A rewrite living only in the composite
    // could therefore corrupt the served map while all of them stayed green — which is
    // exactly what happened (COLLIDE_BLANK 0x20 was being rewritten to solid rock, turning
    // walkable cells into walls). Invariant: for a subtile exactly one room covers, the
    // composite must reproduce that room's cell verbatim.
    const gpa = std.testing.allocator;
    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    const seed: u32 = 1033089920;
    var act_no: i32 = 0;
    while (act_no < 5) : (act_no += 1) {
        var per = lib.generateActCollisionAll(&ctx, gpa, act_no, seed, .nightmare) catch continue;
        defer per.deinit(gpa);
        var raw = try lib.generateActCompositeRaw(&ctx, gpa, act_no, seed, .nightmare);
        defer raw.deinit(gpa);
        for (per.levels) |lc| {
            var comp: ?lib.RawLevelComposite = null;
            for (raw.levels) |r| {
                if (r.level_id == lc.level_id) comp = r;
            }
            const c = comp orelse continue;
            const cw: i32 = @intCast(c.w);
            const ch: i32 = @intCast(c.h);
            // Coverage count, so overlapping rooms (which the composite ORs) are excluded.
            const cover = try gpa.alloc(u8, c.w * c.h);
            defer gpa.free(cover);
            @memset(cover, 0);
            for (lc.grids) |g| {
                var y: i32 = 0;
                while (y < g.h) : (y += 1) {
                    var x: i32 = 0;
                    while (x < g.w) : (x += 1) {
                        const dx = g.x + x;
                        const dy = g.y + y;
                        if (dx < 0 or dy < 0 or dx >= cw or dy >= ch) continue;
                        const di: usize = @intCast(dy * cw + dx);
                        if (cover[di] < 2) cover[di] += 1;
                    }
                }
            }
            for (lc.grids) |g| {
                var y: i32 = 0;
                while (y < g.h) : (y += 1) {
                    var x: i32 = 0;
                    while (x < g.w) : (x += 1) {
                        const dx = g.x + x;
                        const dy = g.y + y;
                        if (dx < 0 or dy < 0 or dx >= cw or dy >= ch) continue;
                        const di: usize = @intCast(dy * cw + dx);
                        if (cover[di] != 1) continue;
                        const want: u16 = g.cells[@intCast(y * g.w + x)];
                        try std.testing.expectEqual(want, c.cells[di]);
                    }
                }
            }
        }
    }
}

/// Filter a decompressed all-acts golden to just the rooms whose levelId is in
/// [min,max], keeping the drlg_seed header — lets the per-act tests reuse the one
/// compressed golden instead of a separate uncompressed file per act.
fn filterToLevels(gpa: std.mem.Allocator, golden: []const u8, min: i64, max: i64) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, golden, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const keep = if (std.mem.indexOf(u8, line, "\"drlg_coll\"")) |_| blk: {
            const at = std.mem.indexOf(u8, line, "\"levelId\":") orelse break :blk false;
            var i = at + "\"levelId\":".len;
            var v: i64 = 0;
            while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) v = v * 10 + (line[i] - '0');
            break :blk v >= min and v <= max;
        } else std.mem.indexOf(u8, line, "\"drlg_seed\"") != null; // keep header
        if (keep) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

test "coll: SHIPPED consumer path (generateActCollisionAll) vs golden" {
    // What an external consumer actually calls — the C-ABI / library entry point, not the
    // per-room path the other gates drive. Checked on several seeds so "holds up as a lib"
    // means the same thing cross-seed that it does for the per-room builder.
    const gpa = std.testing.allocator;
    for ([_][]const u8{ GOLDEN_GZ, GOLDEN_2_GZ, GOLDEN_17_GZ }) |gz| {
        const g = decompressGz(gpa, gz) catch continue;
        defer gpa.free(g);
        var c = lib.Ctx.init(std.heap.page_allocator) catch return;
        defer c.deinit();
        lib.verify_consumer_path = true;
        defer lib.verify_consumer_path = false;
        const rr = try lib.verifyActCollision(gpa, &c, g, .nightmare, false);
        std.debug.print("[coll CONSUMER seed {d}] cells={d} | walkable off {d} | masked off {d} | exact off {d}\n", .{ rr.seed, rr.total_cells, rr.total_cells - rr.walk_ok, rr.total_cells - rr.masked_ok, rr.total_cells - rr.exact_ok });
        try std.testing.expectEqual(@as(u32, 0), rr.dim_mismatch);
        try std.testing.expectEqual(rr.total_cells, rr.walk_ok);
        try std.testing.expectEqual(rr.total_cells, rr.masked_ok);
        try std.testing.expectEqual(rr.total_cells, rr.exact_ok);
    }

    const gpa2 = std.testing.allocator;
    const golden = decompressGolden(gpa2) catch return;
    defer gpa2.free(golden);
    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    lib.verify_consumer_path = true;
    defer lib.verify_consumer_path = false;
    const r = try lib.verifyActCollision(gpa2, &ctx, golden, .nightmare, false);
    // The C-ABI path must not drift from the per-room path the goldens verify — it is
    // the same builder now, so it has to score identically, EXACT included (the older
    // materializer differed by 1038 masked / 1479 exact cells).
    try std.testing.expectEqual(@as(u32, 0), r.dim_mismatch);
    try std.testing.expectEqual(r.total_cells, r.walk_ok);
    try std.testing.expectEqual(r.total_cells, r.masked_ok);
    try std.testing.expectEqual(r.total_cells, r.exact_ok);
}

test "coll: DUMP our room tile arrays (vs d2probe --roomdump)" {
    if (true) return; // opt-in: set LVL, flip to `if (false)`, diff OURTILE vs the probe's roomtile
    const LVL = 56;
    const gpa = std.testing.allocator;
    const golden = decompressGz(gpa, GOLDEN_17_GZ) catch return;
    defer gpa.free(golden);
    const one = try filterToLevels(gpa, golden, LVL, LVL);
    defer gpa.free(one);
    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    lib.dump_room_tiles = LVL;
    defer lib.dump_room_tiles = -1;
    _ = try lib.verifyActCollision(gpa, &ctx, one, .nightmare, false);
}

test "coll: DUMP ours rooms for diff viz" {
    if (true) return; // opt-in debug dump: flip to `if (false)` to emit OURSROOM lines
    const gpa = std.testing.allocator;
    const golden = decompressGolden(gpa) catch return;
    defer gpa.free(golden);
    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    lib.dump_ours_rooms = true;
    _ = try lib.verifyActCollision(gpa, &ctx, golden, .nightmare, false);
    lib.dump_ours_rooms = false;
}

test "coll: seed-2 single-level focus (probe)" {
    if (true) return; // opt-in: set LVL below, flip to `if (false)`
    const LVL = 47;
    const gpa = std.testing.allocator;
    const golden = decompressGz(gpa, GOLDEN_2_GZ) catch return;
    defer gpa.free(golden);
    const one = try filterToLevels(gpa, golden, LVL, LVL);
    defer gpa.free(one);
    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    lib.probe_room = .{ .level = LVL, .px = -1, .py = -1 };
    defer lib.probe_room = null;
    _ = try lib.verifyActCollision(gpa, &ctx, one, .nightmare, false);
}

test "coll: single-level focus (probe)" {
    if (true) return; // opt-in: set the level range + probes below, flip to `if (false)`
    const gpa = std.testing.allocator;
    const golden = decompressGolden(gpa) catch return;
    defer gpa.free(golden);
    const one = try filterToLevels(gpa, golden, 111, 111);
    defer gpa.free(one);
    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    // px/py = -1 probes every room of the level.
    lib.probe_room = .{ .level = 111, .px = -1, .py = -1 };
    defer lib.probe_room = null;
    @import("drlg/tilegen.zig").probe_seq = true;
    defer @import("drlg/tilegen.zig").probe_seq = true;
    @import("drlg/tilegen.zig").probe_only_level = 111;
    defer @import("drlg/tilegen.zig").probe_only_level = -1;
    lib.dump_mismatch_cells = true;
    defer lib.dump_mismatch_cells = false;
    _ = try lib.verifyActCollision(gpa, &ctx, one, .nightmare, false);
}

test "coll: Kurast focus (L79-83 verbose)" {
    if (true) return; // opt-in: flip to `if (false)` for Kurast-only confusion + histogram
    const gpa = std.testing.allocator;
    const golden = decompressGolden(gpa) catch return;
    defer gpa.free(golden);
    const kurast = try filterToLevels(gpa, golden, 79, 83);
    defer gpa.free(kurast);
    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    _ = try lib.verifyActCollision(gpa, &ctx, kurast, .nightmare, true);
}

test "coll: Act-1 from all-acts golden (seed 1, per-cell floor)" {
    const gpa = std.testing.allocator;
    const golden = decompressGolden(gpa) catch return;
    defer gpa.free(golden);
    const act1 = try filterToLevels(gpa, golden, 2, 39);
    defer gpa.free(act1);

    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();
    const r = try lib.verifyActCollision(gpa, &ctx, act1, .nightmare, false);
    try std.testing.expectEqual(@as(u32, 1), r.seed);
    // Precise Act-1 tracker: byte-exact, like the all-acts gates it slices.
    try std.testing.expectEqual(r.total_cells, r.masked_ok);
    try std.testing.expectEqual(r.total_cells, r.exact_ok);
}
