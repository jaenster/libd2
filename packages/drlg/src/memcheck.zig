//! `d2-drlg memcheck` — asserts that generating acts is BOUNDED in memory.
//!
//! Generation is request-scoped: drlg-server holds one `Ctx` per worker for the process lifetime
//! and generates acts against it forever, so the invariant that matters is that the Nth act costs
//! no more resident memory than the first. This is checked as a ratio, not an absolute ceiling —
//! an absolute "stay under N MB" rots the moment a table grows and invites raising the number,
//! while comparing two equal-sized batches only fails when generation actually accumulates. The
//! first batch is a warm-up whose growth is discarded: the DS1 parse cache, the DS1/DT1 blob
//! indices and the level tables legitimately fill on first use and then plateau.
//!
//! It lives in the CLI rather than the test suite because a peak-RSS reading is a property of the
//! whole PROCESS: inside the test binary every other test's high-water mark contaminates it. Here
//! the process does nothing but generate.
//!
//! Process RSS is the measure rather than an allocator counter because the leak this was written
//! for was invisible to every allocator in the program — it accumulated inside `std.debug`'s
//! global unwind arena (see testalloc.zig). `--traced` reproduces that configuration on demand so
//! the check can be shown to fail, and so the test suite's own allocator choice stays honest.
//!
//! Caveat, stated because it bounds what this can catch: `ru_maxrss` is a process-wide high-water
//! mark that never falls, so the second path measured cannot see growth that stays below the peak
//! the first path already set. The regression guarded here is ~85 MB per act, which dwarfs that
//! headroom at any batch size, but a leak of a few MB per act would need its own invocation.

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");

/// Peak resident set size in bytes. `ru_maxrss` is BYTES on Darwin and KIBIBYTES on Linux and the
/// BSDs — getting that wrong puts the budget out by 1024x, so it is converted here, once.
pub fn peakRssBytes() ?u64 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.cpu.arch.isWasm()) return null;
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    if (ru.maxrss <= 0) return null;
    const raw: u64 = @intCast(ru.maxrss);
    return if (builtin.os.tag.isDarwin()) raw else raw * 1024;
}

/// Growth allowed across the measured batch. Post-warm-up growth is a few MB of DS1 cache for
/// files the warm-up seeds happened not to touch; the leak this guards against costs ~85 MB per
/// act, so at the default 5-act batch the failure signal is ~425 MB against this budget.
const budget_bytes: u64 = 64 * 1024 * 1024;

const Path = enum {
    /// The per-room collision builder the fidelity gates drive.
    room_collision,
    /// What drlg-server calls per request.
    act_full,

    fn label(p: Path) []const u8 {
        return switch (p) {
            .room_collision => "generateActRoomCollision",
            .act_full => "generateActFull",
        };
    }
};

/// One batch: `acts` acts, walking acts I..V and wrapping to the next seed. Results are freed
/// immediately — nothing is retained, so anything that survives is accumulation.
fn runBatch(ctx: *lib.Ctx, gpa: std.mem.Allocator, path: Path, first_seed: u32, acts: usize) usize {
    var done: usize = 0;
    var seed = first_seed;
    var act_no: i32 = 0;
    while (done < acts) {
        switch (path) {
            .room_collision => {
                if (lib.generateActRoomCollision(ctx, gpa, act_no, seed, .nightmare)) |r| {
                    var res = r;
                    res.deinit(gpa);
                    done += 1;
                } else |_| {}
            },
            .act_full => {
                if (lib.generateActFull(ctx, gpa, act_no, seed, .nightmare, .{})) |r| {
                    var res = r;
                    res.deinit(gpa);
                    done += 1;
                } else |_| {}
            },
        }
        act_no += 1;
        if (act_no == 5) {
            act_no = 0;
            seed += 1;
        }
    }
    return done;
}

fn checkPath(ctx: *lib.Ctx, gpa: std.mem.Allocator, path: Path, acts: usize) bool {
    const warmed = runBatch(ctx, gpa, path, 1, acts);
    const before = peakRssBytes().?;
    const measured = runBatch(ctx, gpa, path, 1001, acts);
    const after = peakRssBytes().?;

    const grew = after -| before;
    const ok = grew <= budget_bytes;
    std.debug.print("{s:<26} {d} warm-up acts -> peak {d} MB | {d} measured acts -> peak {d} MB | grew {d} MB (budget {d} MB) {s}\n", .{
        path.label(),             warmed, before >> 20, measured, after >> 20, grew >> 20, budget_bytes >> 20,
        if (ok) "OK" else "FAIL",
    });
    if (!ok) std.debug.print(
        "  generating {d} more acts cost {d} MB of peak RSS. Act generation must be bounded — one Ctx\n" ++
            "  serves requests for the process lifetime, so per-act growth is a leak.\n",
        .{ measured, grew >> 20 },
    );
    return ok;
}

/// Returns the process exit status: 0 when every path stayed inside the budget.
pub fn run(gpa: std.mem.Allocator, acts: usize, traced: bool) u8 {
    if (peakRssBytes() == null) {
        std.debug.print("memcheck: no RSS accounting on this target\n", .{});
        return 0;
    }

    var ctx = lib.Ctx.init(gpa) catch {
        std.debug.print("memcheck: Ctx.init failed\n", .{});
        return 2;
    };
    defer ctx.deinit();

    // Leak detection on the generation allocator comes free, so take it: memcheck then covers both
    // an allocator-visible leak and the RSS growth no allocator can see. `--traced` is the same
    // allocator with `std.testing.allocator`'s 10-frame capture, which is what made act generation
    // cost ~85 MB per act; it exists so this check can be demonstrated to fail.
    var plain: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    var stacky: std.heap.DebugAllocator(.{ .stack_trace_frames = 10, .resize_stack_traces = true }) = .init;
    const out = if (traced) stacky.allocator() else plain.allocator();

    std.debug.print("memcheck: {d}-act batches{s}\n", .{ acts, if (traced) " (--traced: stack-trace-capturing allocator)" else "" });
    var ok = checkPath(&ctx, out, .room_collision, acts);
    if (!checkPath(&ctx, out, .act_full, acts)) ok = false;

    const leaked = if (traced) stacky.deinit() else plain.deinit();
    if (leaked == .leak) {
        std.debug.print("memcheck: FAIL — the generation allocator reports surviving allocations\n", .{});
        ok = false;
    }
    std.debug.print("memcheck: {s}\n", .{if (ok) "PASS" else "FAIL"});
    return if (ok) 0 else 1;
}
