//! Load an act and time real routes across it, so "quick" is a measurement rather than a claim.
//!
//!     zig build bench -Doptimize=ReleaseFast -- <seed> <act 1..5>
//!
//! Endpoints are the two extremes of each level's LARGEST connected region, so every route is a
//! genuine corner-to-corner traverse rather than a lucky short hop — and none of them fail for the
//! trivial reason that an arbitrary coordinate landed in rock.

const std = @import("std");
const drlg = @import("d2-drlg");
const pf = @import("lib.zig");

const print = std.debug.print;

/// This std prints a sign for every signed integer, which turns a table of ids and sizes into
/// "+280x+200". Everything printed below is non-negative, so widen it to unsigned first.
fn u(v: i32) u32 {
    return @intCast(v);
}

// This std has no `time.Timer` in a libc-free configuration, and libd2 stays libc-free — so the
// bench (which does link libc, being a native tool) pulls in the C monotonic clock directly, the
// same way drlg-server does.
extern "c" fn clock_gettime(clk_id: std.posix.clockid_t, tp: *std.posix.timespec) c_int;

fn monoNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Timer = struct {
    start: u64,

    fn begin() Timer {
        return .{ .start = monoNs() };
    }

    fn read(self: *const Timer) u64 {
        return monoNs() - self.start;
    }

    fn reset(self: *Timer) void {
        self.start = monoNs();
    }
};

/// First and last passable cell of the level's largest connected region, in row-major order.
fn extremes(alloc: std.mem.Allocator, lv: *pf.Level, mask: u16) !?[2]pf.Point {
    const pm = try lv.passMap(mask);
    const comp = try pm.components(alloc);
    if (pm.comp_count == 0) return null;

    const counts = try alloc.alloc(u32, pm.comp_count + 1);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (comp) |c| counts[c] += 1;

    // counts[0] is the impassable label, which is usually the majority of a level — start the
    // scan at 1 so it cannot win.
    var best: u32 = 1;
    for (counts[1..], 1..) |n, id| {
        if (n > counts[best]) best = @intCast(id);
    }

    var first: ?usize = null;
    var last: usize = 0;
    for (comp, 0..) |c, i| {
        if (c != best) continue;
        if (first == null) first = i;
        last = i;
    }
    const f = first orelse return null;
    const w: usize = @intCast(pm.w);
    return [2]pf.Point{
        .{ .x = @intCast(f % w), .y = @intCast(f / w) },
        .{ .x = @intCast(last % w), .y = @intCast(last / w) },
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const seed: u32 = if (args.next()) |a| try std.fmt.parseInt(u32, a, 0) else 0x13572468;
    const act_1based: i32 = if (args.next()) |a| try std.fmt.parseInt(i32, a, 10) else 1;
    const act = act_1based - 1;

    var ctx = try drlg.Ctx.init(gpa);
    defer ctx.deinit();

    var timer = Timer.begin();
    var world = pf.World.init(gpa, seed, .normal);
    defer world.deinit();
    try world.loadAct(&ctx, act);
    const load_ns = timer.read();

    print("seed 0x{x} act {d}: {d} levels loaded in {d:.1} ms\n\n", .{
        seed, act_1based, world.levels.items.len, @as(f64, @floatFromInt(load_ns)) / 1e6,
    });
    print("  lvl      size    walk moves        ms  |  tele casts      ms\n", .{});

    var walk_total: u64 = 0;
    var walk_n: usize = 0;
    var walk_max: u64 = 0;
    var tele_total: u64 = 0;
    var tele_n: usize = 0;

    for (world.levels.items) |*lv| {
        const ends = (try extremes(gpa, lv, pf.Colmask.player_path)) orelse continue;
        const from = pf.Pos{ .level = lv.id, .x = ends[0].x, .y = ends[0].y };
        const to = pf.Pos{ .level = lv.id, .x = ends[1].x, .y = ends[1].y };

        print("  {d:3}  {d:4}x{d:<4}  ", .{ u(lv.id), u(lv.w), u(lv.h) });

        timer.reset();
        if (world.route(from, to, .{})) |r| {
            const ns = timer.read();
            var rr = r;
            defer rr.deinit();
            walk_total += ns;
            walk_max = @max(walk_max, ns);
            walk_n += 1;
            print("{d:11} {d:9.3}  | ", .{ rr.moveCount(), @as(f64, @floatFromInt(ns)) / 1e6 });
        } else |err| {
            print("{s:>11} {s:>9}  | ", .{ @errorName(err), "" });
        }

        timer.reset();
        if (world.route(from, to, .{ .teleport = true })) |r| {
            const ns = timer.read();
            var rr = r;
            defer rr.deinit();
            tele_total += ns;
            tele_n += 1;
            print("{d:11} {d:7.3}\n", .{ rr.moveCount() -| 1, @as(f64, @floatFromInt(ns)) / 1e6 });
        } else |err| {
            print("{s:>11}\n", .{@errorName(err)});
        }
    }

    if (walk_n != 0) print("\nwalk: {d} routes, mean {d:.3} ms, worst {d:.3} ms\n", .{
        walk_n,
        @as(f64, @floatFromInt(walk_total)) / @as(f64, @floatFromInt(walk_n)) / 1e6,
        @as(f64, @floatFromInt(walk_max)) / 1e6,
    });
    if (tele_n != 0) print("tele: {d} routes, mean {d:.3} ms\n", .{
        tele_n, @as(f64, @floatFromInt(tele_total)) / @as(f64, @floatFromInt(tele_n)) / 1e6,
    });
}
