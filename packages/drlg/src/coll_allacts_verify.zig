//! All-acts collision golden verify. A single d2probe capture of seed 1 across every
//! act (Act I–V, all non-town levels) — the runtime CollMap (Room1.pColl.pMapStart,
//! u16/subtile) dumped before monster spawn, so it's pure DT1 terrain collision. Stored
//! gzip'd (23.6 MB JSONL -> 371 KB) and decompressed here, then handed to the same
//! verifyActCollision the per-act tests use; it auto-detects which acts appear from the
//! golden's level ids and generates each. Reports per-act masked-0x1F fidelity.
//!
//! Difficulty: the DRLG runs at Nightmare regardless of the game's marker (see the
//! .nightmare note on the seed-1 Act-1 test), so we verify at .nightmare.

const std = @import("std");
const lib = @import("lib.zig");

const GOLDEN_GZ = @embedFile("golden/coll_seed1_all.jsonl.gz");
const GOLDEN_777_GZ = @embedFile("golden/coll_seed777_all.jsonl.gz");

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

    const r = try lib.verifyActCollision(gpa, &ctx, golden, .nightmare, true);
    const pct: u64 = if (r.total_cells > 0) @as(u64, r.masked_ok) * 100 / r.total_cells else 0;
    std.debug.print(
        "\n[coll all-acts seed 1] rooms matched={d} dim_mismatch={d} golden_only={d} | cells={d} masked-0x1F ok={d} ({d}%)\n",
        .{ r.matched_rooms, r.dim_mismatch, r.golden_only, r.total_cells, r.masked_ok, pct },
    );
    try std.testing.expect(r.matched_rooms > 0);
    // Lock overall all-acts fidelity; raise as mechanisms close. Never regress.
    // Both goldens are ALL-ROOMS-ACTIVE REBUILT captures (2026-07-08): the engine
    // builds each room's CollMap once at activation, seeing only the neighbors
    // active at that moment, so a plain activate+dump walk bakes the activation
    // ORDER into the capture (645 cells / 36 rooms at seed 1). The capture now
    // frees + re-allocs every room's grid after the full level walk, giving the
    // steady-state map the port targets. Measured 11,083,341 (99.959%) at rebase.
    try std.testing.expect(r.masked_ok >= 11_085_000);
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
        "[coll all-acts seed 777] rooms matched={d} dim_mismatch={d} | cells={d} masked-0x1F ok={d}\n",
        .{ r.matched_rooms, r.dim_mismatch, r.total_cells, r.masked_ok },
    );
    try std.testing.expectEqual(@as(u32, 777), r.seed);
    try std.testing.expect(r.matched_rooms > 0);
    try std.testing.expectEqual(@as(usize, 0), r.dim_mismatch);
    // Rebuilt (all-rooms-active) golden; 11,154,056 after the +1 wall-edge gather.
    try std.testing.expect(r.masked_ok >= 11_155_000);
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
    // Precise Act-1 tracker for the session's outdoor sub-theme / DS1-parse fixes.
    // Never regress; raise as fidelity climbs.
    try std.testing.expect(r.masked_ok >= 2_189_500);
}
