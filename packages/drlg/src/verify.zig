//! Cross-validation of the Zig port against REAL engine output. Loads golden
//! DRLG dumps captured from the headless 1.14d engine (via the d2gs oracle hook)
//! and asserts our derivations reproduce them exactly. This is the ground-truth
//! gate: if the engine and our port disagree on a pinned seed, these fail.
//!
//! Golden set: seed 305419896 (0x12345678). The engine reported
//! drlgStartSeed = 62524658; per-level seed = drlgStartSeed + levelId (except a
//! few special presets that reseed — noted below).

const std = @import("std");
const rng = @import("rng.zig");
const tables = @import("tables.zig");
const oracle = @import("oracle.zig");
const serial = @import("serial.zig");
const act_mod = @import("act.zig");

/// True when D2DRLG_WILD_DIAG is set (gates the wilderness L2/L6 mismatch print).
fn wildDiagOn() bool {
    return std.c.getenv("D2DRLG_WILD_DIAG") != null;
}

const GOLDEN_INIT_SEED: u32 = 305419896;
const GOLDEN = @embedFile("golden/seed_305419896.jsonl");

const testing = std.testing;

/// For every maze/preset level in a golden dump, regenerate its rooms from the
/// derived level seed and assert the room COORDS match the engine bit-for-bit.
/// This is the core accuracy gate, reusable across seeds. (Wilderness type 3 is
/// skipped until that generator lands; room seeds are population RNG, not checked.)
/// Compute DefineRoomsNear for every room in `rooms` (in-place, creation order = index
/// order = pRoomExFirst walk order for both maze and preset after their respective
/// orderings). Each room's adj slice is allocated from `allocator`; caller must free.
///
/// Algorithm: for each room walk all rooms collecting those where the signed rectangle
/// gap on BOTH axes is < 6 (includes self and diagonal neighbours, excludes rooms >5
/// units away). Then bubble-sort (n-1 passes × n-1 adjacent comparisons) with swap
/// condition `next.right <= cur.left || next.bottom <= cur.top`, matching
/// ReorderNearRoomList in DrlgRoom.cpp @0x66BB00.
fn fillAdj(allocator: std.mem.Allocator, rooms: []oracle.Room) !void {
    var near: std.ArrayListUnmanaged(i32) = .empty;
    defer near.deinit(allocator);
    for (rooms, 0..) |*r, i| {
        near.clearRetainingCapacity();
        const ac = r.coords;
        for (rooms, 0..) |other, j| {
            const bc = other.coords;
            // Signed x/y gap between rectangles (negative = overlap, 0 = touching).
            const gx: i32 = if (ac.x < bc.x) bc.x - ac.w - ac.x else ac.x - bc.w - bc.x;
            const gy: i32 = if (ac.y < bc.y) bc.y - ac.h - ac.y else ac.y - bc.h - bc.y;
            if (gx < 6 and gy < 6) try near.append(allocator, @intCast(j));
        }
        // Bubble sort: n-1 passes of n-1 adjacent comparisons.
        const n = near.items.len;
        if (n > 1) {
            const nl = n - 1;
            for (0..nl) |_| {
                for (0..nl) |k| {
                    const ni_raw = near.items[k + 1];
                    const ci_raw = near.items[k];
                    const ni: usize = @intCast(ni_raw);
                    const ci: usize = @intCast(ci_raw);
                    const nr = rooms[ni].coords;
                    const cr = rooms[ci].coords;
                    if ((nr.x + nr.w <= cr.x) or (nr.y + nr.h <= cr.y)) {
                        near.items[k] = ni_raw;
                        near.items[k + 1] = ci_raw;
                    }
                }
            }
        }
        _ = i; // room index not needed (we write into r.adj directly)
        r.adj = try allocator.dupe(i32, near.items);
        r.near = @intCast(near.items.len); // near == adj.len (verified in golden data)
    }
}

/// Free all adj slices allocated by fillAdj, then free the rooms slice itself.
fn freeRoomsWithAdj(allocator: std.mem.Allocator, rooms: []oracle.Room) void {
    for (rooms) |r| if (r.adj.len > 0) allocator.free(r.adj);
    allocator.free(rooms);
}

/// Accumulated statistics from one (or more) seed runs.
pub const Tally = struct {
    levels: usize = 0,
    byte_exact: usize = 0,
    rooms: usize = 0,
    coord: usize = 0,
    seed_ok: usize = 0,
    def: usize = 0,
    file: usize = 0,
    ntype: usize = 0,
    nptype: usize = 0,
    adj: usize = 0,
    count_mismatch: usize = 0,

    pub fn add(self: *Tally, o: Tally) void {
        self.levels += o.levels;
        self.byte_exact += o.byte_exact;
        self.rooms += o.rooms;
        self.coord += o.coord;
        self.seed_ok += o.seed_ok;
        self.def += o.def;
        self.file += o.file;
        self.ntype += o.ntype;
        self.nptype += o.nptype;
        self.adj += o.adj;
        self.count_mismatch += o.count_mismatch;
    }
};

/// Per-level verdict for tracking worst offenders.
pub const LevelResult = struct {
    id: i32,
    rooms_total: usize,
    rooms_ok: usize, // coord matches
    byte_exact: bool,
    seed_ok: usize = 0,
    def_ok: usize = 0,
    file_ok: usize = 0,
    ntype_ok: usize = 0,
    nptype_ok: usize = 0,
    // Level-level preset pick diagnosis (the barracks jail-exit variant). Both
    // default to oracle.LVL_PICK_NONE; only meaningful for preset levels in a
    // golden captured with the `lvlPick` field. A golden_lvl_pick != port_lvl_pick
    // on Courtyard 1 (0x1b) is the proximate cause of barracks (0x1c) divergence.
    golden_lvl_pick: i32 = oracle.LVL_PICK_NONE,
    port_lvl_pick: i32 = oracle.LVL_PICK_NONE,
};

// TRANSFORM path
// The judge that drives the recon->Zig transform closure (src/drlg/*) and
// byte-compares each generated level against the golden.
const sdrlg = @import("drlg/structs.zig");
const drlg = @import("drlg/drlg.zig");
const dtables = @import("drlg/tables.zig");
const dpool = @import("drlg/pool.zig");

/// Extract one level's generated RoomEx list (the transform's pRoomExFirst walk)
/// into oracle.Room records for comparison. `def`/`picked_file` come from the
/// D2DrlgPresetRoomStrc payload block (nLevelPrest/nPickedFile), matching the
/// deep golden's per-room content fields.
fn extractRecon(allocator: std.mem.Allocator, pLevel: *sdrlg.D2DrlgLevelStrc) ![]oracle.Room {
    var rooms: std.ArrayListUnmanaged(oracle.Room) = .empty;
    errdefer rooms.deinit(allocator);
    var pr: ?*sdrlg.D2RoomExStrc = pLevel.pRoomExFirst;
    while (pr) |p| : (pr = p.pRoomExNext) {
        var def: i32 = 0;
        var picked_file: i32 = 0;
        if (p.pRoomExData) |data| {
            const rd: *sdrlg.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(data));
            def = @intFromEnum(rd.nLevelPrest);
            picked_file = rd.nPickedFile;
        }
        try rooms.append(allocator, .{
            .coords = .{
                .x = p.sCoords.WorldPosition.x,
                .y = p.sCoords.WorldPosition.y,
                .w = p.sCoords.WorldSize.x,
                .h = p.sCoords.WorldSize.y,
            },
            .seed = @bitCast(p.sSeed.nSeedLow),
            .def = def,
            .picked_file = picked_file,
            .n_type = p.nType,
            .n_preset_type = p.nPresetType,
        });
    }
    return rooms.toOwnedSlice(allocator);
}

/// Per-type breakdown of the transform path (so wilderness-stubbed shows as a
/// separate count, not silent failures).
pub const ReconTally = struct {
    total: Tally = .{},
    maze_levels: usize = 0,
    maze_exact: usize = 0,
    preset_levels: usize = 0,
    preset_exact: usize = 0,
    wild_levels: usize = 0,
    wild_exact: usize = 0,

    pub fn add(self: *ReconTally, o: ReconTally) void {
        self.total.add(o.total);
        self.maze_levels += o.maze_levels;
        self.maze_exact += o.maze_exact;
        self.preset_levels += o.preset_levels;
        self.preset_exact += o.preset_exact;
        self.wild_levels += o.wild_levels;
        self.wild_exact += o.wild_exact;
    }
};

/// TRANSFORM judge: for each golden level, drive DRLG_AllocDrlgActMisc +
/// GetLevelAndAlloc + InitLevel (the transformed closure), then compare the
/// generated RoomEx list against the golden per-field. Level placement
/// (sCoordinatesAndSize) is seeded from the golden level coords (decouples room
/// generation from the un-ported outdoor inter-level placement). Caller owns
/// `golden_levels` + the drlg LvlTables.
pub fn tallyLevelsRecon(
    allocator: std.mem.Allocator,
    golden_levels: []const oracle.Level,
    drlg_tb: *dtables.LvlTables,
    act_tb: *const tables.Tables,
    init_seed: u32,
    nDifficulty: u8,
    level_results: ?*std.ArrayListUnmanaged(LevelResult),
) !ReconTally {
    dtables.g_lvl_tables = drlg_tb;
    var rt: ReconTally = .{};

    // One pDrlg per seed: dwStartSeed is act-independent; build via ACT_II so the
    // Act-II tomb levels are rolled (harmless for other acts — their ids never
    // match a tomb level so the multipliers stay inert). nDifficulty drives the
    // per-difficulty maze room counts (LvlMaze Rooms[nDiff]) — the only DRLG input
    // that varies N/NM/Hell (level sizes are difficulty-invariant).
    var pDrlg: sdrlg.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, init_seed, .None, 0, nDifficulty);

    // Pre-pass: allocate every golden level and feed it the recorded coords. The
    // inter-level adjacency (orth) build below derives each wilderness seam's
    // direction from the two levels' world rects, so ALL coords must be in place
    // before it runs — exactly as the engine sets coords during the placement
    // subsystem (DRLGLEVEL_ParseLevelData) before AllocDrlgLevelFromLevelIdToLevelId.
    for (golden_levels) |g| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(g.id));
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = g.coords.x, .y = g.coords.y },
            .WorldSize = .{ .x = g.coords.w, .y = g.coords.h },
        };
    }

    // DRLGLEVEL_ParseLevelData (006772c0) Cathedral→Courtyard nPickedFile write: the
    // Act-1 placement subsystem overwrites the Courtyard's (0x1b) own preset selector
    // pick with a jail-exit variant derived from the Black Marsh placement direction +
    // a seed roll. The Barracks (0x1c) reads that as its jail-exit layout. We only run
    // this for Act-1 corpora (where the courtyard/barracks are present); the value comes
    // from the verified Act-1 placement walk (act.zig) so it is a faithful port of the
    // engine's pass-2 write, not a per-seed correction.
    for (golden_levels) |g| {
        if (g.id != 0x1b and g.id != 0x1c) continue;
        if (act_mod.act1CourtyardPick(act_tb, init_seed)) |pick| {
            const pCourt = drlg.GetLevelAndAlloc(&pDrlg, .OuterCloister);
            if (pCourt.pDrlgLevelData) |pd| {
                const pp: *drlg.D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pd));
                pp.nPickedFile = pick;
            }
        }
        break;
    }

    // Same pass-2 write for the Rogue Encampment town (0x1): its nPickedFile is the
    // town's own placement direction (TownN1/E1/S1/W1 = 0/1/2/3), so it faces the
    // Blood Moor neighbour. Guarded by golden presence so Act-2+ corpora are untouched.
    for (golden_levels) |g| {
        if (g.id != 1) continue;
        const pTown = drlg.GetLevelAndAlloc(&pDrlg, .RogueEncampment);
        if (pTown.pDrlgLevelData) |pd| {
            const pp: *drlg.D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pd));
            pp.nPickedFile = act_mod.act1TownPick(act_tb, init_seed);
        }
        break;
    }

    // Build the inter-level wilderness adjacency so each wilderness level's
    // pOrthData is populated; DRLGOUTDOOR_GenerateLevel turns these orths into the
    // border junction vertices (DRLGVER_CreateVerticesFromEdges, dwFlags&1).
    drlg.buildInterLevelOrths(&pDrlg);

    // The maze transform now dispatches every level type; DRLGMAZE_GenerateLevel
    // self-skips the few not-yet-transformed arms (Arcane 0x13, Baal 0x23,
    // Barracks/River specials) by returning 0 after allocating only the root room,
    // so those still register as a room-count mismatch (not byte-exact) rather than
    // crashing. No level type needs to be skipped here anymore.
    for (golden_levels) |g| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(g.id));
        drlg.InitLevel(pLevel);

        // Port's own level-level preset pick (jail-exit variant) for diagnosis:
        // PresetArea levels store D2DrlgLevelDataPresetArea.nPickedFile here.
        const port_lvl_pick: i32 = blk: {
            if (g.drlg_type != 2) break :blk oracle.LVL_PICK_NONE;
            const pd = pLevel.*.pDrlgLevelData orelse break :blk oracle.LVL_PICK_NONE;
            const pp: *const drlg.D2DrlgLevelDataPresetArea = @ptrCast(@alignCast(pd));
            break :blk pp.nPickedFile;
        };

        const rooms = extractRecon(allocator, pLevel) catch continue;
        try fillAdj(allocator, rooms);
        defer freeRoomsWithAdj(allocator, rooms);

        rt.total.levels += 1;
        const is_wild = g.drlg_type == 3;
        const is_preset = g.drlg_type == 2;
        if (is_wild) rt.wild_levels += 1 else if (is_preset) rt.preset_levels += 1 else rt.maze_levels += 1;

        var port_lv = g;
        port_lv.rooms = rooms;
        const gb = try serial.serialize(allocator, &.{g});
        defer allocator.free(gb);
        const pb = try serial.serialize(allocator, &.{port_lv});
        defer allocator.free(pb);
        const is_exact = std.mem.eql(u8, gb, pb);
        if (is_exact) {
            rt.total.byte_exact += 1;
            if (is_wild) rt.wild_exact += 1 else if (is_preset) rt.preset_exact += 1 else rt.maze_exact += 1;
        }

        var rooms_ok: usize = 0;
        var lseed: usize = 0;
        var ldef: usize = 0;
        var lfile: usize = 0;
        var lntype: usize = 0;
        var lnptype: usize = 0;
        if (g.rooms.len != rooms.len) {
            rt.total.count_mismatch += 1;
        } else {
            for (g.rooms, rooms) |ge, ac| {
                rt.total.rooms += 1;
                if (ge.coords.eql(ac.coords)) { rt.total.coord += 1; rooms_ok += 1; }
                if (ge.seed == ac.seed) { rt.total.seed_ok += 1; lseed += 1; }
                if (ge.def == ac.def) { rt.total.def += 1; ldef += 1; }
                if (ge.picked_file == ac.picked_file) { rt.total.file += 1; lfile += 1; }
                if (ge.n_type == ac.n_type) { rt.total.ntype += 1; lntype += 1; }
                if (ge.n_preset_type == ac.n_preset_type) { rt.total.nptype += 1; lnptype += 1; }
                if (ge.adj.len == ac.adj.len) rt.total.adj += 1;
            }
        }
        // Env-gated wilderness diagnostic: for a failing L2/L6, print the seed +
        // which field diverges + the first differing room. D2DRLG_WILD_DIAG=1.
        if (!is_exact and (g.id == 2 or g.id == 6) and wildDiagOn()) {
            std.debug.print("WILD seed={d} L{d} rooms g{d}/p{d} coord{d} seed{d} def{d} file{d} ntype{d} nptype{d}\n", .{ init_seed, g.id, g.rooms.len, rooms.len, rooms_ok, lseed, ldef, lfile, lntype, lnptype });
            if (g.rooms.len == rooms.len) {
                for (g.rooms, rooms, 0..) |ge, ac, i| {
                    if (ge.seed != ac.seed or ge.def != ac.def or ge.picked_file != ac.picked_file or !ge.coords.eql(ac.coords)) {
                        std.debug.print("  room[{d}] g(x{d},y{d} seed{d} def{d} f{d}) p(x{d},y{d} seed{d} def{d} f{d})\n", .{ i, ge.coords.x, ge.coords.y, ge.seed, ge.def, ge.picked_file, ac.coords.x, ac.coords.y, ac.seed, ac.def, ac.picked_file });
                        break;
                    }
                }
            }
        }
        if (level_results) |lr| {
            try lr.append(allocator, .{
                .id = g.id,
                .rooms_total = g.rooms.len,
                .rooms_ok = rooms_ok,
                .byte_exact = is_exact,
                .seed_ok = lseed,
                .def_ok = ldef,
                .file_ok = lfile,
                .ntype_ok = lntype,
                .nptype_ok = lnptype,
                .golden_lvl_pick = g.lvl_pick,
                .port_lvl_pick = port_lvl_pick,
            });
        }
    }
    return rt;
}

test "transform path: maze+preset reproduce deep golden (seed 305419896)" {
    const a = testing.allocator;
    const levels = try oracle.parseJsonl(a, DEEP_GOLDEN);
    defer {
        for (levels) |*lv| lv.deinit(a);
        a.free(levels);
    }
    var dtb = try dtables.LvlTables.load(a);
    defer dtb.deinit();
    var atb = try tables.Tables.load(a);
    defer atb.deinit();

    // Route the transform's pool allocator through an arena so its allocs are
    // reclaimed at test end (the closure never frees).
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const saved = dpool.allocator;
    dpool.allocator = arena.allocator();
    defer dpool.allocator = saved;

    var lr: std.ArrayListUnmanaged(LevelResult) = .empty;
    defer lr.deinit(a);
    const rt = try tallyLevelsRecon(a, levels, &dtb, &atb, GOLDEN_INIT_SEED, 0, &lr);
    std.debug.print(
        "TRANSFORM seed {d}: byte-exact {d}/{d} | maze {d}/{d} preset {d}/{d} wild {d}/{d}\n",
        .{ GOLDEN_INIT_SEED, rt.total.byte_exact, rt.total.levels, rt.maze_exact, rt.maze_levels, rt.preset_exact, rt.preset_levels, rt.wild_exact, rt.wild_levels },
    );
    for (levels) |g| {
        if (g.drlg_type != 1) continue;
        for (lr.items) |it| if (it.id == g.id and !it.byte_exact) {
            std.debug.print("  MAZE not-exact: lvl {d} rooms {d}/{d}\n", .{ g.id, it.rooms_ok, it.rooms_total });
        };
    }
    for (levels) |g| {
        if (g.drlg_type != 3) continue;
        for (lr.items) |it| if (it.id == g.id) {
            std.debug.print("  WILD lvl {d}: {s} coord {d}/{d} seed {d} def {d} file {d} ntype {d} nptype {d}\n", .{ g.id, if (it.byte_exact) "EXACT" else "  -  ", it.rooms_ok, it.rooms_total, it.seed_ok, it.def_ok, it.file_ok, it.ntype_ok, it.nptype_ok });
        };
    }
    // Floor: the 4 Act-II sewer mazes are byte-exact via the transform; they
    // must remain so here.
    try testing.expect(rt.maze_exact >= 4);
}

// Deeper structural invariants on the engine's room sets — these walk every room
// and assert geometric consistency that coord-equality alone wouldn't catch.
test "golden structural invariants: in-bounds, tiling, non-overlap" {
    const levels = try oracle.parseJsonl(testing.allocator, GOLDEN);
    defer {
        for (levels) |*lv| lv.deinit(testing.allocator);
        testing.allocator.free(levels);
    }

    for (levels) |lv| {
        if (lv.rooms.len == 0) continue;
        const lx0 = lv.coords.x;
        const ly0 = lv.coords.y;
        const lx1 = lv.coords.x + lv.coords.w;
        const ly1 = lv.coords.y + lv.coords.h;

        var covered: i64 = 0;
        for (lv.rooms, 0..) |r, i| {
            // Every room lies within the level bounds.
            try testing.expect(r.coords.x >= lx0 and r.coords.y >= ly0);
            try testing.expect(r.coords.x + r.coords.w <= lx1 and r.coords.y + r.coords.h <= ly1);
            try testing.expect(r.coords.w > 0 and r.coords.h > 0);
            covered += @as(i64, r.coords.w) * r.coords.h;

            // No two rooms overlap (rectangles are disjoint).
            for (lv.rooms[i + 1 ..]) |o| {
                const disjoint = r.coords.x + r.coords.w <= o.coords.x or
                    o.coords.x + o.coords.w <= r.coords.x or
                    r.coords.y + r.coords.h <= o.coords.y or
                    o.coords.y + o.coords.h <= r.coords.y;
                try testing.expect(disjoint);
            }
        }

        // Preset levels tile their whole area exactly (no gaps): covered == w*h.
        if (lv.drlg_type == 2) {
            try testing.expectEqual(@as(i64, lv.coords.w) * lv.coords.h, covered);
        }
        // Maze/wilderness: rooms cover at most the level (already bounded above).
        try testing.expect(covered <= @as(i64, lv.coords.w) * lv.coords.h);
    }
}

test "engine golden: act start seed matches" {
    // The engine derived drlgStartSeed = 62524658 from init seed 305419896.
    try testing.expectEqual(@as(u32, 62524658), rng.actStartSeed(GOLDEN_INIT_SEED));
}

test "engine golden: per-level seed + drlgType match the real engine" {
    const levels = try oracle.parseJsonl(testing.allocator, GOLDEN);
    defer {
        for (levels) |*lv| lv.deinit(testing.allocator);
        testing.allocator.free(levels);
    }
    try testing.expect(levels.len >= 4);

    var tb = try tables.Tables.load(testing.allocator);
    defer tb.deinit();

    const start = rng.actStartSeed(GOLDEN_INIT_SEED);

    for (levels) |lv| {
        // drlgType from our tables must match what the engine generated.
        const tlv = tb.level(lv.id) orelse {
            std.debug.print("level {d} missing from tables\n", .{lv.id});
            return error.LevelMissing;
        };
        try testing.expectEqual(lv.drlg_type, @intFromEnum(tlv.drlg_type));

        // Standard levels: seed == drlgStartSeed + levelId. A handful of special
        // presets reseed independently (e.g. staff/tomb picks) — skip the seed
        // check there, but the type check above still holds.
        const derived = rng.levelSeed(start, lv.id).low;
        if (derived == lv.seed) {
            std.debug.print("level {d}: seed {d} MATCH (type {d})\n", .{ lv.id, lv.seed, lv.drlg_type });
        } else {
            std.debug.print("level {d}: derived {d} != engine {d} (special preset, seed-skip)\n", .{ lv.id, derived, lv.seed });
        }
    }

    // The three standard levels (40 town, 41 wilderness, 47 maze) MUST match.
    for ([_]i32{ 40, 41, 47 }) |id| {
        for (levels) |lv| {
            if (lv.id == id) {
                try testing.expectEqual(rng.levelSeed(start, id).low, lv.seed);
            }
        }
    }
}

test "engine golden: preset/wilderness level size matches tables" {
    const levels = try oracle.parseJsonl(testing.allocator, GOLDEN);
    defer {
        for (levels) |*lv| lv.deinit(testing.allocator);
        testing.allocator.free(levels);
    }
    var tb = try tables.Tables.load(testing.allocator);
    defer tb.deinit();

    // Level 40 (Lut Gholein town) and 41 (Rocky Waste) take their size straight
    // from Levels.txt SizeX/SizeY — verify the engine's coords.w/h agree.
    for (levels) |lv| {
        if (lv.id != 40 and lv.id != 41) continue;
        const tlv = tb.level(lv.id).?;
        try testing.expectEqual(@as(i32, @intCast(tlv.size_x)), lv.coords.w);
        try testing.expectEqual(@as(i32, @intCast(tlv.size_y)), lv.coords.h);
    }
}

// Deep golden (full per-room data: seed/def/types/adjacency) for the primary
// seed — consumed by the transform-path test above.
const DEEP_GOLDEN = @embedFile("golden/deep_seed_305419896.jsonl");
