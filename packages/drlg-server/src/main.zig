//! Native, speed-focused HTTP server for the DeadlyBossMods-shaped map JSON.
//!
//! One Ctx per worker THREAD (game tables loaded once at worker startup, then reused
//! for every request that worker handles), a shared listening socket, and the native
//! `d2-drlg` `renderJson` serializer per request. Generation mutates a Ctx's table gen
//! cache, so Ctx is NOT shared across threads — each worker owns its own; the DRLG pool
//! allocator + table pointer are thread-local, so per-worker generation is race-free.
//!
//!   GET /api/render?seed=<u32>&acts=<1..5>&difficulty=<0|1|2>  -> the act's DBM JSON
//!   GET /health                                                -> 200 "ok"

const std = @import("std");
const drlg = @import("d2-drlg");

const Io = std.Io;
const net = std.Io.net;

const default_port: u16 = 8080;

pub fn main(init: std.process.Init) !void {
    // `io` (a shared, thread-safe std.Io.Threaded) and `gpa` come from the runtime. gpa is
    // shared across workers for their long-lived Ctx tables + per-request arenas; generation
    // itself runs on the DRLG thread-local pool, so per-worker work is race-free.
    const io = init.io;
    const gpa = init.gpa;

    // CLI (--port / --threads) overrides env (PORT / THREADS) overrides defaults.
    var cli_port: ?u16 = null;
    var cli_threads: ?usize = null;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (it.next()) |v| cli_port = std.fmt.parseInt(u16, v, 10) catch null;
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (it.next()) |v| cli_threads = std.fmt.parseInt(usize, v, 10) catch null;
        }
    }
    const port = cli_port orelse envInt(u16, init.environ_map, "PORT") orelse default_port;
    const want = cli_threads orelse envInt(usize, init.environ_map, "THREADS") orelse fallbackThreads();

    const addr = net.IpAddress.parseIp4("0.0.0.0", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        std.debug.print("drlg-server: listen on :{d} failed: {s}\n", .{ port, @errorName(e) });
        return e;
    };
    defer server.deinit(io);

    // Pre-warm the lib's lazy process-global caches (DT1 index, Objects.txt, preset tables,
    // DS1 blobs) ONCE, single-threaded, before any worker runs. Generation only writes those
    // on first build; after warmup every concurrent gen just READS them, so per-worker gens
    // (own Ctx + own thread-local pool) never race on shared build state.
    prewarm(gpa) catch |e| std.debug.print("drlg-server: prewarm failed: {s}\n", .{@errorName(e)});

    std.debug.print("drlg-server: listening on http://0.0.0.0:{d} ({d} workers)\n", .{ port, want });

    // Spawn want-1 workers; run one worker loop on the main thread too.
    var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
    defer threads.deinit(gpa);
    var i: usize = 1;
    while (i < want) : (i += 1) {
        const t = std.Thread.spawn(.{}, workerLoop, .{ gpa, io, &server }) catch |e| {
            std.debug.print("drlg-server: spawn worker failed: {s}\n", .{@errorName(e)});
            break;
        };
        try threads.append(gpa, t);
    }
    workerLoop(gpa, io, &server);
    for (threads.items) |t| t.join();
}

/// Build every lazy process-global generation cache once (all five acts), so workers only
/// ever read them concurrently. Uses a throwaway Ctx + arena, freed here.
fn prewarm(gpa: std.mem.Allocator) !void {
    var ctx = try drlg.Ctx.init(gpa);
    defer ctx.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var act: i32 = 0;
    while (act < 5) : (act += 1) {
        // renderJson's output is owned by the passed allocator (the arena here);
        // arena.reset reclaims it — do NOT free it with gpa (invalid free).
        _ = try drlg.renderJson(&ctx, arena.allocator(), 0, act, .normal);
        _ = arena.reset(.retain_capacity);
    }
}

fn envInt(comptime T: type, env: *std.process.Environ.Map, key: []const u8) ?T {
    const v = env.get(key) orelse return null;
    return std.fmt.parseInt(T, v, 10) catch null;
}

fn fallbackThreads() usize {
    const n = std.Thread.getCpuCount() catch return 4;
    return @min(@max(n, 1), 16);
}

/// One worker: owns a Ctx (tables loaded once here) and services connections off the
/// shared listener until the process exits.
fn workerLoop(gpa: std.mem.Allocator, io: Io, server: *net.Server) void {
    var ctx = drlg.Ctx.init(gpa) catch |e| {
        std.debug.print("drlg-server: worker Ctx.init failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer ctx.deinit();

    while (true) {
        const stream = server.accept(io) catch |e| switch (e) {
            error.SocketNotListening => return, // shutdown
            else => continue,
        };
        serveConnection(gpa, io, stream, &ctx);
    }
}

/// Serve one TCP connection: HTTP keep-alive loop until the client closes or errors.
fn serveConnection(gpa: std.mem.Allocator, io: Io, stream: net.Stream, ctx: *drlg.Ctx) void {
    defer stream.close(io);
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    var http_server = std.http.Server.init(&sr.interface, &sw.interface);

    while (http_server.reader.state == .ready) {
        var request = http_server.receiveHead() catch return;
        handleRequest(gpa, ctx, &request) catch return;
    }
}

const json_ct: std.http.Header = .{ .name = "content-type", .value = "application/json" };
const text_ct: std.http.Header = .{ .name = "content-type", .value = "text/plain" };

fn handleRequest(gpa: std.mem.Allocator, ctx: *drlg.Ctx, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = pathOf(target);

    if (std.mem.eql(u8, path, "/health")) {
        return request.respond("ok", .{ .extra_headers = &.{text_ct} });
    }
    if (!std.mem.eql(u8, path, "/api/render")) {
        return request.respond("not found\n", .{ .status = .not_found });
    }

    const params = parseRenderParams(queryOf(target)) catch {
        return request.respond("bad request: invalid params\n", .{ .status = .bad_request });
    };

    // Per-request arena: renderJson's output + its internal generation scratch. Freed here.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // `&level=<levelNo>` renders ONLY that level (single-element `levels` array — cheap: it
    // skips generating the act's other 38 levels); without it the whole act is rendered.
    const body = blk: {
        if (params.level) |lid| {
            break :blk drlg.renderLevelJson(ctx, arena.allocator(), params.seed, params.act_no, lid, params.diff) catch {
                return request.respond("render failed\n", .{ .status = .internal_server_error });
            };
        }
        break :blk drlg.renderJson(ctx, arena.allocator(), params.seed, params.act_no, params.diff) catch {
            return request.respond("render failed\n", .{ .status = .internal_server_error });
        };
    };
    return request.respond(body, .{ .extra_headers = &.{json_ct} });
}

const RenderParams = struct { seed: u32, act_no: i32, diff: drlg.Difficulty, level: ?i32 = null };

fn parseRenderParams(query: []const u8) !RenderParams {
    var seed: u32 = 0;
    var acts: u32 = 1;
    var diff_n: u32 = 0;
    var level: ?i32 = null;
    if (getParam(query, "seed")) |v| seed = try std.fmt.parseInt(u32, v, 10);
    if (getParam(query, "acts")) |v| acts = try std.fmt.parseInt(u32, v, 10);
    if (getParam(query, "difficulty")) |v| diff_n = try std.fmt.parseInt(u32, v, 10);
    if (getParam(query, "level")) |v| level = try std.fmt.parseInt(i32, v, 10);
    if (acts < 1 or acts > 5) return error.BadParam;
    const diff: drlg.Difficulty = switch (diff_n) {
        0 => .normal,
        1 => .nightmare,
        2 => .hell,
        else => return error.BadParam,
    };
    return .{ .seed = seed, .act_no = @intCast(acts - 1), .diff = diff, .level = level };
}

fn pathOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}
fn queryOf(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[q + 1 ..];
    return "";
}

/// First value of `key` in a `k=v&k=v` query string (no percent-decoding — params are ints).
fn getParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}
