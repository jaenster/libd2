//! Memory-growth gate. Generation is a request-scoped operation — drlg-server holds one `Ctx` per
//! worker for the process lifetime and generates acts against it forever — so the invariant that
//! matters is BOUNDEDNESS: the Nth act must not cost more resident memory than the first.
//!
//! This is asserted as a ratio, not an absolute ceiling. An absolute "stay under N MB" rots the
//! moment a table grows and invites raising the number; comparing two equal-sized batches only
//! fails when generation actually accumulates. Process RSS is the measure rather than an allocator
//! counter because the leak this gate was written for was invisible to every allocator in the
//! program: it accumulated inside `std.debug`'s global unwind arena (see testalloc.zig).
//!
//! The first batch is a warm-up whose growth is discarded — the DS1 parse cache, the DS1/DT1 blob
//! indices and the level tables legitimately fill on first use and then plateau. Only the second
//! batch's growth is asserted.

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");
const testalloc = @import("testalloc.zig");

/// Peak resident set size in bytes. `ru_maxrss` is bytes on Darwin and kilobytes everywhere else
/// that implements it. Peak (rather than current) is what a leak moves and what an operator hits.
fn peakRssBytes() ?u64 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.cpu.arch.isWasm()) return null;
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    if (ru.maxrss <= 0) return null;
    const raw: u64 = @intCast(ru.maxrss);
    return if (builtin.os.tag.isDarwin()) raw else raw * 1024;
}

/// Every act of every one of `seeds`, discarding the result. Returns the number generated.
fn generateBatch(ctx: *lib.Ctx, gpa: std.mem.Allocator, seeds: []const u32) usize {
    var n: usize = 0;
    for (seeds) |seed| {
        var act_no: i32 = 0;
        while (act_no < 5) : (act_no += 1) {
            var res = lib.generateActRoomCollision(ctx, gpa, act_no, seed, .nightmare) catch continue;
            res.deinit(gpa);
            n += 1;
        }
    }
    return n;
}

// Under the leak this gate was written for, a 10-act batch grew peak RSS by ~850 MB. Genuine
// post-warm-up growth is a few MB of DS1 cache for files the warm-up seeds happened not to touch,
// so 64 MB sits an order of magnitude below the failure signal without being flaky.
const slack_bytes: u64 = 64 * 1024 * 1024;

test "drlg: repeated act generation does not grow memory" {
    const rss0 = peakRssBytes() orelse return; // no RSS on this target — nothing to assert
    _ = rss0;

    var mem: testalloc.Checked = .{};
    defer mem.deinit();
    const gpa = mem.allocator();

    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();

    const warm = [_]u32{ 1, 2 };
    const measured = [_]u32{ 3, 4 };

    const warm_acts = generateBatch(&ctx, gpa, &warm);
    const rss_a = peakRssBytes().?;
    const measured_acts = generateBatch(&ctx, gpa, &measured);
    const rss_b = peakRssBytes().?;

    try std.testing.expect(warm_acts > 0 and measured_acts > 0);
    const grew = rss_b -| rss_a;
    std.debug.print(
        "\n[mem] {d} warm-up acts -> peak {d} MB; {d} more acts -> peak {d} MB (grew {d} MB, budget {d} MB)\n",
        .{ warm_acts, rss_a >> 20, measured_acts, rss_b >> 20, grew >> 20, slack_bytes >> 20 },
    );
    if (grew > slack_bytes) {
        std.debug.print(
            "[mem] FAIL: generating {d} more acts cost {d} MB of peak RSS. Act generation must be bounded —\n" ++
                "      the same Ctx serves requests for the process lifetime, so per-act growth is a leak.\n",
            .{ measured_acts, grew >> 20 },
        );
        return error.ActGenerationGrowsMemory;
    }
}

test "drlg: repeated generateActFull (shipped consumer path) does not grow memory" {
    const rss0 = peakRssBytes() orelse return;
    _ = rss0;

    var mem: testalloc.Checked = .{};
    defer mem.deinit();
    const gpa = mem.allocator();

    var ctx = lib.Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();

    // drlg-server calls this per request; a leak here is a production problem, not a test one.
    const Batch = struct {
        fn run(c: *lib.Ctx, a: std.mem.Allocator, seeds: []const u32) usize {
            var n: usize = 0;
            for (seeds) |seed| {
                var act_no: i32 = 0;
                while (act_no < 5) : (act_no += 1) {
                    var res = lib.generateActFull(c, a, act_no, seed, .nightmare, .{}) catch continue;
                    res.deinit(a);
                    n += 1;
                }
            }
            return n;
        }
    };

    const warm_acts = Batch.run(&ctx, gpa, &.{ 1, 2 });
    const rss_a = peakRssBytes().?;
    const measured_acts = Batch.run(&ctx, gpa, &.{ 3, 4 });
    const rss_b = peakRssBytes().?;

    try std.testing.expect(warm_acts > 0 and measured_acts > 0);
    const grew = rss_b -| rss_a;
    std.debug.print(
        "\n[mem] generateActFull: {d} warm-up acts -> peak {d} MB; {d} more -> peak {d} MB (grew {d} MB, budget {d} MB)\n",
        .{ warm_acts, rss_a >> 20, measured_acts, rss_b >> 20, grew >> 20, slack_bytes >> 20 },
    );
    if (grew > slack_bytes) return error.ActGenerationGrowsMemory;
}
