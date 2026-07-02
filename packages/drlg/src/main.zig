const std = @import("std");
const rng = @import("rng.zig");
const tables = @import("tables.zig");
const oracle = @import("oracle.zig");
const verify = @import("verify.zig");
const dtables = @import("drlg/tables.zig");
const dpool = @import("drlg/pool.zig");
const fogmem = @import("d2-fog").memory;
const presettables = @import("drlg/presettables.zig");
const drlglib = @import("lib.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const cmd = args.next() orelse "help";

    if (std.mem.eql(u8, cmd, "rng")) {
        const seed_val = std.fmt.parseInt(u32, args.next() orelse "0", 0) catch 0;
        var s = rng.Seed.fromValue(seed_val);
        std.debug.print("seed {d} -> first 8 rolls (mod 100):\n", .{seed_val});
        for (0..8) |i| std.debug.print("  [{d}] {d}\n", .{ i, s.pick(100) });
        return;
    }

    if (std.mem.eql(u8, cmd, "level")) {
        const id = std.fmt.parseInt(i64, args.next() orelse "1", 10) catch 1;
        var tb = try tables.Tables.load(gpa);
        defer tb.deinit();
        const lv = tb.level(id) orelse {
            std.debug.print("no level {d}\n", .{id});
            return;
        };
        std.debug.print("level {d} \"{s}\" act={d} drlgType={s} sizeX={d} sizeY={d}\n", .{
            lv.id, lv.name, lv.act, @tagName(lv.drlg_type), lv.size_x, lv.size_y,
        });
        return;
    }

    if (std.mem.eql(u8, cmd, "bench")) {
        // bench <seed> <diff 0-2> <act 0-4> [iters] — time full-act DRLG generation
        // (produces per-room collision, like d2mapapi's GetMaps output).
        const seed = std.fmt.parseInt(u32, args.next() orelse "0", 0) catch 0;
        const diff_n = std.fmt.parseInt(u8, args.next() orelse "0", 10) catch 0;
        const act_no = std.fmt.parseInt(i32, args.next() orelse "0", 10) catch 0;
        const iters = std.fmt.parseInt(u32, args.next() orelse "50", 10) catch 50;
        const diff: drlglib.Difficulty = @enumFromInt(diff_n);
        var ctx = try drlglib.Ctx.init(gpa);
        defer ctx.deinit();
        // No internal timer (this std strips Timer/clock_gettime): run `iters` full-act
        // generations so the caller can wall-clock the process (shell `time`), and
        // diff two iter counts to cancel the one-time Ctx.init + table-load cost.
        var nlevels: usize = 0;
        var checksum: u64 = 0;
        var i: u32 = 0;
        while (i < iters) : (i += 1) {
            var a = std.heap.ArenaAllocator.init(gpa);
            defer a.deinit();
            var r = try drlglib.generateActCollisionAll(&ctx, a.allocator(), act_no, seed, diff);
            nlevels = r.levels.len;
            checksum +%= r.levels.len;
            r.deinit(a.allocator());
        }
        std.debug.print("bench: act {d} seed {d} diff {d} | {d} levels/act | {d} iters done | chk {d}\n", .{ act_no, seed, diff_n, nlevels, iters, checksum });
        return;
    }

    if (std.mem.eql(u8, cmd, "verify-seeds-recon")) {
        // Drives the recon->Zig TRANSFORM closure (src/drlg/*) via
        // verify.tallyLevelsRecon and prints a cross-seed scoreboard. JSONL input
        // is split into per-seed blocks by `drlg_seed` markers.
        const path = args.next() orelse {
            std.debug.print("usage: d2-drlg verify-seeds-recon <golden.jsonl> [threads]\n", .{});
            return;
        };
        // Optional 2nd arg: worker thread count (0/absent => one per CPU).
        const threads_arg: usize = if (args.next()) |a| (std.fmt.parseInt(usize, a, 10) catch 0) else 0;
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        std.debug.print("reading {s}...\n", .{path});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024 * 1024));
        defer gpa.free(bytes);

        // Per-worker tables are loaded below once the thread count is known (each
        // worker mutates its own file cache during generation).

        // Block-split by drlg_seed markers + dedup (identical to verify-seeds).
        const SeedBlock = struct { seed: u32, diff: u8, start: usize, end: usize };
        var blocks: std.ArrayListUnmanaged(SeedBlock) = .empty;
        defer blocks.deinit(gpa);
        var line_iter = std.mem.splitScalar(u8, bytes, '\n');
        var pos: usize = 0;
        var cur_seed: ?u32 = null;
        var cur_diff: u8 = 0;
        var cur_start: usize = 0;
        while (line_iter.next()) |line| {
            const line_end = pos + line.len + 1;
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (std.mem.startsWith(u8, trimmed, "{") and std.mem.indexOf(u8, trimmed, "\"drlg_seed\"") != null) {
                if (cur_seed) |s| try blocks.append(gpa, .{ .seed = s, .diff = cur_diff, .start = cur_start, .end = pos });
                var parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch {
                    pos = line_end;
                    continue;
                };
                defer parsed.deinit();
                const seed_v = parsed.value.object.get("seed") orelse {
                    pos = line_end;
                    continue;
                };
                cur_seed = switch (seed_v) {
                    .integer => |n| @intCast(n),
                    else => 0,
                };
                // Optional `diff` (0/1/2) on the marker; absent => Normal.
                cur_diff = if (parsed.value.object.get("diff")) |d| switch (d) {
                    .integer => |n| @intCast(@min(n, 2)),
                    else => 0,
                } else 0;
                cur_start = line_end;
            }
            pos = line_end;
        }
        if (cur_seed) |s| try blocks.append(gpa, .{ .seed = s, .diff = cur_diff, .start = cur_start, .end = bytes.len });

        var seen = std.AutoHashMapUnmanaged(u32, usize).empty;
        defer seen.deinit(gpa);
        for (blocks.items, 0..) |b, i| try seen.put(gpa, b.seed, i);
        std.debug.print("found {d} unique seeds across {d} blocks\n", .{ seen.count(), blocks.items.len });

        // Flatten the unique-seed set into a work list, then fan out across worker
        // threads. Each seed is independent (its own pDrlg + pool arena), so the
        // only shared state is the read-only file bytes + LvlTables; gpa is the
        // page_allocator (thread-safe) and dpool.allocator is thread-local.
        var work: std.ArrayListUnmanaged(SeedBlock) = .empty;
        defer work.deinit(gpa);
        {
            var seed_it = seen.iterator();
            while (seed_it.next()) |entry| try work.append(gpa, blocks.items[entry.value_ptr.*]);
        }

        const Worker = struct {
            // inputs
            bytes: []const u8,
            dtb: *dtables.LvlTables,
            tb: *tables.Tables,
            work: []const SeedBlock,
            base: usize, // index into `work` this worker starts at
            stride: usize, // total worker count (round-robin partition)
            gpa: std.mem.Allocator,
            // outputs
            rt: verify.ReconTally = .{},
            dev_rt: verify.ReconTally = .{},
            eval_rt: verify.ReconTally = .{},
            n_eval: usize = 0,
            n_seeds: usize = 0,
            results: std.ArrayListUnmanaged(verify.LevelResult) = .empty,

            fn run(self: *@This()) void {
                // Fog pool: faithful replica of the engine's segregated-slab pool.
                // Holds the DS1 file cache (pLvlSub.pDrlgFile points into it across
                // seeds) + gen temporaries; grows on demand and is freed wholesale
                // when the worker exits (deinit == FreeMemoryPool).
                var pool = fogmem.PoolManager.init(self.gpa);
                defer pool.deinit();
                dpool.allocator = pool.allocator(); // thread-local
                // Scratch arena: parse + tally allocations, reset per seed. This keeps
                // page_allocator (mmap-per-call) off the hot path — without it 16
                // threads serialise on the kernel VM lock and barely scale.
                var scratch = std.heap.ArenaAllocator.init(self.gpa);
                defer scratch.deinit();
                const sa = scratch.allocator();

                var i = self.base;
                while (i < self.work.len) : (i += self.stride) {
                    defer _ = scratch.reset(.retain_capacity);
                    const block = self.work[i];
                    const chunk = self.bytes[block.start..block.end];
                    const levels = oracle.parseJsonl(sa, chunk) catch continue;
                    var seed_results: std.ArrayListUnmanaged(verify.LevelResult) = .empty;
                    const one = verify.tallyLevelsRecon(sa, levels, self.dtb, self.tb, block.seed, block.diff, &seed_results) catch continue;
                    self.rt.add(one);
                    if ((block.seed *% 2654435761) % 5 == 0) {
                        self.eval_rt.add(one);
                        self.n_eval += 1;
                    } else self.dev_rt.add(one);
                    self.n_seeds += 1;
                    // Copy the POD per-level results into the worker's persistent list
                    // (the scratch list is freed on the next reset).
                    self.results.appendSlice(self.gpa, seed_results.items) catch {};
                }
            }
        };

        // Worker thread count from the optional CLI arg (0/absent => one per CPU).
        const n_threads = @max(1, @min(work.items.len, if (threads_arg == 0) (std.Thread.getCpuCount() catch 1) else threads_arg));

        // Load ONE table set per worker, single-threaded, so the lazy globals
        // (presettables) and per-row file cache (pDrlgFile) are isolated per worker
        // — generation then mutates only its own tables. g_lvl_tables is thread-local.
        const tbs = try gpa.alloc(tables.Tables, n_threads);
        defer gpa.free(tbs);
        const dtbs = try gpa.alloc(dtables.LvlTables, n_threads);
        defer gpa.free(dtbs);
        // Pre-warm the lazy preset monster/object tables (a process-global cache)
        // single-threaded so workers only read it.
        _ = presettables.ensureLoaded();
        for (tbs, dtbs) |*t, *d| {
            t.* = try tables.Tables.load(gpa);
            d.* = try dtables.LvlTables.load(gpa);
        }
        defer for (tbs, dtbs) |*t, *d| {
            t.deinit();
            d.deinit();
        };

        const workers = try gpa.alloc(Worker, n_threads);
        defer gpa.free(workers);
        for (workers, 0..) |*w, wi| w.* = .{
            .bytes = bytes,
            .dtb = &dtbs[wi],
            .tb = &tbs[wi],
            .work = work.items,
            .base = wi,
            .stride = n_threads,
            .gpa = gpa,
        };
        std.debug.print("running {d} seeds across {d} threads...\n", .{ work.items.len, n_threads });

        const threads = try gpa.alloc(std.Thread, n_threads);
        defer gpa.free(threads);
        for (threads, workers) |*t, *w| t.* = try std.Thread.spawn(.{}, Worker.run, .{w});
        for (threads) |t| t.join();

        // Merge per-worker tallies + results.
        var rt: verify.ReconTally = .{}; // transform
        var dev_rt: verify.ReconTally = .{};
        var eval_rt: verify.ReconTally = .{};
        var n_eval: usize = 0;
        var n_seeds: usize = 0;
        var all_results: std.ArrayListUnmanaged(verify.LevelResult) = .empty;
        defer all_results.deinit(gpa);
        for (workers) |*w| {
            rt.add(w.rt);
            dev_rt.add(w.dev_rt);
            eval_rt.add(w.eval_rt);
            n_eval += w.n_eval;
            n_seeds += w.n_seeds;
            try all_results.appendSlice(gpa, w.results.items);
            w.results.deinit(gpa);
        }

        const pct = struct {
            fn p(ok: usize, tot: usize) f64 {
                if (tot == 0) return 0.0;
                return @as(f64, @floatFromInt(ok)) / @as(f64, @floatFromInt(tot)) * 100.0;
            }
        };
        const r = rt.total.rooms;
        std.debug.print(
            \\
            \\=== TRANSFORM CROSS-SEED SCOREBOARD ({d} seeds, {d} levels) ===
            \\byte-exact: {d}/{d} levels ({d:.1}%)
            \\per-field over {d} rooms:
            \\  coord {d:.1}%  seed {d:.1}%  def {d:.1}%  file {d:.1}%  ntype {d:.1}%  nptype {d:.1}%  adj {d:.1}%
            \\room-count mismatches: {d}
            \\per-type byte-exact: maze {d}/{d}  preset {d}/{d}  wilderness {d}/{d} (stubbed)
            \\
        , .{
            n_seeds,                      rt.total.levels,
            rt.total.byte_exact,          rt.total.levels,
            pct.p(rt.total.byte_exact, rt.total.levels),
            r,                            pct.p(rt.total.coord, r),
            pct.p(rt.total.seed_ok, r),   pct.p(rt.total.def, r),
            pct.p(rt.total.file, r),      pct.p(rt.total.ntype, r),
            pct.p(rt.total.nptype, r),    pct.p(rt.total.adj, r),
            rt.total.count_mismatch,
            rt.maze_exact,                rt.maze_levels,
            rt.preset_exact,              rt.preset_levels,
            rt.wild_exact,                rt.wild_levels,
        });

        const dr = dev_rt.total.rooms;
        const er = eval_rt.total.rooms;
        std.debug.print(
            \\--- TRANSFORM HOLDOUT (DEV optimised; EVAL = ~20% check) ---
            \\DEV  ({d} seeds): byte-exact {d:.1}%  coord {d:.1}%  seed {d:.1}%  def {d:.1}%
            \\EVAL ({d} seeds): byte-exact {d:.1}%  coord {d:.1}%  seed {d:.1}%  def {d:.1}%
            \\
        , .{
            n_seeds - n_eval,
            pct.p(dev_rt.total.byte_exact, dev_rt.total.levels), pct.p(dev_rt.total.coord, dr), pct.p(dev_rt.total.seed_ok, dr), pct.p(dev_rt.total.def, dr),
            n_eval,
            pct.p(eval_rt.total.byte_exact, eval_rt.total.levels), pct.p(eval_rt.total.coord, er), pct.p(eval_rt.total.seed_ok, er), pct.p(eval_rt.total.def, er),
        });

        // Worst NON-empty levels by coord match ratio (skip the stubbed wilderness /
        // unsupported-maze levels that produce 0 rooms — they're known gaps).
        std.mem.sort(verify.LevelResult, all_results.items, {}, struct {
            fn lt(_: void, a: verify.LevelResult, b: verify.LevelResult) bool {
                const ar = if (a.rooms_total == 0) 1.0 else @as(f64, @floatFromInt(a.rooms_ok)) / @as(f64, @floatFromInt(a.rooms_total));
                const br = if (b.rooms_total == 0) 1.0 else @as(f64, @floatFromInt(b.rooms_ok)) / @as(f64, @floatFromInt(b.rooms_total));
                return ar < br;
            }
        }.lt);
        std.debug.print("transform: NON-byte-exact generated levels (coord ratio, then first non-exact):\n", .{});
        var shown: usize = 0;
        for (all_results.items) |lr| {
            if (lr.byte_exact or lr.rooms_total == 0 or lr.rooms_ok == 0) continue;
            std.debug.print("  level {d}: {d}/{d} rooms coord-ok  byte-exact={}\n", .{ lr.id, lr.rooms_ok, lr.rooms_total, lr.byte_exact });
            shown += 1;
            if (shown >= 8) break;
        }

        // Level-pick diagnosis: per preset-level histogram of golden vs port
        // nPickedFile (the jail-exit variant). Only counts levels whose golden
        // carries a real lvlPick (i.e. the golden was captured with the field).
        // A mismatch here on Courtyard 1 (27) explains barracks (28) divergence,
        // since GenerateBarracksLayout reads the courtyard's pick. Invisible in the
        // byte-compare because the file-pick advances the seed by one either way.
        {
            const MAXID2 = 256;
            var pick_seen = [_]u32{0} ** MAXID2;
            var pick_bad = [_]u32{0} ** MAXID2;
            var ex_golden = [_]i32{0} ** MAXID2;
            var ex_port = [_]i32{0} ** MAXID2;
            var any_pick = false;
            for (all_results.items) |lr| {
                if (lr.golden_lvl_pick == oracle.LVL_PICK_NONE) continue;
                const id: usize = if (lr.id >= 0 and lr.id < MAXID2) @intCast(lr.id) else continue;
                any_pick = true;
                pick_seen[id] += 1;
                if (lr.golden_lvl_pick != lr.port_lvl_pick) {
                    if (pick_bad[id] == 0) {
                        ex_golden[id] = lr.golden_lvl_pick;
                        ex_port[id] = lr.port_lvl_pick;
                    }
                    pick_bad[id] += 1;
                }
            }
            if (any_pick) {
                std.debug.print("\n=== LEVEL-PICK DIAGNOSIS (golden vs port nPickedFile) ===\n", .{});
                for (0..MAXID2) |id| {
                    if (pick_seen[id] == 0) continue;
                    if (pick_bad[id] == 0) continue; // only show divergent levels
                    std.debug.print("  level {d:>3}: pick-mismatch {d}/{d}  (e.g. golden={d} port={d})\n", .{ id, pick_bad[id], pick_seen[id], ex_golden[id], ex_port[id] });
                }
            }
        }

        // Failure manifest: per level-id histogram of non-byte-exact levels, split
        // into ZERO-room (untransformed/stub gap) vs PARTIAL (real divergence to
        // root-cause). Sorted by count so the biggest gaps lead the worklist.
        const MAXID = 256;
        var hist_zero = [_]u32{0} ** MAXID;
        var hist_partial = [_]u32{0} ** MAXID;
        for (all_results.items) |lr| {
            if (lr.byte_exact) continue;
            const id: usize = if (lr.id >= 0 and lr.id < MAXID) @intCast(lr.id) else continue;
            if (lr.rooms_total == 0) hist_zero[id] += 1 else hist_partial[id] += 1;
        }
        std.debug.print("\n=== FAILURE MANIFEST (non-byte-exact by level id) ===\n", .{});
        std.debug.print("  id: zero-room(stub/untransformed) + partial(real divergence)\n", .{});
        const IdCounts = struct {
            z: *const [MAXID]u32,
            p: *const [MAXID]u32,
            fn gt(ctx: @This(), a: usize, b: usize) bool {
                return (ctx.z[a] + ctx.p[a]) > (ctx.z[b] + ctx.p[b]);
            }
        };
        var order: [MAXID]usize = undefined;
        for (0..MAXID) |k| order[k] = k;
        std.mem.sort(usize, &order, IdCounts{ .z = &hist_zero, .p = &hist_partial }, IdCounts.gt);
        for (order) |id| {
            const z = hist_zero[id];
            const p = hist_partial[id];
            if (z == 0 and p == 0) continue;
            std.debug.print("  level {d:>3}: zero={d:<5} partial={d}\n", .{ id, z, p });
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "colldump")) {
        const tilegen = @import("drlg/tilegen.zig");
        const act_no = std.fmt.parseInt(i32, args.next() orelse "0", 10) catch 0;
        const seed = std.fmt.parseInt(u32, args.next() orelse "72", 0) catch 72;
        var ctx = try drlglib.Ctx.init(gpa);
        defer ctx.deinit();
        tilegen.g_lookup_fallback = 0;
        tilegen.g_lookup_null = 0;
        var res = try drlglib.generateActCollisionAll(&ctx, gpa, act_no, seed, .normal);
        defer res.deinit(gpa);
        std.debug.print("act {d} seed {d}: {d} levels (fallback={d} null={d})\n", .{ act_no, seed, res.levels.len, tilegen.g_lookup_fallback, tilegen.g_lookup_null });
        for (res.levels) |l| {
            var total: usize = 0;
            var blocked: usize = 0;
            for (l.grids) |g| {
                for (g.cells) |c| {
                    total += 1;
                    if (c & 0x01 != 0) blocked += 1;
                }
            }
            const lv = ctx.act.level(l.level_id);
            const nm = if (lv) |x| (if (x.level_name.len != 0) x.level_name else x.name) else "?";
            const dt = if (lv) |x| @tagName(x.drlg_type) else "?";
            const pct = if (total == 0) 0.0 else @as(f64, @floatFromInt(blocked)) / @as(f64, @floatFromInt(total)) * 100.0;
            std.debug.print("  L{d:>3} {s:<24} type={s:<10} grids={d:>3} cells={d:>7} blocked={d:>7} ({d:>5.1}%) null_lookups={d}\n", .{ l.level_id, nm, dt, l.grids.len, total, blocked, pct, l.unresolved });
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "tilemiss")) {
        const dt1 = @import("d2-formats").dt1;
        const dt1blob = @import("d2-formats").dt1_blob;
        const dt1_data = @import("d2-formats").dt1_data;
        const preset = @import("drlg/preset.zig");
        const s = @import("drlg/structs.zig");
        const level_id = std.fmt.parseInt(i32, args.next() orelse "10", 10) catch 10;
        const seed = std.fmt.parseInt(u32, args.next() orelse "72", 0) catch 72;
        var ctx = try drlglib.Ctx.init(gpa);
        defer ctx.deinit();
        const tlv = ctx.act.level(level_id).?;
        // Load the level's DT1 library and enumerate the identities it provides.
        const raw = try dt1blob.decompress(gpa, dt1_data.bytes);
        defer gpa.free(raw);
        var idx = try dt1blob.buildIndex(gpa, raw);
        defer idx.deinit();
        var files: [32][]const u8 = undefined;
        const nf = ctx.act.typeFiles(tlv.lvl_type, &files);
        var have = std.AutoHashMapUnmanaged(u64, void).empty;
        defer have.deinit(gpa);
        var dt_tiles: usize = 0;
        for (files[0..nf]) |f| {
            const rec = idx.get(f) orelse {
                std.debug.print("  MISSING DT1 in blob: {s}\n", .{f});
                continue;
            };
            var d = try dt1blob.unpack(gpa, rec);
            defer d.deinit();
            dt_tiles += d.tiles.len;
            std.debug.print("  DT1 {s}: {d} tiles\n", .{ f, d.tiles.len });
            for (d.tiles) |t| {
                const k = (@as(u64, @intCast(t.orientation & 0xff)) << 32) | (@as(u64, @intCast(t.main & 0xffff)) << 16) | @as(u64, @intCast(t.sub & 0xffff));
                have.put(gpa, k, {}) catch {};
            }
        }
        var w: i32 = 64;
        var h: i32 = 64;
        if (tlv.size_x > 0 and tlv.size_y > 0) { w = @intCast(tlv.size_x); h = @intCast(tlv.size_y); }
        const lvl = try drlglib.generate(&ctx, seed, @enumFromInt(level_id), .normal, .{ .x = 0, .y = 0, .w = w, .h = h });
        defer lvl.deinit();
        var miss = std.AutoHashMapUnmanaged(u64, u32).empty;
        defer miss.deinit(gpa);
        var pr = lvl.firstRoom();
        var rooms: usize = 0;
        while (pr) |p| : (pr = p.pRoomExNext) {
            const data = p.pRoomExData orelse continue;
            const rd: *s.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(data));
            const pmap = rd.pMap orelse continue;
            if (pmap.pTxtLevelPrest == null) continue;
            const rel = preset.presetDs1Path(pmap) orelse continue;
            var d = preset.unpackDs1(gpa, rel) orelse continue;
            defer d.deinit();
            rooms += 1;
            for (d.floor_layers) |fl| for (fl) |c| {
                if (c.raw & 0x00ff_ffff == 0) continue;
                const mn: i32 = @intCast((c.raw >> 20) & 0x3f);
                const sub: i32 = @intCast((c.raw >> 8) & 0xff);
                const k = (@as(u64, 0) << 32) | (@as(u64, @intCast(mn)) << 16) | @as(u64, @intCast(sub));
                if (!have.contains(k)) { const e = miss.getOrPutValue(gpa, k, 0) catch continue; e.value_ptr.* += 1; }
            };
            for (d.wall_layers) |wl| {
                const n = @min(wl.wall.len, wl.orient.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const wc = wl.wall[i];
                    if (wc.raw & 0x00ff_ffff == 0) continue;
                    const orient: i32 = wl.orient[i].prop1;
                    const mn: i32 = @intCast((wc.raw >> 20) & 0x3f);
                    const sub: i32 = @intCast((wc.raw >> 8) & 0xff);
                    const k = (@as(u64, @intCast(orient & 0xff)) << 32) | (@as(u64, @intCast(mn)) << 16) | @as(u64, @intCast(sub));
                    if (!have.contains(k)) { const e = miss.getOrPutValue(gpa, k, 0) catch continue; e.value_ptr.* += 1; }
                }
            }
        }
        std.debug.print("level {d} \"{s}\" LevelType={d}: {d} DT1 tiles, {d} distinct identities, {d} rooms\n", .{ level_id, tlv.name, tlv.lvl_type, dt_tiles, have.count(), rooms });
        std.debug.print("MISSING identities (orient/main/sub -> count): {d} distinct\n", .{miss.count()});
        var it = miss.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            std.debug.print("  o={d} m={d} s={d}  x{d}\n", .{ (k >> 32) & 0xff, (k >> 16) & 0xffff, k & 0xffff, e.value_ptr.* });
        }
        _ = dt1;
        return;
    }

    std.debug.print(
        \\d2-drlg — D2 1.14d map generation (Zig)
        \\usage:
        \\  d2-drlg rng <seed>          first RNG rolls for a seed
        \\  d2-drlg level <id>          level table info
        \\  d2-drlg ds1 <file.ds1>      parse + ASCII-render a DS1 map
        \\  d2-drlg verify-seeds-recon <f>  cross-seed scoreboard via the recon->Zig transform closure
        \\
    , .{});
}

test {
    _ = rng;
}
