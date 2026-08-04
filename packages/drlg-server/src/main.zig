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

// Native libdeflate collision-deflate. The server links libdeflate (+libc), so it can swap
// the pure-Zig `std.compress.flate` compressor the library uses by default for a C one. The
// library + wasm build never see this: it is injected as `drlg.DeflateFn` only from here.
// Level 1 on real act CollMaps: 1.4 GB/s vs zlib level 1's 0.9 GB/s, output 36% smaller.
const deflate_level: c_int = 1;
const Compressor = opaque {};
extern "c" fn libdeflate_alloc_compressor(compression_level: c_int) ?*Compressor;
extern "c" fn libdeflate_zlib_compress(c: *Compressor, in: [*]const u8, in_nbytes: usize, out: [*]u8, out_nbytes_avail: usize) usize;
extern "c" fn libdeflate_zlib_compress_bound(c: ?*Compressor, in_nbytes: usize) usize;
extern "c" fn libdeflate_gzip_compress(c: *Compressor, in: [*]const u8, in_nbytes: usize, out: [*]u8, out_nbytes_avail: usize) usize;
extern "c" fn libdeflate_gzip_compress_bound(c: ?*Compressor, in_nbytes: usize) usize;

// std.time.Timer/Instant/std.time.nanoTimestamp are gone in this Zig, and std.posix has no
// clock_gettime wrapper here — but the binary links libc, so pull the C clock_gettime in
// directly. std.posix.CLOCK is the platform enum (right constant on both macOS and Linux).
extern "c" fn clock_gettime(clk_id: std.posix.clockid_t, tp: *std.posix.timespec) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

/// Monotonic microseconds — for latency deltas (immune to wall-clock jumps).
fn monoUs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

/// Monotonic nanoseconds — the clock the drlg lib's phase timers borrow (it links no libc of
/// its own). Installed in `main`; `GET /api/prof` reads and resets the accumulated totals.
fn monoNs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}

/// Wall-clock unix milliseconds — for the log line's "ts" field.
fn wallMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = clock_gettime(std.posix.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Build one line fully in a stack buffer and emit it with a SINGLE write() to stderr (fd 2)
/// so concurrent workers never interleave. Line stays well under PIPE_BUF, so the write is atomic.
fn logLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [768]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, out.ptr, out.len);
}

/// One structured JSON access-log line per HTTP request, shaped for Loki `| json`. Latency is
/// integer microseconds in "us" (whole-act renders are ~hundreds of ms, but a single-level or
/// /health request is often sub-millisecond, so ms would round to 0 too often). Render params
/// are included only when `rp` is set (i.e. /api/render); `err` adds an "err" field on failures.
fn logReq(method: []const u8, path: []const u8, status: u16, bytes: usize, us: i64, rp: ?RenderParams, err: ?[]const u8) void {
    var extra_buf: [192]u8 = undefined;
    var extra: []const u8 = "";
    if (rp) |p| {
        const act1: i32 = p.act_no + 1;
        const dn: u8 = switch (p.diff) {
            .normal => 0,
            .nightmare => 1,
            .hell => 2,
        };
        const walk = if (p.include_walk) "true" else "false";
        extra = if (p.level) |lv|
            std.fmt.bufPrint(&extra_buf, ",\"seed\":{d},\"act\":{d},\"difficulty\":{d},\"level\":{d},\"walk\":{s}", .{ p.seed, act1, dn, lv, walk }) catch ""
        else
            std.fmt.bufPrint(&extra_buf, ",\"seed\":{d},\"act\":{d},\"difficulty\":{d},\"level\":null,\"walk\":{s}", .{ p.seed, act1, dn, walk }) catch "";
    }
    var err_buf: [160]u8 = undefined;
    var err_str: []const u8 = "";
    if (err) |e| err_str = std.fmt.bufPrint(&err_buf, ",\"err\":\"{s}\"", .{e}) catch "";
    logLine("{{\"ts\":{d},\"level\":\"info\",\"msg\":\"req\",\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"bytes\":{d},\"us\":{d}{s}{s}}}\n", .{ wallMs(), method, path, status, bytes, us, extra, err_str });
}

/// zlib-deflate `raw` (LE-u16 CollMap) into a fresh `alloc` slice, level 1 (Z_BEST_SPEED),
/// producing an rfc1950 zlib-container stream that inflates back to `raw` byte-for-byte —
/// the drop-in native `drlg.DeflateFn` for `renderJson`/`renderLevelJson`.
fn zlibDeflate(alloc: std.mem.Allocator, raw: []const u8) anyerror![]u8 {
    // Compress into a per-worker scratch buffer, then hand back only the bytes that were
    // actually produced. Compressing straight into `alloc` would put a bound-sized slab
    // (~raw.len, i.e. megabytes per level) into the request arena, which never shrinks a
    // returned slice — 40x the memory for the same result.
    const comp = zcomp orelse blk: {
        const c = libdeflate_alloc_compressor(deflate_level) orelse return error.DeflateInit;
        zcomp = c;
        break :blk c;
    };
    const bound = libdeflate_zlib_compress_bound(comp, raw.len);
    if (zbuf.len < bound) {
        if (zbuf.len != 0) std.heap.page_allocator.free(zbuf);
        zbuf = try std.heap.page_allocator.alloc(u8, bound);
    }
    const n = libdeflate_zlib_compress(comp, raw.ptr, raw.len, zbuf.ptr, zbuf.len);
    if (n == 0) return error.DeflateFailed;
    return alloc.dupe(u8, zbuf[0..n]);
}

/// Per-worker deflate state: one compressor (it holds internal match tables — allocating it
/// per level would cost more than the compression) and a scratch buffer grown to the largest
/// level seen. Both live for the worker's lifetime.
threadlocal var zcomp: ?*Compressor = null;
threadlocal var zbuf: []u8 = &.{};

/// The process-wide `Io`, so `zlibDeflateMany` can put a batch of levels on its thread pool.
var g_io: Io = undefined;

/// One level, compressed on whichever pool thread picks it up. The result is `smp_allocator`-
/// owned (thread-safe); `zlibDeflateMany` copies it into the request arena and frees it, since
/// that arena belongs to the requesting thread alone.
fn deflateTask(raw: []const u8) anyerror![]u8 {
    return zlibDeflate(std.heap.smp_allocator, raw);
}

/// `drlg.DeflateManyFn`: compress a batch of levels concurrently. Deflate is the biggest phase
/// of a whole-act render (up to 32 ms of a 62 ms act-2 request) and the levels are independent,
/// so the pool turns it into roughly one level's worth of wall-clock.
fn zlibDeflateMany(alloc: std.mem.Allocator, srcs: []const []const u8, dsts: [][]u8) anyerror!void {
    const Fut = std.Io.Future(anyerror![]u8);
    var futs: [16]Fut = undefined;
    var i: usize = 0;
    while (i < srcs.len) {
        // The last level of a batch runs here rather than on the pool: this thread would
        // otherwise just block on it.
        var n: usize = 0;
        while (n < futs.len and i + n + 1 < srcs.len) : (n += 1) {
            futs[n] = g_io.concurrent(deflateTask, .{srcs[i + n]}) catch break;
        }
        for (futs[0..n], 0..) |*f, k| {
            const bytes = try f.await(g_io);
            defer std.heap.smp_allocator.free(bytes);
            dsts[i + k] = try alloc.dupe(u8, bytes);
        }
        i += n;
        if (i < srcs.len) {
            dsts[i] = try zlibDeflate(alloc, srcs[i]);
            i += 1;
        }
    }
}

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
    // After prewarm, so the one-time table builds don't land in the phase totals.
    drlg.prof.clock = &monoNs;
    g_io = io;
    drlg.deflate_many = &zlibDeflateMany;

    logLine("{{\"level\":\"info\",\"msg\":\"listening\",\"port\":{d},\"workers\":{d}}}\n", .{ port, want });

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
        _ = try drlg.renderJson(&ctx, arena.allocator(), 0, act, .normal, zlibDeflate, false);
        _ = arena.reset(.retain_capacity);
    }
}

fn envInt(comptime T: type, env: *std.process.Environ.Map, key: []const u8) ?T {
    const v = env.get(key) orelse return null;
    return std.fmt.parseInt(T, v, 10) catch null;
}

// Default worker count when neither --threads nor THREADS is set. Each worker owns a full
// Ctx (the game tables, ~3-4 MB) AND, while serving, one per-request arena that for a whole-act
// render holds the generation scratch + the 0.7-1 MB JSON body. Peak RSS therefore scales with
// the worker count: N workers => up to N concurrent whole-act arenas + N Ctx copies. On a big
// host `getCpuCount()` reports every node core (16+), so the old `min(cpu, 16)` spun up 16
// table-loading workers and let 16 large arenas coexist, blowing past a small pod memory cap
// (OOM-kill under concurrent whole-act traffic — even a 256Mi cap still OOMs at 16). This service
// is I/O-light (a whole act is ~0.2s of CPU), so cap the auto default low to bound memory; a
// deployment that wants more can still raise it explicitly via THREADS / --threads.
fn fallbackThreads() usize {
    const n = std.Thread.getCpuCount() catch return 4;
    return @min(@max(n, 1), 4);
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
const gzip_ce: std.http.Header = .{ .name = "content-encoding", .value = "gzip" };

fn acceptsGzip(request: *std.http.Server.Request) bool {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding") and
            std.mem.indexOf(u8, h.value, "gzip") != null) return true;
    }
    return false;
}

/// gzip the response body. The act JSON is ~855 KB of which most is repeated room/preset
/// structure, so it compresses to about a third — and at level 1 libdeflate does that in ~2 ms
/// against the ~150 ms the uncompressed body spends on the wire. Returns the original slice if
/// compression would not help (it never grows the response).
fn gzipBody(alloc: std.mem.Allocator, body: []const u8) []const u8 {
    const comp = zcomp orelse blk: {
        const c = libdeflate_alloc_compressor(deflate_level) orelse return body;
        zcomp = c;
        break :blk c;
    };
    const bound = libdeflate_gzip_compress_bound(comp, body.len);
    const buf = alloc.alloc(u8, bound) catch return body;
    const n = libdeflate_gzip_compress(comp, body.ptr, body.len, buf.ptr, buf.len);
    if (n == 0 or n >= body.len) return body;
    return buf[0..n];
}

fn handleRequest(gpa: std.mem.Allocator, ctx: *drlg.Ctx, request: *std.http.Server.Request) !void {
    const start = monoUs();
    const method = @tagName(request.head.method);
    const target = request.head.target;
    const path = pathOf(target);

    if (std.mem.eql(u8, path, "/health")) {
        // k8s liveness/readiness probes hit this every few seconds; do NOT log it (it would
        // drown the access log). Everything else is still logged below.
        const body = "ok";
        return request.respond(body, .{ .extra_headers = &.{text_ct} });
    }
    if (std.mem.eql(u8, path, "/api/prof")) {
        // Cumulative per-phase nanoseconds since the last read; reading resets them, so a
        // benchmark can bracket a run. Only meaningful with --threads 1 (the totals are a
        // process-wide sum, so concurrent requests interleave into the same buckets).
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.writeByte('{') catch {};
        inline for (@typeInfo(drlg.prof.Phase).@"enum".fields, 0..) |f, i| {
            w.print("{s}\"{s}\":{d}", .{ if (i == 0) "" else ",", f.name, drlg.prof.get(@enumFromInt(f.value)) }) catch {};
        }
        w.writeAll("}\n") catch {};
        drlg.prof.reset();
        return request.respond(w.buffered(), .{ .extra_headers = &.{json_ct} });
    }
    if (!std.mem.eql(u8, path, "/api/render")) {
        const body = "not found\n";
        const res = request.respond(body, .{ .status = .not_found });
        logReq(method, path, 404, body.len, monoUs() - start, null, null);
        return res;
    }

    const params = parseRenderParams(queryOf(target)) catch {
        const body = "bad request: invalid params\n";
        const res = request.respond(body, .{ .status = .bad_request });
        logReq(method, path, 400, body.len, monoUs() - start, null, "invalid params");
        return res;
    };

    // Per-request arena: renderJson's output + its internal generation scratch. Freed here.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // `&level=<levelNo>` renders ONLY that level (single-element `levels` array — cheap: it
    // skips generating the act's other 38 levels); without it the whole act is rendered.
    const body = blk: {
        if (params.level) |lid| {
            break :blk drlg.renderLevelJson(ctx, arena.allocator(), params.seed, params.act_no, lid, params.diff, zlibDeflate, params.include_walk) catch {
                const b = "render failed\n";
                const res = request.respond(b, .{ .status = .internal_server_error });
                logReq(method, path, 500, b.len, monoUs() - start, params, "render failed");
                return res;
            };
        }
        break :blk drlg.renderJson(ctx, arena.allocator(), params.seed, params.act_no, params.diff, zlibDeflate, params.include_walk) catch {
            const b = "render failed\n";
            const res = request.respond(b, .{ .status = .internal_server_error });
            logReq(method, path, 500, b.len, monoUs() - start, params, "render failed");
            return res;
        };
    };
    const t_gz = drlg.prof.begin();
    const sent: []const u8 = if (acceptsGzip(request)) gzipBody(arena.allocator(), body) else body;
    drlg.prof.end(.gzip, t_gz);
    const hdrs: []const std.http.Header = if (sent.ptr == body.ptr) &.{json_ct} else &.{ json_ct, gzip_ce };
    const res = request.respond(sent, .{ .extra_headers = hdrs });
    logReq(method, path, 200, sent.len, monoUs() - start, params, null);
    return res;
}

const RenderParams = struct { seed: u32, act_no: i32, diff: drlg.Difficulty, level: ?i32 = null, include_walk: bool = false };

fn parseRenderParams(query: []const u8) !RenderParams {
    var seed: u32 = 0;
    var acts: u32 = 1;
    var diff_n: u32 = 0;
    var level: ?i32 = null;
    var include_walk = false;
    if (getParam(query, "seed")) |v| seed = try std.fmt.parseInt(u32, v, 10);
    if (getParam(query, "acts")) |v| acts = try std.fmt.parseInt(u32, v, 10);
    if (getParam(query, "difficulty")) |v| diff_n = try std.fmt.parseInt(u32, v, 10);
    if (getParam(query, "level")) |v| level = try std.fmt.parseInt(i32, v, 10);
    // `?walk=true` (or 1) adds the pather walk grid + exits per level; default off keeps the
    // response DBM-byte-identical.
    if (getParam(query, "walk")) |v| include_walk = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    if (acts < 1 or acts > 5) return error.BadParam;
    const diff: drlg.Difficulty = switch (diff_n) {
        0 => .normal,
        1 => .nightmare,
        2 => .hell,
        else => return error.BadParam,
    };
    return .{ .seed = seed, .act_no = @intCast(acts - 1), .diff = diff, .level = level, .include_walk = include_walk };
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
