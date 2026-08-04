//! Load an act and time real routes across it, so "quick" is a measurement rather than a claim.
//!
//!     zig build bench -Doptimize=ReleaseFast -- <seed> <act 1..5> [fromLevel toLevel]
//!     zig build bench -Doptimize=ReleaseFast -- <seed> <act> near <level> <dist> <count>
//!     zig build bench -Doptimize=ReleaseFast -- <seed> <act> run  <fromLevel> <toLevel>
//!     zig build bench -Doptimize=ReleaseFast -- <seed> 4     chaos
//!     zig build bench -Doptimize=ReleaseFast -- <seed> game            (all five acts, start to end)
//!
//! With two extra level ids it instead times that one CROSS-LEVEL route repeatedly, which is the
//! interesting number for a bot: a whole journey, not a single level's traverse.
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

/// Distance between consecutive nodes of a route, accumulated per leg (a level transition is not a
/// step, so pairs never span two legs).
///
/// For a walk the nodes are compressed corners, so the mean says how long the straight runs are.
/// For teleport every pair IS a cast, and the mean Chebyshev against the 50-subtile gate is a
/// direct efficiency measure: well under 50 means casts are being wasted.
const Spans = struct {
    pairs: usize = 0,
    clear_sum: f64 = 0,
    clear_n: usize = 0,
    hug: usize = 0,
    euclid_sum: f64 = 0,
    cheb_sum: f64 = 0,
    cheb_max: i32 = 0,
    at_gate: usize = 0, // pairs within 2 subtiles of the gate — a maximal cast

    /// Mean clearance of the cells a route's waypoints sit on, plus how many touch a wall. This is
    /// what wall aversion is supposed to move.
    fn addClearance(self: *Spans, world: *pf.World, r: *const pf.Route, mask: u16) !void {
        for (r.legs) |leg| {
            const lv = world.level(leg.level) orelse continue;
            const pm = try lv.passMap(mask);
            const cl = pm.clearance();
            for (leg.moves) |m| {
                if (!pm.inBounds(m.x, m.y)) continue;
                const c = cl[pm.index(m.x, m.y)];
                self.clear_sum += @floatFromInt(c);
                self.clear_n += 1;
                if (c <= 1) self.hug += 1;
            }
        }
    }

    fn add(self: *Spans, r: *const pf.Route, gate: i32) void {
        for (r.legs) |leg| {
            var i: usize = 1;
            while (i < leg.moves.len) : (i += 1) {
                const dx = leg.moves[i].x - leg.moves[i - 1].x;
                const dy = leg.moves[i].y - leg.moves[i - 1].y;
                const cheb = @max(@as(i32, @intCast(@abs(dx))), @as(i32, @intCast(@abs(dy))));
                const fx: f64 = @floatFromInt(dx);
                const fy: f64 = @floatFromInt(dy);
                self.pairs += 1;
                self.euclid_sum += @sqrt(fx * fx + fy * fy);
                self.cheb_sum += @floatFromInt(cheb);
                self.cheb_max = @max(self.cheb_max, cheb);
                if (cheb >= gate - 2) self.at_gate += 1;
            }
        }
    }

    /// Print every hop of a route as `euclid/cheb`, one line per leg. This is the raw material the
    /// aggregate above summarises — useful for eyeballing whether the search is stringing maximal
    /// hops together or dribbling out short ones.
    fn dump(r: *const pf.Route, label: []const u8) void {
        for (r.legs) |leg| {
            if (leg.moves.len < 2) continue;
            print("      {s} [lvl {d}]:", .{ label, u(leg.level) });
            var i: usize = 1;
            while (i < leg.moves.len) : (i += 1) {
                const dx = leg.moves[i].x - leg.moves[i - 1].x;
                const dy = leg.moves[i].y - leg.moves[i - 1].y;
                const cheb = @max(@as(i32, @intCast(@abs(dx))), @as(i32, @intCast(@abs(dy))));
                const fx: f64 = @floatFromInt(dx);
                const fy: f64 = @floatFromInt(dy);
                print(" {d:.0}/{d}", .{ @sqrt(fx * fx + fy * fy), u(cheb) });
            }
            print("\n", .{});
        }
    }

    fn report(self: *const Spans, gate: i32, teleporting: bool) void {
        if (self.pairs == 0) return;
        const n: f64 = @floatFromInt(self.pairs);
        print("    spans: {d} hops, mean {d:.1} subtiles ({d:.1} chebyshev), max cheb {d}", .{
            self.pairs, self.euclid_sum / n, self.cheb_sum / n, u(self.cheb_max),
        });
        if (self.clear_n != 0) {
            print(" | clearance mean {d:.2}, {d}% of nodes touch a wall", .{
                self.clear_sum / @as(f64, @floatFromInt(self.clear_n)),
                self.hug * 100 / self.clear_n,
            });
        }
        if (!teleporting) {
            // A walk has no per-step limit, so "how close to the gate" means nothing here — the
            // spans are just how long the compressed straight runs are.
            print("\n", .{});
            return;
        }
        // Every hop is a cast. Mean chebyshev against the gate is the efficiency: how much of the
        // legal reach each cast actually spends. max must never exceed the gate, or we emitted a
        // cast the server would reject outright.
        print(", gate {d}: mean uses {d:.0}% of it, {d}% of casts are maximal\n", .{
            u(gate),
            self.cheb_sum / n / @as(f64, @floatFromInt(gate)) * 100.0,
            self.at_gate * 100 / self.pairs,
        });
    }
};

/// Objects.txt rows named "Waypoint" — one per act sprite.
fn isWaypoint(id: i32) bool {
    return switch (id) {
        119, 145, 156, 157, 237, 238, 288, 323, 324, 398, 402, 429, 494, 496, 511 => true,
        else => false,
    };
}

/// The passable cell nearest a level's centre — a stable endpoint that exists on every level.
fn centreOf(alloc: std.mem.Allocator, lv: *pf.Level) !pf.Point {
    _ = alloc;
    const pm = try lv.passMap(pf.Colmask.player_path);
    return pf.grid.nearestPassable(pm, @divTrunc(lv.w, 2), @divTrunc(lv.h, 2), @max(lv.w, lv.h)) orelse
        error.NoPassableCell;
}

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
    const act_arg: []const u8 = args.next() orelse "1";
    const arg2_is_game = std.mem.eql(u8, act_arg, "game");
    const act_1based: i32 = if (arg2_is_game) 1 else try std.fmt.parseInt(i32, act_arg, 10);
    const act = act_1based - 1;
    const arg3: ?[]const u8 = args.next();
    const near_mode = arg3 != null and std.mem.eql(u8, arg3.?, "near");
    const run_mode = arg3 != null and std.mem.eql(u8, arg3.?, "run");
    const chaos_mode = arg3 != null and std.mem.eql(u8, arg3.?, "chaos");
    const objs_mode = arg3 != null and std.mem.eql(u8, arg3.?, "objs");
    const objs_level: i32 = if (objs_mode) try std.fmt.parseInt(i32, args.next() orelse "131", 10) else 0;
    const game_mode = arg2_is_game or (arg3 != null and std.mem.eql(u8, arg3.?, "game"));
    // `chaos spans` additionally lists every individual hop, not just the aggregate.
    var show_spans = false;
    const run_from: i32 = if (run_mode) try std.fmt.parseInt(i32, args.next() orelse "1", 10) else 0;
    const run_to: i32 = if (run_mode) try std.fmt.parseInt(i32, args.next() orelse "25", 10) else 0;
    const near_level: i32 = if (near_mode) try std.fmt.parseInt(i32, args.next() orelse "3", 10) else 0;
    const near_dist: i32 = if (near_mode) try std.fmt.parseInt(i32, args.next() orelse "120", 10) else 0;
    const near_count: usize = if (near_mode) try std.fmt.parseInt(usize, args.next() orelse "80", 10) else 0;
    const prof_mode = arg3 != null and std.mem.eql(u8, arg3.?, "prof");
    const chains_mode = arg3 != null and std.mem.eql(u8, arg3.?, "chains");
    const chains_from: i32 = if (chains_mode) try std.fmt.parseInt(i32, args.next() orelse "75", 10) else 0;
    const chains_to: i32 = if (chains_mode) try std.fmt.parseInt(i32, args.next() orelse "102", 10) else 0;
    const chains_count: u32 = if (chains_mode) try std.fmt.parseInt(u32, args.next() orelse "100", 10) else 0;
    const explicit = !near_mode and !run_mode and !chaos_mode and !game_mode and !objs_mode and
        !prof_mode and !chains_mode;
    const from_level: ?i32 = if (!explicit) null else if (arg3) |a| try std.fmt.parseInt(i32, a, 10) else null;
    const to_level: ?i32 = if (!explicit) null else if (args.next()) |a| try std.fmt.parseInt(i32, a, 10) else null;

    var ctx = try drlg.Ctx.init(gpa);
    defer ctx.deinit();

    // Level placement is seeded, so which levels end up edge-to-edge — and therefore which pairs
    // the engine's warp-connection sweep stitches — varies. This walks N seeds and prints the
    // level chain each one produces, to see how much the topology actually moves.
    if (chains_mode) {
        var chain: std.ArrayListUnmanaged(i32) = .empty;
        defer chain.deinit(gpa);
        var i: u32 = 0;
        while (i < chains_count) : (i += 1) {
            const s = seed +% i *% 0x9e3779b1;
            var w = pf.World.init(gpa, s, .normal);
            defer w.deinit();
            try w.loadAct(&ctx, act);
            chain.clearRetainingCapacity();
            print("0x{x:0>8}", .{s});
            if (w.levelRoute(chains_from, chains_to, &chain)) |_| {
                for (chain.items) |c| print(" {d}", .{u(c)});
            } else |e| {
                print(" FAIL {s}", .{@errorName(e)});
            }
            print("\n", .{});
        }
        return;
    }

    if (prof_mode) {
        drlg.prof.clock = &struct {
            fn f() i64 {
                return @intCast(monoNs());
            }
        }.f;
        drlg.prof.reset();
        var t = Timer.begin();
        var bare = try drlg.generateActFull(&ctx, gpa, act, seed, .normal, .{ .raw_collision = true });
        const bare_ns = t.read();
        bare.deinit(gpa);
        inline for (@typeInfo(drlg.prof.Phase).@"enum".fields) |f| {
            const v = drlg.prof.get(@enumFromInt(f.value));
            if (v != 0) print("    {s:<14}{d:7.1} ms\n", .{ f.name, @as(f64, @floatFromInt(v)) / 1e6 });
        }

        t.reset();
        var full = try drlg.generateActFull(&ctx, gpa, act, seed, .normal, .{ .room_links = true, .raw_collision = true });
        const gen_ns = t.read();
        var cells: usize = 0;
        for (full.levels) |lf| {
            if (lf.coll_w <= 0 or lf.coll_h <= 0) continue;
            const n: usize = @intCast(lf.coll_w * lf.coll_h);
            cells += n;
        }
        full.deinit(gpa);

        var t2 = Timer.begin();
        var w2 = pf.World.init(gpa, seed, .normal);
        try w2.loadAct(&ctx, act);
        const load_ns = t2.read();
        w2.deinit();

        const ms = struct {
            fn f(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / 1e6;
            }
        }.f;
        print("act {d}: {d} levels, {d} subtiles\n", .{ act_1based, full.levels.len, cells });
        print("  generateActFull   {d:7.1} ms  (no room_links: {d:.1} ms)\n", .{ ms(gen_ns), ms(bare_ns) });
        print("  World.loadAct     {d:7.1} ms\n", .{ms(load_ns)});
        print("  pathfinding layer {d:7.1} ms\n", .{ms(load_ns) - ms(gen_ns)});
        return;
    }

    var timer = Timer.begin();
    var world = pf.World.init(gpa, seed, .normal);
    defer world.deinit();
    if (game_mode) {
        for (0..5) |a| try world.loadAct(&ctx, @intCast(a));
    } else {
        try world.loadAct(&ctx, act);
    }
    const load_ns = timer.read();

    print("seed 0x{x} act {d}: {d} levels loaded in {d:.1} ms\n\n", .{
        seed, act_1based, world.levels.items.len, @as(f64, @floatFromInt(load_ns)) / 1e6,
    });
    // How much cross-level teleport this act actually offers: the engine links plenty of rooms
    // across levels, but only the pairs that ALSO land within the cast gate in world coordinates
    // are usable, and most warp destinations sit far away in that frame.
    {
        var links: usize = 0;
        var usable: usize = 0;
        for (world.levels.items) |*lv| {
            links += lv.links.len;
            for (world.levels.items) |*other| {
                if (other.id == lv.id) continue;
                if ((try pf.World.crossLevelCast(lv, other, .{})) != null) usable += 1;
            }
        }
        print("cross-level room links: {d}; level pairs a cast can bridge: {d}\n\n", .{ links, usable });
    }

    // Where each level of the act actually sits, and which neighbours it is geometrically adjacent
    // to. Separates "placed wrong" from "placed right but never stitched".
    if (objs_mode and objs_level == 0) {
        print("  lvl   origin(tiles)   size(tiles)   exits\n", .{});
        for (world.levels.items) |*lv| {
            print("  {d:3}  ({d:5},{d:5})  {d:4}x{d:<4}  ", .{
                u(lv.id), u(lv.origin_x), u(lv.origin_y), u(lv.tileW()), u(lv.tileH()),
            });
            for (lv.exits) |e| print("{d}({s}) ", .{ u(e.to_level), @tagName(e.kind) });
            print("\n", .{});
        }
        print("\n  geometric adjacency (bbox gap < 6 tiles on both axes = the seam rule):\n", .{});
        for (world.levels.items) |*a| {
            for (world.levels.items) |*b| {
                if (b.id <= a.id) continue;
                const ax1 = a.origin_x + a.tileW();
                const ay1 = a.origin_y + a.tileH();
                const bx1 = b.origin_x + b.tileW();
                const by1 = b.origin_y + b.tileH();
                const gx = @max(@as(i32, 0), @max(a.origin_x - bx1, b.origin_x - ax1));
                const gy = @max(@as(i32, 0), @max(a.origin_y - by1, b.origin_y - ay1));
                if (gx >= 6 or gy >= 6) continue;
                var linked = false;
                for (a.exits) |e| {
                    if (e.to_level == b.id) linked = true;
                }
                for (b.exits) |e| {
                    if (e.to_level == a.id) linked = true;
                }
                print("  {d:3} <-> {d:3}  gap {d},{d}  {s}\n", .{
                    u(a.id), u(b.id), u(gx), u(gy), if (linked) "linked" else "NOT STITCHED",
                });
            }
        }
        return;
    }

    // Every preset object on a level, with its Objects.txt name.
    if (objs_mode) {
        const lv = world.level(objs_level) orelse {
            print("level {d} not in this act\n", .{u(objs_level)});
            return;
        };
        const text = @import("d2-data").file("Objects");
        print("level {d} ({d}x{d}) preset objects:\n", .{ u(objs_level), u(lv.w), u(lv.h) });
        for (lv.presets) |unit| {
            if (unit.etype != 2) continue;
            // Find the Objects.txt row with this Id and print its Name + description.
            var lines = std.mem.splitScalar(u8, text, '\n');
            _ = lines.next();
            while (lines.next()) |line| {
                var cols = std.mem.splitScalar(u8, line, '\t');
                const name = cols.next() orelse continue;
                const desc = cols.next() orelse continue;
                const idtxt = cols.next() orelse continue;
                const id = std.fmt.parseInt(i32, std.mem.trim(u8, idtxt, "\r "), 10) catch continue;
                if (id != unit.txt_file_no) continue;
                print("  id {d:3}  ({d:4},{d:4})  {s:<22} {s}\n", .{
                    u(unit.txt_file_no), u(unit.x), u(unit.y), name, desc,
                });
                break;
            }
        }
        return;
    }

    // The whole game, start to end: can a character actually get from the Rogue Encampment to the
    // Worldstone Chamber? Every act loaded, so the level graph spans all of them.
    if (game_mode) {
        // Where each boss is actually FOUGHT. Baal is in the Throne of Destruction; the Worldstone
        // Chamber beyond it is where you go after he dies, through the portal he opens.
        const STAGES = [_]struct { to: i32, name: []const u8 }{
            .{ .to = 37, .name = "Andariel (Catacombs 4)" },
            .{ .to = 73, .name = "Duriel (Tal Rasha's Chamber)" },
            .{ .to = 102, .name = "Mephisto (Durance 3)" },
            .{ .to = 108, .name = "Diablo (Chaos Sanctum)" },
            .{ .to = 131, .name = "Baal (Throne of Destruction)" },
            .{ .to = 132, .name = "Worldstone Chamber (post-Baal)" },
        };
        // Probe the Act 5 chain link by link when it fails, so the break is named rather than
        // reported as a blanket "unreachable".
        const PROBES = [_][2]i32{
            .{ 73, 69 }, .{ 69, 46 }, .{ 46, 74 }, .{ 74, 54 }, .{ 54, 40 }, .{ 40, 75 },
            .{ 75, 76 }, .{ 76, 78 }, .{ 78, 79 }, .{ 79, 80 }, .{ 80, 81 }, .{ 81, 82 },
            .{ 82, 83 }, .{ 83, 100 }, .{ 100, 102 },
            .{ 108, 109 }, .{ 109, 110 }, .{ 110, 111 }, .{ 111, 112 }, .{ 112, 113 },
            .{ 113, 115 }, .{ 115, 117 }, .{ 117, 118 }, .{ 118, 120 }, .{ 120, 128 },
            .{ 128, 129 }, .{ 129, 130 }, .{ 130, 131 }, .{ 131, 132 },
        };
        print("{d} levels loaded across 5 acts in {d:.1} ms\n\n", .{
            world.levels.items.len, @as(f64, @floatFromInt(load_ns)) / 1e6,
        });

        var chain: std.ArrayListUnmanaged(i32) = .empty;
        defer chain.deinit(gpa);
        var stage_from: i32 = 1;
        var ok = true;
        for (STAGES) |st| {
            chain.clearRetainingCapacity();
            world.levelRoute(stage_from, st.to, &chain) catch |e| {
                print("  {s:<30} UNREACHABLE ({s})\n", .{ st.name, @errorName(e) });
                ok = false;
                stage_from = st.to;
                continue;
            };
            print("  {s:<30} {d:2} levels:", .{ st.name, chain.items.len });
            for (chain.items) |id| print(" {d}", .{u(id)});
            print("\n", .{});
            stage_from = st.to;
        }

        // Now actually PATH each stage, not just the level chain, and time the lot. This is the
        // number that matters for a bot: what does planning a whole playthrough cost.
        {
            print("\n  full path per stage (walk / teleport), centre to centre:\n", .{});
            var walk_total: u64 = 0;
            var tele_total: u64 = 0;
            var walk_moves: usize = 0;
            var tele_moves: usize = 0;
            var stage_start: i32 = 1;
            for (STAGES) |st| {
                const a = centreOf(gpa, world.level(stage_start) orelse continue) catch continue;
                const b = centreOf(gpa, world.level(st.to) orelse continue) catch continue;

                var wns: u64 = 0;
                var tns: u64 = 0;
                var wm: usize = 0;
                var tm: usize = 0;
                var walk_ok = false;
                var tele_ok = false;
                timer.reset();
                if (world.route(.{ .level = stage_start, .x = a.x, .y = a.y }, .{ .level = st.to, .x = b.x, .y = b.y }, .{})) |r| {
                    wns = timer.read();
                    var rr = r;
                    wm = rr.moveCount() - rr.legs.len;
                    rr.deinit();
                    walk_ok = true;
                } else |_| {}
                timer.reset();
                if (world.route(.{ .level = stage_start, .x = a.x, .y = a.y }, .{ .level = st.to, .x = b.x, .y = b.y }, .{ .teleport = true })) |r| {
                    tns = timer.read();
                    var rr = r;
                    tm = rr.moveCount() - rr.legs.len;
                    rr.deinit();
                    tele_ok = true;
                } else |_| {}

                walk_total += wns;
                tele_total += tns;
                walk_moves += wm;
                tele_moves += tm;
                // A route that FAILED is not a zero-length route. Say so, rather than printing
                // "0 steps 0.00 ms" and letting it read as instant success.
                if (!walk_ok or !tele_ok) {
                    print("    {s:<32} NO ROUTE (walk {s}, teleport {s})\n", .{
                        st.name,
                        if (walk_ok) "ok" else "failed",
                        if (tele_ok) "ok" else "failed",
                    });
                } else {
                    print("    {s:<32} {d:5} steps {d:8.2} ms  |  {d:5} casts {d:8.2} ms\n", .{
                        st.name, wm, @as(f64, @floatFromInt(wns)) / 1e6, tm, @as(f64, @floatFromInt(tns)) / 1e6,
                    });
                }
                stage_start = st.to;
            }
            print("    {s:<32} {d:5} steps {d:8.2} ms  |  {d:5} casts {d:8.2} ms\n", .{
                "WHOLE PLAYTHROUGH", walk_moves, @as(f64, @floatFromInt(walk_total)) / 1e6,
                tele_moves, @as(f64, @floatFromInt(tele_total)) / 1e6,
            });
        }

        // And the single end-to-end question.
        chain.clearRetainingCapacity();
        if (world.levelRoute(1, 132, &chain)) {
            var acts_seen: [6]bool = @splat(false);
            for (chain.items) |id| {
                const a: usize = if (id <= 39) 1 else if (id <= 74) 2 else if (id <= 102) 3 else if (id <= 108) 4 else 5;
                acts_seen[a] = true;
            }
            var n: usize = 0;
            for (acts_seen[1..]) |seen| {
                if (seen) n += 1;
            }
            print("\n  Rogue Encampment -> Worldstone Chamber: {d} levels, spanning {d}/5 acts\n", .{ chain.items.len, n });
        } else |e| {
            print("\n  Rogue Encampment -> Worldstone Chamber: UNREACHABLE ({s})\n", .{@errorName(e)});
            ok = false;
        }
        // Audit every level's Levels.txt Vis entries against the adjacency generation reports. A
        // Vis entry naming a level is the game saying "these two connect"; if generation produces
        // no exit for it, the level graph has a hole.
        {
            const text = @import("d2-data").file("Levels");
            var lines = std.mem.splitScalar(u8, text, '\n');
            const header = lines.next() orelse return;
            var idc: usize = 0;
            var visc: [8]usize = @splat(0);
            {
                var cols = std.mem.splitScalar(u8, header, '\t');
                var i: usize = 0;
                while (cols.next()) |c| : (i += 1) {
                    const nm = std.mem.trim(u8, c, "\r");
                    if (std.mem.eql(u8, nm, "Id")) idc = i;
                    for (0..8) |v| {
                        var buf: [8]u8 = undefined;
                        const want = std.fmt.bufPrint(&buf, "Vis{d}", .{v}) catch continue;
                        if (std.mem.eql(u8, nm, want)) visc[v] = i;
                    }
                }
            }
            var holes: usize = 0;
            var checked: usize = 0;
            print("\n  vis audit (Levels.txt says they connect, generation disagrees):\n", .{});
            while (lines.next()) |line| {
                if (std.mem.trim(u8, line, "\r \t").len == 0) continue;
                var cols = std.mem.splitScalar(u8, line, '\t');
                var i: usize = 0;
                var lid: i32 = -1;
                var vis: [8]i32 = @splat(0);
                while (cols.next()) |c| : (i += 1) {
                    const v = std.mem.trim(u8, c, "\r ");
                    if (i == idc) lid = std.fmt.parseInt(i32, v, 10) catch -1;
                    for (0..8) |k| {
                        if (visc[k] != 0 and i == visc[k]) vis[k] = std.fmt.parseInt(i32, v, 10) catch 0;
                    }
                }
                const lv = world.level(lid) orelse continue;
                for (vis) |dest| {
                    if (dest == 0 or dest == lid) continue;
                    if (world.level(dest) == null) continue;
                    checked += 1;
                    var found = false;
                    for (lv.exits) |e| {
                        if (e.to_level == dest) found = true;
                    }
                    // The other side counts too: the pair connects if either names the other.
                    if (!found) {
                        if (world.level(dest)) |dl| {
                            for (dl.exits) |e| {
                                if (e.to_level == lid) found = true;
                            }
                        }
                    }
                    if (!found) {
                        holes += 1;
                        print("    {d:3} -> {d:3}  no exit either way\n", .{ u(lid), u(dest) });
                    }
                }
            }
            print("    {d} of {d} Vis pairs have no adjacency\n", .{ holes, checked });
        }

        if (!ok) {
            print("\n  link probe:\n", .{});
            for (PROBES) |pr| {
                chain.clearRetainingCapacity();
                if (world.levelRoute(pr[0], pr[1], &chain)) {
                    print("    {d:3} -> {d:3}  ok ({d} levels)\n", .{ u(pr[0]), u(pr[1]), chain.items.len });
                } else |_| {
                    print("    {d:3} -> {d:3}  BROKEN\n", .{ u(pr[0]), u(pr[1]) });
                    for (pr) |lid| {
                        const lv = world.level(lid) orelse continue;
                        print("        level {d} exits ({d}):", .{ u(lid), lv.exits.len });
                        for (lv.exits) |e| print(" {d}({s})", .{ u(e.to_level), @tagName(e.kind) });
                        print("\n", .{});
                    }
                }
            }
        }
        return;
    }

    // The Chaos Sanctuary run, on the real preset positions: River of Flame waypoint, across into
    // the Sanctuary, then seal to seal to seal, and finally the star in the middle. This is the
    // single most-run route in the game and it is all long in-level paths, so it is the honest
    // worst case for a bot's pathfinding budget.
    if (chaos_mode) {
        const RIVER_OF_FLAME: i32 = 107;
        const CHAOS_SANCTUM: i32 = 108;
        const SEAL_IDS = [_]i32{ 392, 393, 394, 395, 396 };

        show_spans = (args.next() != null);
        const river = world.level(RIVER_OF_FLAME) orelse return;
        const chaos = world.level(CHAOS_SANCTUM) orelse return;

        // The waypoint object on the River of Flame. Objects.txt has one "Waypoint" row per act
        // sprite, so take whichever one this level actually placed.
        var wp: ?pf.Point = null;
        for (river.presets) |unit| {
            if (unit.etype == 2 and isWaypoint(unit.txt_file_no)) {
                wp = .{ .x = unit.x, .y = unit.y };
                break;
            }
        }

        var seals: std.ArrayListUnmanaged(pf.Point) = .empty;
        defer seals.deinit(gpa);
        for (SEAL_IDS) |sid| try chaos.findObjects(sid, &seals, gpa);

        print("River of Flame waypoint: {s}; seals found in Chaos: {d}\n\n", .{
            if (wp == null) "NOT FOUND" else "found", seals.items.len,
        });
        if (wp == null or seals.items.len == 0) return;

        // The star is the pentagram in the middle; the five seals sit around it, so their centroid
        // lands on it closely enough to measure with.
        var sx: i64 = 0;
        var sy: i64 = 0;
        for (seals.items) |p| {
            sx += p.x;
            sy += p.y;
        }
        const cpm = try chaos.passMap(pf.Colmask.player_path);
        const star = pf.grid.nearestPassable(
            cpm,
            @intCast(@divTrunc(sx, @as(i64, @intCast(seals.items.len)))),
            @intCast(@divTrunc(sy, @as(i64, @intCast(seals.items.len)))),
            200,
        ) orelse return;

        const Variant = struct { name: []const u8, opts: pf.Options };
        for ([_]Variant{
            .{ .name = "walk (no aversion)", .opts = .{ .wall_aversion = .{ .desired = 0 } } },
            .{ .name = "walk (aversion 3/2)", .opts = .{} },
            .{ .name = "walk (aversion 5/3)", .opts = .{ .wall_aversion = .{ .desired = 5, .weight = 3 } } },
            // The engine's own gate, then what conventional bots use. d2bs-style movers cap a
            // RADIAL distance, which is the disk inscribed in the engine's square — so the same
            // number costs casts even before you shave it down to 40 or 39 for safety.
            .{ .name = "tele cheb 50 (engine)", .opts = .{ .teleport = true, .teleport_max_cast = 50 } },
            .{ .name = "tele cheb 40", .opts = .{ .teleport = true, .teleport_max_cast = 40 } },
            .{ .name = "tele cheb 39", .opts = .{ .teleport = true, .teleport_max_cast = 39 } },
            .{ .name = "tele radial 50", .opts = .{ .teleport = true, .teleport_max_cast = 50, .teleport_metric = .euclidean } },
            .{ .name = "tele radial 40 (d2bs)", .opts = .{ .teleport = true, .teleport_max_cast = 40, .teleport_metric = .euclidean } },
            .{ .name = "tele radial 39", .opts = .{ .teleport = true, .teleport_max_cast = 39, .teleport_metric = .euclidean } },
        }) |v| {
            var total: u64 = 0;
            var moves: usize = 0;
            var spans: Spans = .{};
            var legs: usize = 0;
            const gate = v.opts.teleport_max_cast orelse pf.teleport.ENGINE_MAX_CAST;
            print("  {s}:\n", .{v.name});

            // Leg 1: waypoint -> Chaos Sanctuary (crosses the level boundary).
            timer.reset();
            var r0 = try world.route(
                .{ .level = RIVER_OF_FLAME, .x = wp.?.x, .y = wp.?.y },
                .{ .level = CHAOS_SANCTUM, .x = star.x, .y = star.y },
                v.opts,
            );
            var ns = timer.read();
            total += ns;
            moves += r0.moveCount();
            print("    wp -> chaos star   {d:4} moves  {d:8.1} us\n", .{ r0.moveCount(), @as(f64, @floatFromInt(ns)) / 1e3 });
            spans.add(&r0, gate);
            try spans.addClearance(&world, &r0, v.opts.mask);
            legs += r0.legs.len;
            if (show_spans) Spans.dump(&r0, "wp->star");
            r0.deinit();

            // Then star -> each seal -> back, which is how the run is actually walked.
            var prev = star;
            for (seals.items, 0..) |seal, i| {
                const target = pf.grid.nearestPassable(cpm, seal.x, seal.y, 40) orelse continue;
                timer.reset();
                var r = world.route(
                    .{ .level = CHAOS_SANCTUM, .x = prev.x, .y = prev.y },
                    .{ .level = CHAOS_SANCTUM, .x = target.x, .y = target.y },
                    v.opts,
                ) catch continue;
                ns = timer.read();
                total += ns;
                moves += r.moveCount();
                print("    -> seal {d}          {d:4} moves  {d:8.1} us\n", .{ i + 1, r.moveCount(), @as(f64, @floatFromInt(ns)) / 1e3 });
                spans.add(&r, gate);
                try spans.addClearance(&world, &r, v.opts.mask);
                legs += r.legs.len;
                if (show_spans) Spans.dump(&r, "->seal");
                r.deinit();
                prev = target;
            }

            timer.reset();
            var rb = try world.route(
                .{ .level = CHAOS_SANCTUM, .x = prev.x, .y = prev.y },
                .{ .level = CHAOS_SANCTUM, .x = star.x, .y = star.y },
                v.opts,
            );
            ns = timer.read();
            total += ns;
            moves += rb.moveCount();
            print("    -> star (Diablo)   {d:4} moves  {d:8.1} us\n", .{ rb.moveCount(), @as(f64, @floatFromInt(ns)) / 1e3 });
            spans.add(&rb, gate);
            try spans.addClearance(&world, &rb, v.opts.mask);
            legs += rb.legs.len;
            if (show_spans) Spans.dump(&rb, "->star");
            rb.deinit();

            // A leg's first move is where you already stand, not a step — so the number of actual
            // steps (casts, when teleporting) is moves minus one PER LEG, not minus one overall.
            print("    TOTAL   {d:4} nodes over {d} legs = {d:3} {s}   {d:8.3} ms\n", .{
                moves, legs, moves - legs, if (v.opts.teleport) "casts" else "steps",
                @as(f64, @floatFromInt(total)) / 1e6,
            });
            spans.report(gate, v.opts.teleport);
            print("\n", .{});
        }
        return;
    }

    // Run mode: what a bot's pathfinding load actually looks like over a whole run.
    //
    // A bot does not compute one route and follow it blindly. It re-paths constantly, because
    // monsters block and knock it around, and it breaks off to engage things it passes. So the
    // realistic question is not "how long is one route" but "how much CPU does a full run cost".
    // This walks the route, re-pathing to the goal every few waypoints, and fires a short
    // engage-that-monster query at each step along the way.
    if (run_mode) {
        var prng = std.Random.DefaultPrng.init(0xB07);
        const rnd = prng.random();

        const start = try centreOf(gpa, world.level(run_from) orelse {
            print("level {d} not in this act\n", .{u(run_from)});
            return;
        });
        const goal = try centreOf(gpa, world.level(run_to) orelse {
            print("level {d} not in this act\n", .{u(run_to)});
            return;
        });

        const Variant = struct { name: []const u8, opts: pf.Options };
        for ([_]Variant{
            .{ .name = "walk", .opts = .{} },
            .{ .name = "teleport", .opts = .{ .teleport = true } },
        }) |v| {
            var queries: usize = 0;
            var total_ns: u64 = 0;
            var worst_ns: u64 = 0;
            var steps: usize = 0;

            timer.reset();
            var full = try world.route(
                .{ .level = run_from, .x = start.x, .y = start.y },
                .{ .level = run_to, .x = goal.x, .y = goal.y },
                v.opts,
            );
            total_ns += timer.read();
            queries += 1;
            const legs = full.legs.len;
            const plan_moves = full.moveCount();

            for (full.legs) |leg| {
                const lv = world.level(leg.level) orelse continue;
                const pm = try lv.passMap(v.opts.mask);
                const leg_end = if (leg.moves.len != 0) leg.moves[leg.moves.len - 1] else continue;

                for (leg.moves, 0..) |m, mi| {
                    steps += 1;

                    // Engage something nearby: pick a reachable point within ~120 subtiles and
                    // path to it. This is the query a bot fires most often.
                    const ang = rnd.float(f32) * 6.2831853;
                    const tx = m.x + @as(i32, @intFromFloat(@cos(ang) * 120.0));
                    const ty = m.y + @as(i32, @intFromFloat(@sin(ang) * 120.0));
                    if (pm.inBounds(tx, ty) and pm.passable(tx, ty)) {
                        timer.reset();
                        if (world.route(
                            .{ .level = leg.level, .x = m.x, .y = m.y },
                            .{ .level = leg.level, .x = tx, .y = ty },
                            v.opts,
                        )) |r2| {
                            const ns = timer.read();
                            var rr = r2;
                            rr.deinit();
                            total_ns += ns;
                            worst_ns = @max(worst_ns, ns);
                            queries += 1;
                        } else |_| {}
                    }

                    // Re-path to the end of this leg every few waypoints: the bot has drifted.
                    if (mi % 3 != 0) continue;
                    timer.reset();
                    if (world.route(
                        .{ .level = leg.level, .x = m.x, .y = m.y },
                        .{ .level = leg.level, .x = leg_end.x, .y = leg_end.y },
                        v.opts,
                    )) |r3| {
                        const ns = timer.read();
                        var rr = r3;
                        rr.deinit();
                        total_ns += ns;
                        worst_ns = @max(worst_ns, ns);
                        queries += 1;
                    } else |_| {}
                }
            }
            full.deinit();

            print("  {s:<9} {d:2} legs, {d:3} planned moves | {d:4} queries  {d:8.1} ms total  mean {d:6.1} us  worst {d:7.1} us\n", .{
                v.name, legs, plan_moves, queries,
                @as(f64, @floatFromInt(total_ns)) / 1e6,
                @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(queries)) / 1e3,
                @as(f64, @floatFromInt(worst_ns)) / 1e3,
            });
        }
        return;
    }

    // Short-range mode: many independent queries of a bounded length inside ONE level. This is the
    // shape a bot actually generates — walk to that monster, that chest, that waypoint — and it is
    // a very different profile from a cross-act journey.
    if (near_mode) {
        const lv = world.level(near_level) orelse {
            print("level {d} not in this act\n", .{u(near_level)});
            return;
        };
        const pm = try lv.passMap(pf.Colmask.player_path);
        const comp = try pm.components(gpa);

        // Deterministic pairs: walk the grid with a fixed-seed PRNG, keep pairs that are roughly
        // `near_dist` apart AND in the same connected region (an unreachable pair measures the
        // component rejection, not the search).
        // Sample from the PASSABLE cells of the largest region, not from the bounding box. A cave
        // is ~1.5% passable, so drawing coordinates uniformly and rejecting almost never finds two
        // valid endpoints — the sampler has to know where the floor is.
        var best_label: u32 = 0;
        {
            const counts = try gpa.alloc(u32, pm.comp_count + 1);
            defer gpa.free(counts);
            @memset(counts, 0);
            for (comp) |c| counts[c] += 1;
            best_label = 1;
            for (counts[1..], 1..) |n, id| {
                if (n > counts[best_label]) best_label = @intCast(id);
            }
        }
        var floor: std.ArrayListUnmanaged(u32) = .empty;
        defer floor.deinit(gpa);
        for (comp, 0..) |c, i| {
            if (c == best_label) try floor.append(gpa, @intCast(i));
        }
        if (floor.items.len < 2) {
            print("level {d} has no walkable region to sample\n", .{u(near_level)});
            return;
        }

        var prng = std.Random.DefaultPrng.init(0xD2D2D2);
        const rnd = prng.random();
        var pairs: std.ArrayListUnmanaged([2]pf.Point) = .empty;
        defer pairs.deinit(gpa);
        const tol = @max(@divTrunc(near_dist, 8), 4); // accept within ~12% of the requested span
        var attempts: usize = 0;
        while (pairs.items.len < near_count and attempts < near_count * 20000) : (attempts += 1) {
            const ia = floor.items[rnd.intRangeLessThan(usize, 0, floor.items.len)];
            const ib = floor.items[rnd.intRangeLessThan(usize, 0, floor.items.len)];
            const w: u32 = @intCast(pm.w);
            const a = pf.Point{ .x = @intCast(ia % w), .y = @intCast(ia / w) };
            const b = pf.Point{ .x = @intCast(ib % w), .y = @intCast(ib / w) };
            const dx: f64 = @floatFromInt(a.x - b.x);
            const dy: f64 = @floatFromInt(a.y - b.y);
            const d = @sqrt(dx * dx + dy * dy);
            if (@abs(d - @as(f64, @floatFromInt(near_dist))) > @as(f64, @floatFromInt(tol))) continue;
            try pairs.append(gpa, .{ a, b });
        }

        print("level {d} ({d}x{d}), {d} random pairs ~{d} subtiles apart\n\n", .{
            u(near_level), u(lv.w), u(lv.h), pairs.items.len, u(near_dist),
        });
        if (pairs.items.len == 0) return;

        const Variant = struct { name: []const u8, opts: pf.Options };
        for ([_]Variant{
            .{ .name = "walk", .opts = .{} },
            .{ .name = "teleport", .opts = .{ .teleport = true } },
        }) |v| {
            var total: u64 = 0;
            var worst: u64 = 0;
            var moves: usize = 0;
            var ok: usize = 0;
            for (pairs.items) |pr| {
                timer.reset();
                var r = world.route(
                    .{ .level = near_level, .x = pr[0].x, .y = pr[0].y },
                    .{ .level = near_level, .x = pr[1].x, .y = pr[1].y },
                    v.opts,
                ) catch continue;
                const ns = timer.read();
                defer r.deinit();
                total += ns;
                worst = @max(worst, ns);
                moves += r.moveCount();
                ok += 1;
            }
            if (ok == 0) continue;
            const mean_us = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(ok)) / 1e3;
            print("  {s:<10} {d:3} routes  mean {d:8.1} us  worst {d:8.1} us  avg {d:5.1} moves\n", .{
                v.name, ok, mean_us, @as(f64, @floatFromInt(worst)) / 1e3,
                @as(f64, @floatFromInt(moves)) / @as(f64, @floatFromInt(ok)),
            });
        }
        return;
    }

    // Explicit endpoints: time that journey instead of sweeping every level.
    if (from_level) |fl| {
        const tl = to_level.?;
        const src = f: {
            const lv = world.level(fl) orelse {
                print("level {d} not in this act\n", .{u(fl)});
                return;
            };
            break :f try centreOf(gpa, lv);
        };
        const dst = f: {
            const lv = world.level(tl) orelse {
                print("level {d} not in this act\n", .{u(tl)});
                return;
            };
            break :f try centreOf(gpa, lv);
        };

        var chain: std.ArrayListUnmanaged(i32) = .empty;
        defer chain.deinit(gpa);
        try world.levelRoute(fl, tl, &chain);
        print("route {d} -> {d} via {d} levels: ", .{ u(fl), u(tl), chain.items.len });
        for (chain.items) |id| print("{d} ", .{u(id)});
        print("\n\n", .{});

        const Variant = struct { name: []const u8, opts: pf.Options };
        const variants = [_]Variant{
            .{ .name = "walk", .opts = .{} },
            .{ .name = "teleport", .opts = .{ .teleport = true } },
            .{ .name = "teleport+cross", .opts = .{ .teleport = true, .teleport_across_levels = true } },
        };
        const reps = 20;
        for (variants) |v| {
            // One warm run first: the first query per level pays for its passability bitset and
            // component labels, and that is a load cost, not a query cost.
            var warm = try world.route(
                .{ .level = fl, .x = src.x, .y = src.y },
                .{ .level = tl, .x = dst.x, .y = dst.y },
                v.opts,
            );
            const moves = warm.moveCount();
            warm.deinit();

            timer.reset();
            for (0..reps) |_| {
                var r = try world.route(
                    .{ .level = fl, .x = src.x, .y = src.y },
                    .{ .level = tl, .x = dst.x, .y = dst.y },
                    v.opts,
                );
                r.deinit();
            }
            const ns = timer.read() / reps;
            print("  {s:<16} {d:5} moves   {d:8.3} ms/route\n", .{ v.name, moves, @as(f64, @floatFromInt(ns)) / 1e6 });
        }
        return;
    }

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
