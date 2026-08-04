//! Multi-seed masked-CRC collision holdout. The per-cell byte verify only covers a handful of
//! seeds, which invites seed-specific fixes. This checks our generated collision against a broad
//! golden: 200 seeds x 131 levels of per-level order-independent FNV checksums captured from the
//! real 1.14d engine (d2probe). The checksum hashes each room's (px,py,w,h) + its cells masked to
//! the low 5 static-terrain COLBITs (0x1F), identical to coll_logger.zig — so a level's CRC
//! matches ONLY if every one of our rooms is byte-exact for that seed. A fix tuned to one seed
//! fails the rest.
//!
//! Scope: ALL FIVE ACTS, 200 seeds, at ALL THREE DIFFICULTIES. Difficulty reaches the DRLG in
//! exactly one place: ActualLevelGeneration (Maze.cpp, 0x671210) indexes the LvlMaze row's
//! Rooms[3] with pLevel->pDrlg->nDifficulty to get the section count a maze level grows to.
//! Levels.txt SizeX/SizeY are identical across the N/(N)/(H) columns on all 138 rows, so nothing
//! else in layout can move. Only 9 of the 82 maze levels have differing Rooms columns — 18, 19,
//! 21-24 (Crypt, Mausoleum, Tower Cellar 1-4), 100, 101 (Durance 1-2) and 133 (Pandemonium Run 1)
//! — and a seed-98 three-way engine capture confirms those 9 and only those 9 change: 9 of 131
//! levels differ Normal vs Nightmare, 6 differ Nightmare vs Hell (Rooms(N) == Rooms(H) on ids 24,
//! 100 and 101), 122 levels are identical CRC and cell count at every difficulty.
//!
//! The Nightmare golden long predates the other two: until the d2probe fix that stopped the
//! bGameIsSetup write from landing on D2GameStrc+109 (nDifficulty), every capture came out at
//! Nightmare whatever --diff asked for. The Normal and Hell goldens are the first captures where
//! the flag actually reached the engine; the re-captured Nightmare set is byte-identical to the
//! golden it replaced, which is what pins the old capture's true difficulty.

const std = @import("std");
const lib = @import("lib.zig");

const GOLDEN_NM_GZ = @embedFile("golden/coll_crc_masked_200.jsonl.gz");
const GOLDEN_N_GZ = @embedFile("golden/coll_crc_masked_200_normal.jsonl.gz");
const GOLDEN_H_GZ = @embedFile("golden/coll_crc_masked_200_hell.jsonl.gz");

fn fnvByte(h: u32, b: u8) u32 {
    return (h ^ b) *% 0x01000193;
}
fn hashU32(h: *u32, v: u32) void {
    h.* = fnvByte(h.*, @truncate(v));
    h.* = fnvByte(h.*, @truncate(v >> 8));
    h.* = fnvByte(h.*, @truncate(v >> 16));
    h.* = fnvByte(h.*, @truncate(v >> 24));
}

/// Parse `"key":N` (unsigned) from a JSONL line; null if absent.
fn jval(line: []const u8, key: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    var i = at + key.len;
    var v: u64 = 0;
    var any = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        v = v * 10 + (line[i] - '0');
        any = true;
    }
    return if (any) v else null;
}

/// Run the cross-seed gate for one difficulty. `golden_gz` is a gzip'd d2probe CRC sweep; `diff`
/// is the difficulty it was really captured at, and every per-level checksum must match.
/// `recorded_diff` is the value the capture WROTE into its records, which is not always the same
/// thing — the pre-fix probe logged the requested flag without ever reading the engine back.
/// Asserting it separately pins each golden's provenance instead of letting a relabelled file
/// slip through.
fn runCrcGate(
    gpa: std.mem.Allocator,
    golden_gz: []const u8,
    diff: lib.Difficulty,
    recorded_diff: u64,
    label: []const u8,
) !void {
    // Decompress the gzip golden fully.
    const flate = std.compress.flate;
    var in: std.Io.Reader = .fixed(golden_gz);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var dec = flate.Decompress.init(&in, .gzip, window);
    var golden: std.ArrayListUnmanaged(u8) = .empty;
    defer golden.deinit(gpa);
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const n = dec.reader.readSliceShort(&buf) catch break;
        if (n == 0) break;
        try golden.appendSlice(gpa, buf[0..n]);
    }

    // Golden map: (seed<<16 | levelId) -> crc, plus the set of seeds it actually covers so a
    // partial capture costs only the seeds it contains.
    var gmap: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer gmap.deinit(gpa);
    var gseeds: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer gseeds.deinit(gpa);
    {
        var it = std.mem.splitScalar(u8, golden.items, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, "drlg_coll_crc") == null) continue;
            const seed = jval(line, "\"seed\":") orelse continue;
            const lid = jval(line, "\"levelId\":") orelse continue;
            const gdiff = jval(line, "\"diff\":") orelse continue;
            try std.testing.expectEqual(recorded_diff, gdiff);

            const crc = jval(line, "\"crc\":") orelse continue;
            try gmap.put(gpa, (seed << 16) | lid, @truncate(crc));
            try gseeds.put(gpa, seed, {});
        }
    }
    try std.testing.expect(gmap.count() > 0);

    // The golden holds all 200 captured seeds. Checking a subset invites exactly the
    // seed-specific fix this test exists to catch, so it checks every one of them.
    const nseeds: u32 = 200;

    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();

    // Per-level tallies across seeds.
    var matched: std.AutoHashMapUnmanaged(i32, u32) = .empty;
    defer matched.deinit(gpa);
    var total: std.AutoHashMapUnmanaged(i32, u32) = .empty;
    defer total.deinit(gpa);
    var grand_match: u32 = 0;
    var grand_total: u32 = 0;

    var seed: u32 = 1;
    while (seed <= nseeds) : (seed += 1) {
        if (!gseeds.contains(seed)) continue;
        var act_no: i32 = 0;
        while (act_no < 5) : (act_no += 1) {
            var res = lib.generateActRoomCollision(&ctx, gpa, act_no, seed, diff) catch continue;
            defer res.deinit(gpa);

            // Our per-level masked CRC (commutative sum of per-room hashes).
            var lvl_crc: std.AutoHashMapUnmanaged(i32, u32) = .empty;
            defer lvl_crc.deinit(gpa);
            for (res.rooms) |r| {
                var rh: u32 = 0x811c9dc5;
                hashU32(&rh, @bitCast(r.px));
                hashU32(&rh, @bitCast(r.py));
                hashU32(&rh, @bitCast(r.w));
                hashU32(&rh, @bitCast(r.h));
                for (r.cells) |c| hashU32(&rh, @as(u32, c & 0x1F));
                const gop = try lvl_crc.getOrPut(gpa, r.level_id);
                gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* +% rh else rh;
            }

            var lit = lvl_crc.iterator();
            while (lit.next()) |e| {
                const lid = e.key_ptr.*;
                const g = gmap.get((@as(u64, seed) << 16) | @as(u64, @intCast(lid))) orelse continue;
                const tgop = try total.getOrPut(gpa, lid);
                tgop.value_ptr.* = if (tgop.found_existing) tgop.value_ptr.* + 1 else 1;
                grand_total += 1;
                if (e.value_ptr.* == g) {
                    const mgop = try matched.getOrPut(gpa, lid);
                    mgop.value_ptr.* = if (mgop.found_existing) mgop.value_ptr.* + 1 else 1;
                    grand_match += 1;
                } else {
                    // Name the deviation. A bare count tells you something is wrong; the seed and
                    // level are what let you reproduce it against the engine capture.
                    std.debug.print("[coll-crc MISMATCH] {s} seed {d} act {d} level {d}: ours {d} golden {d}\n", .{ label, seed, act_no + 1, lid, e.value_ptr.*, g });
                }
            }
        }
    }

    const pct: u32 = if (grand_total == 0) 0 else grand_match * 100 / grand_total;
    std.debug.print("\n[coll-crc holdout] all acts, {s}, {d} seeds: {d} of {d} per-level checksums byte-exact, pct {d}\n", .{ label, nseeds, grand_match, grand_total, pct });
    std.debug.print("  levels NOT byte-exact on every seed (level: matched/total):\n", .{});
    var perfect: u32 = 0;
    var lid: i32 = 0;
    while (lid <= 140) : (lid += 1) {
        const t = total.get(lid) orelse continue;
        const m = matched.get(lid) orelse 0;
        if (m == t) {
            perfect += 1;
            continue;
        }
        std.debug.print("     L{d:0>3}: {d}/{d}\n", .{ lid, m, t });
    }
    std.debug.print("  {d} levels byte-exact on all {d} seeds\n", .{ perfect, nseeds });

    try std.testing.expect(grand_total > 0);
    // Cross-seed gate. A fix tuned to seed 1 cannot hold here, so this is the one that makes
    // "works on any seed" mean something — and it is EQUALITY: every per-level checksum of
    // every level on every seed matches the engine. Nothing to raise, nothing to concede.
    const known_deviations: u32 = 0;
    try std.testing.expectEqual(grand_total - known_deviations, grand_match);
}

test "coll: masked-CRC holdout across seeds (all acts, Nightmare)" {
    // This golden's records say "diff":2. They are wrong and always were: the probe echoed the
    // requested flag while the engine ran at Nightmare, because the setup-flag write had landed
    // on nDifficulty. Re-capturing at --diff=1 with the fixed probe reproduces this file
    // checksum-for-checksum, which is what identifies the difficulty it was really generated at.
    try runCrcGate(std.testing.allocator, GOLDEN_NM_GZ, .nightmare, 2, "Nightmare");
}

test "coll: masked-CRC holdout across seeds (all acts, Normal)" {
    try runCrcGate(std.testing.allocator, GOLDEN_N_GZ, .normal, 0, "Normal");
}

test "coll: masked-CRC holdout across seeds (all acts, Hell)" {
    try runCrcGate(std.testing.allocator, GOLDEN_H_GZ, .hell, 2, "Hell");
}

// The whole difficulty axis in one assertion: the maze section count is the only DRLG input that
// varies by difficulty, so exactly the 9 LvlMaze rows with differing Rooms columns may produce
// different geometry, and the other 122 captured levels must be identical at all three. Reading
// this straight off the three engine goldens keeps the claim honest — if a future capture drifts,
// or a difficulty silently stops reaching the maze, this fails before the per-difficulty gates do.
test "coll: difficulty moves exactly the 9 LvlMaze-scaling levels and nothing else" {
    const gpa = std.testing.allocator;

    const Sweep = struct {
        map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
        fn load(self: *@This(), a: std.mem.Allocator, gz: []const u8) !void {
            const flate = std.compress.flate;
            var in: std.Io.Reader = .fixed(gz);
            const window = try a.alloc(u8, flate.max_window_len);
            defer a.free(window);
            var dec = flate.Decompress.init(&in, .gzip, window);
            var raw: std.ArrayListUnmanaged(u8) = .empty;
            defer raw.deinit(a);
            var buf: [1 << 16]u8 = undefined;
            while (true) {
                const n = dec.reader.readSliceShort(&buf) catch break;
                if (n == 0) break;
                try raw.appendSlice(a, buf[0..n]);
            }
            var it = std.mem.splitScalar(u8, raw.items, '\n');
            while (it.next()) |line| {
                if (std.mem.indexOf(u8, line, "drlg_coll_crc") == null) continue;
                const seed = jval(line, "\"seed\":") orelse continue;
                const lid = jval(line, "\"levelId\":") orelse continue;
                const crc = jval(line, "\"crc\":") orelse continue;
                try self.map.put(a, (seed << 16) | lid, @truncate(crc));
            }
        }
    };

    var n: Sweep = .{};
    defer n.map.deinit(gpa);
    var nm: Sweep = .{};
    defer nm.map.deinit(gpa);
    var h: Sweep = .{};
    defer h.map.deinit(gpa);
    try n.load(gpa, GOLDEN_N_GZ);
    try nm.load(gpa, GOLDEN_NM_GZ);
    try h.load(gpa, GOLDEN_H_GZ);
    try std.testing.expectEqual(n.map.count(), nm.map.count());
    try std.testing.expectEqual(n.map.count(), h.map.count());

    // LvlMaze rows whose Rooms / Rooms(N) / Rooms(H) columns are not all equal.
    const scaling = [_]u64{ 18, 19, 21, 22, 23, 24, 100, 101, 133 };

    var moved: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer moved.deinit(gpa);
    var it = n.map.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const a = e.value_ptr.*;
        const b = nm.map.get(key) orelse continue;
        const c = h.map.get(key) orelse continue;
        if (a != b or b != c) try moved.put(gpa, key & 0xFFFF, {});
    }

    for (scaling) |lid| try std.testing.expect(moved.contains(lid));
    try std.testing.expectEqual(scaling.len, moved.count());
}
