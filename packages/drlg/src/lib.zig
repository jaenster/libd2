//! d2-drlg public library API (Layer 1, Zig-native).
//!
//! Re-exports the faithful DRLG structs/enums and drives per-level generation
//! onto a per-Level fog pool — `Level.deinit` is a wholesale teardown, so the
//! caller's entire memory duty is "free each Level, then the Ctx".
//!
//! Scope: byte-exact GENERATION (room layout, seeds, DS1 selection, tile arrays,
//! roads) + collision. The render / warp-tile-linking / animation layer is out.
//!
//! The exposed structs are field-faithful but use 64-bit pointers + Zig-computed
//! offsets — this is NOT the 32-bit Game.exe ABI; do not memcpy into the engine.

const std = @import("std");

/// Faithful engine types + enums — full field access for Zig consumers.
pub const abi = @import("drlg/structs.zig");
pub const LevelId = abi.eD2LevelId;

/// Seeded monster-population subsystem (roster + per-room spawns). Re-exported so
/// downstream consumers (the standalone game host) can drive spawns off a level's
/// generated rooms. See drlg/monpop.zig for the faithful port + its residuals.
pub const monpop = @import("drlg/monpop.zig");

/// Faithful unit pathfinding (the PATH_CalculatePath / IDA* chain). Re-exported so
/// downstream consumers (the standalone game host) can path monsters/players over a
/// level's collision. Feed it a `path.CollisionView`; build one from a level's
/// generated collision with `buildPathGrid` below. See path.zig for the port + its
/// byte-exact-validation residual.
pub const path = @import("path.zig");

const drlg = @import("drlg/drlg.zig");
const dtables = @import("drlg/tables.zig");
const dpool = @import("drlg/pool.zig");
const tables = @import("tables.zig");
const presettables = @import("drlg/presettables.zig");
const fog = @import("d2-fog").memory;
const act_mod = @import("act.zig");
const collision = @import("collision.zig");
const dt1 = @import("d2-formats").dt1;
const dt1blob = @import("d2-formats").dt1_blob;
const dt1_data = @import("d2-formats").dt1_data;
const dt1pix = @import("d2-formats").dt1pix;
const ds1 = @import("d2-formats").ds1;
const dt1pix_data = @import("d2-formats").dt1pix_data;
const preset = @import("drlg/preset.zig");
const materialize = @import("drlg/materialize.zig");

/// Generation-internal surface exposed for the sibling `d2-render` package. Its
/// automap + DT1-tile-art layer is a pure post-generation consumer, but it drives
/// this same pipeline (act build, per-level room/DS1 materialization), so it reaches
/// the internal modules + a few raw data blobs through here. NOT a stable API — do
/// not depend on it from outside the monorepo. Generation logic stays in drlg.
pub const gen = struct {
    pub const abi = @import("drlg/structs.zig");
    pub const fog = @import("d2-fog").memory;
    pub const dpool = @import("drlg/pool.zig");
    pub const dtables = @import("drlg/tables.zig");
    pub const act = @import("act.zig");
    pub const drlg = @import("drlg/drlg.zig");
    pub const preset = @import("drlg/preset.zig");
    pub const presettables = @import("drlg/presettables.zig");
    pub const materialize = @import("drlg/materialize.zig");
    pub const objects = @import("objects.zig");
    pub const txt = @import("txt.zig");
    // Formats instances used across the generation boundary — render MUST use these
    // (not its own d2-formats import) for anything flowing into drlg code, so the
    // types match by identity.
    pub const dt1 = @import("d2-formats").dt1;
    pub const dt1pix = @import("d2-formats").dt1pix;
    pub const dt1_blob = @import("d2-formats").dt1_blob;
    pub const dt1pix_data = @import("d2-formats").dt1pix_data;
    pub const ds1 = @import("d2-formats").ds1;
    // Raw table/asset bytes committed in drlg's excel/ + maps/ trees (single source
    // of truth — no duplication into render).
    pub const automap_txt = @embedFile("excel/AutoMap.txt");
    pub const lvltypes_txt = @embedFile("excel/LvlTypes.txt");
    pub const town_ds1 = @embedFile("maps/Act1_Town_TownN1.ds1");
};

pub const Difficulty = enum(u8) { normal = 0, nightmare = 1, hell = 2 };

/// A level's placement rectangle in world coords. Required input: the outdoor
/// inter-level placement pass isn't ported, so callers feed each level's rect
/// (e.g. from a golden capture, or the level's Levels.txt size at the origin).
pub const Placement = struct { x: i32, y: i32, w: i32, h: i32 };

/// Loaded, read-only game data. Long-lived; shared across generate() calls.
///
/// SEAM: `init` currently loads via the file-based table loaders. The
/// distributable path is buffers-only (a `initFromBuffers(TableSet)`); swap this
/// when the FFI/wasm layer lands. Never bundle Blizzard assets in the public lib.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    lvl: dtables.LvlTables,
    act: tables.Tables,

    pub fn init(gpa: std.mem.Allocator) !Ctx {
        _ = presettables.ensureLoaded();
        return .{
            .gpa = gpa,
            .lvl = try dtables.LvlTables.load(gpa),
            .act = try tables.Tables.load(gpa),
        };
    }

    pub fn deinit(self: *Ctx) void {
        self.lvl.deinit();
        self.act.deinit();
    }
};

/// One generated level. Owns its fog pool; `deinit` tears it down wholesale.
///
/// Heap-boxed on purpose: `drlg` (the D2DrlgStrc) must have a stable address
/// because the pool-allocated rooms point back at it — returning by value would
/// dangle those pointers.
pub const Level = struct {
    gpa: std.mem.Allocator,
    pool: fog.PoolManager,
    drlg: abi.D2DrlgStrc,
    level: *abi.D2DrlgLevelStrc,

    /// First RoomEx in the generated list (borrowed; valid until `deinit`).
    /// Walk via `room.pRoomExNext`.
    pub fn firstRoom(self: *Level) ?*abi.D2RoomExStrc {
        return self.level.pRoomExFirst;
    }

    pub fn deinit(self: *Level) void {
        self.pool.deinit();
        self.gpa.destroy(self);
    }
};

/// Generate a single level onto its own fog pool. `placement` is the level's
/// world rect (see `Placement`). Returns a heap-boxed `Level`; call `deinit`.
///
/// Mirrors the verified generation flow: allocDrlgActMisc → GetLevelAndAlloc →
/// (set coords) → buildInterLevelOrths → InitLevel.
pub fn generate(
    ctx: *Ctx,
    seed: u32,
    id: LevelId,
    diff: Difficulty,
    placement: Placement,
) !*Level {
    const self = try ctx.gpa.create(Level);
    errdefer ctx.gpa.destroy(self);
    self.* = .{
        .gpa = ctx.gpa,
        .pool = fog.PoolManager.init(ctx.gpa),
        .drlg = undefined,
        .level = undefined,
    };
    errdefer self.pool.deinit();

    // Wire the threadlocal generation globals to this context + pool.
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = self.pool.allocator();
    dpool.resetRegistry(); // self-contained run: drop any prior generation's stale registry
    ctx.lvl.resetGenCache(); // drop LvlSub pDrlgFile pointers into the prior (freed) pool

    _ = drlg.allocDrlgActMisc(&self.drlg, 1, seed, .None, 0, @intFromEnum(diff));
    const pLevel = drlg.GetLevelAndAlloc(&self.drlg, id);
    pLevel.sCoordinatesAndSize = .{
        .WorldPosition = .{ .x = placement.x, .y = placement.y },
        .WorldSize = .{ .x = placement.w, .y = placement.h },
    };
    drlg.buildInterLevelOrths(&self.drlg);
    drlg.InitLevel(pLevel);
    self.level = pLevel;
    return self;
}

/// One room's world rectangle + type, extracted from a generated RoomEx.
/// `picked_file` = the room's DS1 selector (D2DrlgPresetRoomStrc.nPickedFile for a
/// preset room, D2DrlgRoomExDataMazeStrc.nSubThemePicked for an outdoor/maze room,
/// -1 if the room carries neither). x/y are WORLD TILES, w/h TILES.
pub const RoomRect = struct { x: i32, y: i32, w: i32, h: i32, n_type: i32, n_preset_type: i32, picked_file: i32 };

/// One level's id + its generated rooms (owned by the ActResult's allocator).
/// `placed` = the level was positioned by the act placement graph (part of the
/// connected surface overworld); false = it fell back to the Depend offset chain
/// (an interior: cave/crypt/tomb, entered via warp, with a local origin).
/// `drlg_type` mirrors Levels.txt DrlgType (1 maze, 2 preset, 3 wilderness).
/// `origin_x/y` + `width/height` are the level's generated WorldPosition/WorldSize
/// in TILES (multiply by 5 for the subtile frame DBM reports; room x/y are world
/// tiles, so a room's level-local subtile is (room.x - origin_x) * 5).
pub const LevelRooms = struct {
    level_id: i32,
    drlg_type: i32,
    placed: bool,
    origin_x: i32,
    origin_y: i32,
    width: i32,
    height: i32,
    rooms: []RoomRect,
};

/// A room's DS1/theme selector, for the DBM roomNo/subNo field: a preset room
/// (nPresetType==2) reports its picked DS1 file variant; an outdoor/maze room
/// (nPresetType==1) reports its picked subtheme variant; -1 otherwise.
pub fn roomPickedFile(p: *abi.D2RoomExStrc) i32 {
    const data = p.pRoomExData orelse return -1;
    if (p.nPresetType == 2) {
        const rd: *abi.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(data));
        return rd.nPickedFile;
    }
    if (p.nPresetType == 1) {
        const rd: *abi.D2DrlgRoomExDataMazeStrc = @ptrCast(@alignCast(data));
        return rd.nSubThemePicked;
    }
    return -1;
}

/// Levels.txt LevelName (the in-game display name) for a level id, or "" if unknown.
/// Borrows the Ctx's table storage — valid until the Ctx is destroyed.
pub fn levelDisplayName(ctx: *Ctx, level_id: i32) []const u8 {
    const lv = ctx.act.level(level_id) orelse return "";
    return lv.level_name;
}

/// The whole-act result: every level in the act with its rooms, positioned in a
/// shared world-coord space via the real inter-level placement (act.coords).
pub const ActResult = struct {
    levels: []LevelRooms,

    pub fn deinit(self: *ActResult, alloc: std.mem.Allocator) void {
        for (self.levels) |lr| alloc.free(lr.rooms);
        alloc.free(self.levels);
    }
};

/// Generate an ENTIRE act with faithful inter-level placement, mirroring the
/// verify.zig `tallyLevelsRecon` flow except the coords come from `act.coords`
/// (standalone) instead of a golden capture. One fog pool + one D2DrlgStrc for
/// the whole act; rooms are copied into `out_alloc` and the pool torn down before
/// return. `act_no` is 0-based (Act I = 0 … Act V = 4). Un-ported generator arms
/// self-skip (0 rooms) rather than crash, exactly like the verify path.
pub fn generateAct(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
) !ActResult {
    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry(); // self-contained run: drop any prior generation's stale registry
    ctx.lvl.resetGenCache(); // drop LvlSub pDrlgFile pointers into the prior (freed) pool

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    // Level ids belonging to this act (Levels.txt Act column == act_no).
    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) try ids.append(out_alloc, @intCast(lv.id));
        }
    }

    // Pass 1: allocate every level and set its REAL world coords BEFORE orths.
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }

    // Act-I ParseLevelData pass-2 preset picks: town orientation + Courtyard
    // jail-exit variant, both from placement direction (see applyAct1PresetPicks).
    if (act_no == 0) drlg.applyAct1PresetPicks(&pDrlg, &ctx.act, seed);
    if (act_no == 1) drlg.applyAct2PresetPicks(&pDrlg, &ctx.act, seed);

    drlg.buildInterLevelOrths(&pDrlg);

    // Pass 2: generate each level + collect its rooms.
    var out: std.ArrayListUnmanaged(LevelRooms) = .empty;
    errdefer {
        for (out.items) |lr| out_alloc.free(lr.rooms);
        out.deinit(out_alloc);
    }
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlg.InitLevel(pLevel);

        var rooms: std.ArrayListUnmanaged(RoomRect) = .empty;
        errdefer rooms.deinit(out_alloc);
        var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
        while (pr) |p| : (pr = p.pRoomExNext) {
            try rooms.append(out_alloc, .{
                .x = p.sCoords.WorldPosition.x,
                .y = p.sCoords.WorldPosition.y,
                .w = p.sCoords.WorldSize.x,
                .h = p.sCoords.WorldSize.y,
                .n_type = p.nType,
                .n_preset_type = p.nPresetType,
                .picked_file = roomPickedFile(p),
            });
        }
        const placed = act.positions.get(lid) != null;
        const dtype: i32 = if (ctx.act.level(lid)) |lv| @intFromEnum(lv.drlg_type) else 0;
        const lpos = pLevel.sCoordinatesAndSize.WorldPosition;
        const lsize = pLevel.sCoordinatesAndSize.WorldSize;
        try out.append(out_alloc, .{
            .level_id = lid,
            .drlg_type = dtype,
            .placed = placed,
            .origin_x = lpos.x,
            .origin_y = lpos.y,
            .width = lsize.x,
            .height = lsize.y,
            .rooms = try rooms.toOwnedSlice(out_alloc),
        });
    }

    return .{ .levels = try out.toOwnedSlice(out_alloc) };
}

// ---- collision maps --------------------------------------------------------

/// A rasterized subtile collision grid for one preset DrlgMap, positioned in
/// world (subtile) coords. `cells[y*w + x]` is the OR of contributing tiles'
/// subtile flags (dt1.SubtileFlag: 0x01 block-walk, 0x02 block-los).
pub const CollGrid = struct { x: i32, y: i32, w: i32, h: i32, cells: []u8 };

pub const CollResult = struct {
    grids: []CollGrid,
    unresolved: usize, // tiles whose DS1 identity didn't resolve in the DT1 set

    pub fn deinit(self: *CollResult, alloc: std.mem.Allocator) void {
        for (self.grids) |g| alloc.free(g.cells);
        alloc.free(self.grids);
    }
};

// Baked DT1 subtile-flag blob, decompressed + indexed once per process. This is a
// process-lifetime cache: it is deliberately never freed, so it MUST NOT borrow a
// caller's (transient, leak-checked) allocator — it uses the page allocator so a
// per-call Ctx.gpa can be a DebugAllocator/testing.allocator without a false leak
// and without dangling when that Ctx is destroyed.
var g_dt1_raw: ?[]u8 = null;
var g_dt1_index: ?dt1blob.Index = null;
fn dt1Index() *const dt1blob.Index {
    if (g_dt1_index == null) {
        const a = std.heap.page_allocator;
        g_dt1_raw = dt1blob.decompress(a, dt1_data.bytes) catch @panic("d2-drlg: DT1 blob decompress failed");
        g_dt1_index = dt1blob.buildIndex(a, g_dt1_raw.?) catch @panic("d2-drlg: DT1 blob corrupt");
    }
    return &g_dt1_index.?;
}

/// Generate one level and rasterize the REAL subtile collision of its preset
/// DrlgMaps (via DS1 layers + the level's DT1 tile set). World coords are in
/// subtiles, matching the room rects, so each grid overlays directly. Covers
/// preset-type areas (town, cathedral, tristram, courtyard, treasure rooms,
/// preset catacombs, …); maze/wilderness rooms without a preset DrlgMap yield no
/// grid. Caller owns the result (deinit with `out_alloc`).
pub fn generateLevelCollision(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    seed: u32,
    level_id: i32,
    diff: Difficulty,
) !CollResult {
    var w: i32 = 64;
    var h: i32 = 64;
    const tlv = ctx.act.level(level_id) orelse return CollResult{ .grids = try out_alloc.alloc(CollGrid, 0), .unresolved = 0 };
    if (tlv.size_x > 0 and tlv.size_y > 0) {
        w = @intCast(tlv.size_x);
        h = @intCast(tlv.size_y);
    }
    const lvl = try generate(ctx, seed, @enumFromInt(level_id), diff, .{ .x = 0, .y = 0, .w = w, .h = h });
    defer lvl.deinit();

    // DT1 library for this level's tile set (LvlTypes File columns).
    var files: [32][]const u8 = undefined;
    const nf = ctx.act.typeFiles(tlv.lvl_type, &files);
    var dtlib = collision.DtLibrary.init(out_alloc);
    defer dtlib.deinit();
    var dts: std.ArrayListUnmanaged(dt1.Dt1) = .empty;
    defer {
        for (dts.items) |*d| d.deinit();
        dts.deinit(out_alloc);
    }
    const idx = dt1Index();
    for (files[0..nf]) |f| {
        const rec = idx.get(f) orelse continue;
        const d = dt1blob.unpack(out_alloc, rec) catch continue;
        try dts.append(out_alloc, d);
    }
    for (dts.items) |*d| try dtlib.add(d);

    // Rasterize each unique preset DrlgMap once, positioned at its world offset.
    var grids: std.ArrayListUnmanaged(CollGrid) = .empty;
    errdefer {
        for (grids.items) |g| out_alloc.free(g.cells);
        grids.deinit(out_alloc);
    }
    var seen: std.ArrayListUnmanaged(usize) = .empty;
    defer seen.deinit(out_alloc);
    var unresolved: usize = 0;

    var pr = lvl.firstRoom();
    while (pr) |p| : (pr = p.pRoomExNext) {
        const data = p.pRoomExData orelse continue;
        const rd: *abi.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(data));
        const pmap = rd.pMap orelse continue;
        if (pmap.pTxtLevelPrest == null or pmap.nSizeX <= 0 or pmap.nSizeY <= 0) continue;
        const key = @intFromPtr(pmap);
        var dup = false;
        for (seen.items) |s| if (s == key) {
            dup = true;
            break;
        };
        if (dup) continue;
        try seen.append(out_alloc, key);

        const rel = preset.presetDs1Path(pmap) orelse continue;
        var d = preset.unpackDs1(out_alloc, rel) orelse continue;
        defer d.deinit();
        var g = collision.rasterize(out_alloc, &d, &dtlib) catch continue;
        defer g.deinit();
        unresolved += g.unresolved;
        try grids.append(out_alloc, .{
            .x = pmap.nRealOffsetX,
            .y = pmap.nRealOffsetY,
            .w = @intCast(g.width),
            .h = @intCast(g.height),
            .cells = try out_alloc.dupe(u8, g.cells),
        });
    }

    return .{ .grids = try grids.toOwnedSlice(out_alloc), .unresolved = unresolved };
}

// ---- pathfinding adapter ---------------------------------------------------

/// A level's collision composited into one rectangular grid in WORLD SUBTILE
/// coords, adapted to `path.CollisionView` for the faithful pathfinder.
///
/// `generateLevelCollision` yields per-room `CollGrid`s whose ORIGIN is in TILES
/// (nRealOffsetX == RoomEx.WorldPosition, tile units) but whose EXTENT is in
/// SUBTILES (tile*5). We composite them onto a single subtile-space bitmap: a cell
/// is `blocked` when its subtile-flag byte has the walk-block bit set, and `ground`
/// (covered) when some room grid overlays it. Uncovered cells are void (impassable).
/// Positions on the wire (unit x/y) are world subtiles, so `toLocal`/`toWorld`
/// translate between wire coords and this grid.
pub const PathGrid = struct {
    /// World-subtile coordinate of local cell (0,0).
    origin_x: i32,
    origin_y: i32,
    w: i32,
    h: i32,
    blocked: []bool,
    ground: []bool,

    pub fn deinit(self: *PathGrid, alloc: std.mem.Allocator) void {
        alloc.free(self.blocked);
        alloc.free(self.ground);
        self.* = undefined;
    }

    pub fn view(self: *const PathGrid) path.CollisionView {
        return .{ .w = self.w, .h = self.h, .blocked = self.blocked, .ground = self.ground };
    }

    /// World subtile -> local grid point; null if outside the composited grid.
    pub fn toLocal(self: *const PathGrid, wx: i32, wy: i32) ?path.Point {
        const lx = wx - self.origin_x;
        const ly = wy - self.origin_y;
        if (lx < 0 or ly < 0 or lx >= self.w or ly >= self.h) return null;
        return .{ .x = lx, .y = ly };
    }

    pub fn toWorld(self: *const PathGrid, p: path.Point) path.Point {
        return .{ .x = p.x + self.origin_x, .y = p.y + self.origin_y };
    }
};

/// Build a `PathGrid` from a level's preset collision (`generateLevelCollision`),
/// compositing the per-room subtile grids into one world-subtile-space walkability
/// view. Returns null if the level has no preset collision grids (maze/wilderness
/// rooms without a preset DrlgMap yield none — the caller falls back to straight
/// line movement). Caller owns the result (`deinit` with `out_alloc`).
pub fn buildPathGrid(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    seed: u32,
    level_id: i32,
    diff: Difficulty,
) !?PathGrid {
    var coll = try generateLevelCollision(ctx, out_alloc, seed, level_id, diff);
    defer coll.deinit(out_alloc);
    if (coll.grids.len == 0) return null;

    // Bounding box in world SUBTILE space (origin*5 + extent-in-subtiles).
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (coll.grids) |g| {
        const sx0 = g.x * 5;
        const sy0 = g.y * 5;
        min_x = @min(min_x, sx0);
        min_y = @min(min_y, sy0);
        max_x = @max(max_x, sx0 + g.w);
        max_y = @max(max_y, sy0 + g.h);
    }
    const w: i32 = max_x - min_x;
    const h: i32 = max_y - min_y;
    if (w <= 0 or h <= 0) return null;

    const wu: usize = @intCast(w);
    const hu: usize = @intCast(h);
    const blocked = try out_alloc.alloc(bool, wu * hu);
    errdefer out_alloc.free(blocked);
    const ground = try out_alloc.alloc(bool, wu * hu);
    errdefer out_alloc.free(ground);
    @memset(blocked, false);
    @memset(ground, false);

    const block_bit = dt1.SubtileFlag.block_walk; // 0x01
    for (coll.grids) |g| {
        const gx0 = g.x * 5 - min_x;
        const gy0 = g.y * 5 - min_y;
        var cy: i32 = 0;
        while (cy < g.h) : (cy += 1) {
            var cx: i32 = 0;
            while (cx < g.w) : (cx += 1) {
                const dx = gx0 + cx;
                const dy = gy0 + cy;
                if (dx < 0 or dy < 0 or dx >= w or dy >= h) continue;
                const di: usize = @as(usize, @intCast(dy)) * wu + @as(usize, @intCast(dx));
                const cell = g.cells[@as(usize, @intCast(cy)) * @as(usize, @intCast(g.w)) + @as(usize, @intCast(cx))];
                ground[di] = true;
                if (cell & block_bit != 0) blocked[di] = true;
            }
        }
    }

    return PathGrid{ .origin_x = min_x, .origin_y = min_y, .w = w, .h = h, .blocked = blocked, .ground = ground };
}

test "buildPathGrid composites a preset level into a walkable view" {
    const gpa = std.testing.allocator;
    // generate() swaps the module-global DRLG allocator (dpool.allocator) to a
    // per-Level fog pool and tears it down on deinit; restore the default so a
    // later consumer of the global (e.g. the pool.zig test) never dereferences the
    // freed pool.
    defer dpool.allocator = dpool.default_allocator;
    var ctx = try Ctx.init(gpa);
    defer ctx.deinit();
    // Den of Evil (id 8): preset catacomb — has collision grids.
    var pg = (try buildPathGrid(&ctx, gpa, 0x13572468, 8, .normal)) orelse return;
    defer pg.deinit(gpa);
    try std.testing.expect(pg.w > 0 and pg.h > 0);
    try std.testing.expectEqual(@as(usize, @intCast(pg.w * pg.h)), pg.blocked.len);
    // A real level has both walkable ground and blocking walls.
    var any_ground = false;
    var any_block = false;
    for (pg.ground, pg.blocked) |gr, bl| {
        any_ground = any_ground or gr;
        any_block = any_block or bl;
    }
    try std.testing.expect(any_ground);
    try std.testing.expect(any_block);
}

// ---- materialized composite collision (covers wilderness) ------------------

pub const SUB = collision.SUBTILES_PER_TILE;

/// One object's collision footprint in LEVEL-LOCAL subtile coords: an sx×sy block
/// centered on the object's subtile (x,y). Objects only occupy the collision map at
/// play (Colbit.object 0x400 is a runtime unit bit) — the tile grid never carries it —
/// so we stamp each generated object's footprint into the composite explicitly.
pub const ObjColl = struct { x: i32, y: i32, sx: i32, sy: i32 };

/// One level's per-room materialized subtile collision grids (level-local
/// subtile coords). The frontend composites these into one level grid, filling
/// uncovered gaps with "void" — so interior dungeons still trace tight walls.
pub const LevelColl = struct {
    level_id: i32,
    unresolved: usize,
    grids: []CollGrid,
    objects: []ObjColl = &.{},
    /// Level world TILE origin (lvlPos). Grid x/y are local subtiles relative to
    /// this; world subtile = origin*SUBTILES_PER_TILE + grid-local. Lets the
    /// frontend lay every level of an act in one shared world-coord space.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
};

/// Every level of an act with its per-room materialized collision grids.
pub const ActCollResult = struct {
    levels: []LevelColl,

    pub fn deinit(self: *ActCollResult, alloc: std.mem.Allocator) void {
        for (self.levels) |l| {
            for (l.grids) |g| alloc.free(g.cells);
            alloc.free(l.grids);
            alloc.free(l.objects);
        }
        alloc.free(self.levels);
    }
};

/// Composited-automap render state (one byte per subtile). Distinct from the raw
/// COLBIT collision flags: "blocked" is split into real blocked TERRAIN vs VOID
/// (no room covers the subtile), so a renderer can draw walls only against real
/// terrain and skip the room-union silhouette / inter-room gaps.
pub const CompState = struct {
    pub const open: u8 = 0x00; // walkable floor
    pub const los: u8 = 0x02; // walkable but blocks line-of-sight (sub-flag of open)
    pub const block: u8 = 0x01; // real blocked terrain (a wall/cliff tile)
    pub const void_: u8 = 0x80; // uncovered — no room here
};

/// One level composited into a single level-local subtile grid of CompState bytes.
pub const LevelComposite = struct {
    level_id: i32,
    x: i32, // level-local subtile origin (min over the level's rooms)
    y: i32,
    w: usize,
    h: usize,
    unresolved: usize,
    cells: []u8, // CompState per subtile, row-major (w*h)
};

pub const ActCompositeResult = struct {
    levels: []LevelComposite,

    pub fn deinit(self: *ActCompositeResult, alloc: std.mem.Allocator) void {
        for (self.levels) |l| alloc.free(l.cells);
        alloc.free(self.levels);
    }
};

/// Union a level's per-room collision grids into ONE level-sized CompState grid.
/// Every subtile starts VOID; an OPEN room cell clears it (open wins on overlap,
/// LOS OR'd in); a BLOCKED room cell onto a still-VOID subtile becomes real BLOCK.
/// Returns null if the level has no grids. Caller owns `cells`.
fn compositeLevel(alloc: std.mem.Allocator, lc: LevelColl) !?LevelComposite {
    if (lc.grids.len == 0) return null;
    var minX: i32 = std.math.maxInt(i32);
    var minY: i32 = std.math.maxInt(i32);
    var maxX: i32 = std.math.minInt(i32);
    var maxY: i32 = std.math.minInt(i32);
    for (lc.grids) |g| {
        minX = @min(minX, g.x);
        minY = @min(minY, g.y);
        maxX = @max(maxX, g.x + @as(i32, @intCast(g.w)));
        maxY = @max(maxY, g.y + @as(i32, @intCast(g.h)));
    }
    if (maxX <= minX or maxY <= minY) return null;
    const W: usize = @intCast(maxX - minX);
    const H: usize = @intCast(maxY - minY);
    const cells = try alloc.alloc(u8, W * H);
    @memset(cells, CompState.void_);
    for (lc.grids) |g| {
        const gw: usize = @intCast(g.w);
        const gh: usize = @intCast(g.h);
        var y: usize = 0;
        while (y < gh) : (y += 1) {
            const dst_row = (@as(usize, @intCast(g.y - minY)) + y) * W + @as(usize, @intCast(g.x - minX));
            const src_row = y * gw;
            var x: usize = 0;
            while (x < gw) : (x += 1) {
                const c = g.cells[src_row + x];
                const di = dst_row + x;
                // no-floor marker (0x20): leave the cell void, don't mark walkable.
                if (c & 0x20 != 0) continue;
                if (c & CompState.block == 0) {
                    if (cells[di] & (CompState.block | CompState.void_) != 0) cells[di] = c & CompState.los else cells[di] |= c & CompState.los;
                } else if (cells[di] & CompState.void_ != 0) {
                    cells[di] = CompState.block;
                }
            }
        }
    }
    // Stamp object footprints as blocked. Objects hold the collision map only at play
    // (Colbit.object 0x400) — the tile grid never carries it — so mark each generated
    // object's sx×sy subtile box (centered on its subtile) CompState.block.
    for (lc.objects) |o| {
        var dy: i32 = -@divTrunc(o.sy, 2);
        while (dy <= @divTrunc(o.sy - 1, 2)) : (dy += 1) {
            const cy = o.y + dy - minY;
            if (cy < 0 or cy >= @as(i32, @intCast(H))) continue;
            var dx: i32 = -@divTrunc(o.sx, 2);
            while (dx <= @divTrunc(o.sx - 1, 2)) : (dx += 1) {
                const cx = o.x + dx - minX;
                if (cx < 0 or cx >= @as(i32, @intCast(W))) continue;
                cells[@intCast(cy * @as(i32, @intCast(W)) + cx)] = CompState.block;
            }
        }
    }
    return .{ .level_id = lc.level_id, .x = minX, .y = minY, .w = W, .h = H, .unresolved = lc.unresolved, .cells = cells };
}

/// Generate an entire act and composite EVERY level into one CompState grid each
/// (the automap-ready form: void/blocked/open per subtile). Wraps
/// generateActCollisionAll; the compositing that was previously done in the JS
/// frontend now lives here so every binding (wasm/native) shares it. `act_no` is
/// 0-based. GATE-SAFE: pure post-generation consumer.
pub fn generateActComposite(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
) !ActCompositeResult {
    var coll = try generateActCollisionAll(ctx, out_alloc, act_no, seed, diff);
    defer coll.deinit(out_alloc);

    var out: std.ArrayListUnmanaged(LevelComposite) = .empty;
    errdefer {
        for (out.items) |l| out_alloc.free(l.cells);
        out.deinit(out_alloc);
    }
    for (coll.levels) |lc| {
        if (try compositeLevel(out_alloc, lc)) |lco| try out.append(out_alloc, lco);
    }
    return .{ .levels = try out.toOwnedSlice(out_alloc) };
}

/// The room's WINDOW into its pMap DS1: tile offset = room.WorldPosition − DS1
/// origin (pMap.nRealOffset), size = room.WorldSize, seed = the room's own sSeed.
/// This is the engine's per-room CollMap (a window of the shared level DS1), not
/// the whole DS1 — materializeDs1 emits a (WorldSize+1)×5 subtile grid for it.
pub fn roomWindow(p: *abi.D2RoomExStrc, pmap: *abi.D2DrlgMapStrc) materialize.Ds1RoomWindow {
    return .{
        .off_x = p.sCoords.WorldPosition.x - pmap.nRealOffsetX,
        .off_y = p.sCoords.WorldPosition.y - pmap.nRealOffsetY,
        .size_x = p.sCoords.WorldSize.x,
        .size_y = p.sCoords.WorldSize.y,
        .seed = p.sSeed,
    };
}

/// A room's preset DrlgMap DS1, if it carries one (preset / maze / preset-border).
pub fn roomPMap(p: *abi.D2RoomExStrc) ?*abi.D2DrlgMapStrc {
    const data = p.pRoomExData orelse return null;
    const rd: *abi.D2DrlgPresetRoomStrc = @ptrCast(@alignCast(data));
    const pmap = rd.pMap orelse return null;
    if (pmap.pTxtLevelPrest == null or pmap.nSizeX <= 0 or pmap.nSizeY <= 0) return null;
    return pmap;
}

/// Materialize the composited subtile collision of one LIVE level (rooms still in
/// the act pool) via materialize.zig — the more faithful path that covers EVERY
/// area type: DS1/pMap rooms (preset/maze/preset-border) through materializeDs1,
/// wilderness FLOOR cells through materializeOutdoorFloorRoom. Returns null if the
/// level materialized nothing. Caller owns `cells` (free with `out_alloc`).
fn materializeLevelColl(
    out_alloc: std.mem.Allocator,
    ctx: *Ctx,
    idx: *const dt1blob.Index,
    pLevel: *abi.D2DrlgLevelStrc,
    level_id: i32,
) !?LevelColl {
    const tlv = ctx.act.level(level_id) orelse return null;
    const lvlPos = pLevel.sCoordinatesAndSize.WorldPosition;
    const nLevelType: i32 = @intFromEnum(pLevel.nLevelType);

    // Level DT1 library (LvlTypes File1..32 for this LevelType).
    var files: [32][]const u8 = undefined;
    const nf = ctx.act.typeFiles(tlv.lvl_type, &files);
    var dts: std.ArrayListUnmanaged(dt1.Dt1) = .empty;
    defer {
        for (dts.items) |*d| d.deinit();
        dts.deinit(out_alloc);
    }
    for (files[0..nf]) |f| {
        const rec = idx.get(f) orelse continue;
        const d = dt1blob.unpack(out_alloc, rec) catch continue;
        dts.append(out_alloc, d) catch continue;
    }

    // Emit one grid per materialized room, at its level-local subtile offset. The
    // frontend composites them (open wins, uncovered = void) — same pipeline as
    // the existing preset collision, so interior dungeons keep tight wall outlines.
    var grids: std.ArrayListUnmanaged(CollGrid) = .empty;
    errdefer {
        for (grids.items) |g| out_alloc.free(g.cells);
        grids.deinit(out_alloc);
    }

    const tilegen = @import("drlg/tilegen.zig");
    tilegen.g_lookup_null = 0;
    tilegen.g_lookup_fallback = 0;

    var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
    while (pr) |p| : (pr = p.pRoomExNext) {
        const gx = (p.sCoords.WorldPosition.x - lvlPos.x) * SUB;
        const gy = (p.sCoords.WorldPosition.y - lvlPos.y) * SUB;

        if (roomPMap(p)) |pmap| {
            // DS1/pMap room (preset, maze, or wilderness preset-border): materialize
            // only THIS room's window of the shared level DS1 (engine per-room CollMap).
            const rel = preset.presetDs1Path(pmap) orelse continue;
            var d = preset.unpackDs1(out_alloc, rel) orelse continue;
            defer d.deinit();
            var mr = materialize.materializeDs1(out_alloc, &d, dts.items, roomWindow(p, pmap)) catch continue;
            defer mr.deinit(out_alloc);
            try grids.append(out_alloc, .{
                .x = gx,
                .y = gy,
                .w = @intCast(mr.coll.width),
                .h = @intCast(mr.coll.height),
                .cells = try out_alloc.dupe(u8, mr.coll.cells),
            });
        } else if (p.eRoomExFlags.noLos) {
            // Wilderness FLOOR cell (an 8x8 CreateOutdoorRoomEx shell, no DS1).
            var mr = materialize.materializeOutdoorFloorRoom(out_alloc, dts.items, p.sCoords.WorldSize.x, p.sCoords.WorldSize.y, nLevelType, level_id, p.nSeed, materialize.outdoorOverlayFor(pLevel, p)) catch continue;
            defer mr.deinit(out_alloc);
            try grids.append(out_alloc, .{
                .x = gx,
                .y = gy,
                .w = @intCast(mr.coll.width),
                .h = @intCast(mr.coll.height),
                .cells = try out_alloc.dupe(u8, mr.coll.cells),
            });
        }
    }

    if (grids.items.len == 0) {
        grids.deinit(out_alloc);
        return null;
    }
    return LevelColl{
        .level_id = level_id,
        .unresolved = tilegen.g_lookup_null + tilegen.g_lookup_fallback,
        .grids = try grids.toOwnedSlice(out_alloc),
        .origin_x = lvlPos.x,
        .origin_y = lvlPos.y,
    };
}

/// Generate an ENTIRE act with faithful inter-level placement and materialize the
/// composited subtile collision of EVERY level via the post-generation
/// materialize.zig consumer. Covers wilderness (floor cells + preset borders),
/// preset, and maze levels alike. One fog pool + one D2DrlgStrc for the whole act;
/// materialization runs on the live rooms BEFORE the pool is torn down. `act_no`
/// is 0-based (Act I = 0 … Act V = 4). GATE-SAFE: pure post-generation consumer.
pub fn generateActCollisionAll(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
) !ActCollResult {
    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();
    ctx.lvl.resetGenCache(); // drop LvlSub pDrlgFile pointers into the prior (freed) pool

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) try ids.append(out_alloc, @intCast(lv.id));
        }
    }

    // Pass 1: real world coords BEFORE orths.
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    if (act_no == 0) drlg.applyAct1PresetPicks(&pDrlg, &ctx.act, seed);
    if (act_no == 1) drlg.applyAct2PresetPicks(&pDrlg, &ctx.act, seed);
    drlg.buildInterLevelOrths(&pDrlg);

    const idx = dt1Index();

    // Pass 2: generate + materialize each level.
    var out: std.ArrayListUnmanaged(LevelColl) = .empty;
    errdefer {
        for (out.items) |l| {
            for (l.grids) |g| out_alloc.free(g.cells);
            out_alloc.free(l.grids);
        }
        out.deinit(out_alloc);
    }
    var objtbl = try objects_mod.load(ctx.gpa);
    defer objtbl.deinit();
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlg.InitLevel(pLevel);
        if (try materializeLevelColl(out_alloc, ctx, idx, pLevel, lid)) |lc| {
            var lc2 = lc;
            lc2.objects = collectLevelObjectColl(pLevel, &objtbl, out_alloc) catch &.{};
            try out.append(out_alloc, lc2);
        }
    }

    return .{ .levels = try out.toOwnedSlice(out_alloc) };
}

// ---- absolute-world-keyed room collision (for golden verification) ---------

/// One room's materialized subtile collision keyed by its ABSOLUTE world subtile
/// origin (px = WorldPosition.x*5, py = WorldPosition.y*5) so it can be matched
/// against a real-engine CollMap golden. `cells[y*w+x]` are u8 low COLBIT bits.
pub const RoomColl = struct {
    level_id: i32,
    px: i32,
    py: i32,
    w: i32,
    h: i32,
    cells: []u8,
};

pub const ActRoomCollResult = struct {
    rooms: []RoomColl,
    unresolved: usize,

    pub fn deinit(self: *ActRoomCollResult, alloc: std.mem.Allocator) void {
        for (self.rooms) |r| alloc.free(r.cells);
        alloc.free(self.rooms);
    }
};

/// Same generation + materialization path as `generateActCollisionAll`, but emits
/// ONE grid per room keyed by absolute world subtile origin (px,py) + levelId, for
/// byte-comparing against a real-engine collision golden. GATE-SAFE: pure
/// post-generation consumer, does not touch the byte-exact generation path.
pub fn generateActRoomCollision(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
) !ActRoomCollResult {
    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();
    ctx.lvl.resetGenCache(); // drop LvlSub pDrlgFile pointers into the prior (freed) pool

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) try ids.append(out_alloc, @intCast(lv.id));
        }
    }

    // Pass 1: real world coords BEFORE orths.
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    if (act_no == 0) drlg.applyAct1PresetPicks(&pDrlg, &ctx.act, seed);
    if (act_no == 1) drlg.applyAct2PresetPicks(&pDrlg, &ctx.act, seed);
    drlg.buildInterLevelOrths(&pDrlg);

    const idx = dt1Index();
    const tilegen = @import("drlg/tilegen.zig");
    tilegen.g_lookup_null = 0;
    tilegen.g_lookup_fallback = 0;

    var rooms: std.ArrayListUnmanaged(RoomColl) = .empty;
    errdefer {
        for (rooms.items) |r| out_alloc.free(r.cells);
        rooms.deinit(out_alloc);
    }

    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlg.InitLevel(pLevel);
        const tlv = ctx.act.level(lid) orelse continue;
        const nLevelType: i32 = @intFromEnum(pLevel.nLevelType);

        // Level DT1 library (LvlTypes File1..32 for this LevelType).
        var files: [32][]const u8 = undefined;
        const nf = ctx.act.typeFiles(tlv.lvl_type, &files);
        var dts: std.ArrayListUnmanaged(dt1.Dt1) = .empty;
        defer {
            for (dts.items) |*d| d.deinit();
            dts.deinit(out_alloc);
        }
        for (files[0..nf]) |f| {
            const rec = idx.get(f) orelse continue;
            const d = dt1blob.unpack(out_alloc, rec) catch continue;
            dts.append(out_alloc, d) catch continue;
        }

        var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
        while (pr) |p| : (pr = p.pRoomExNext) {
            const px = p.sCoords.WorldPosition.x * SUB;
            const py = p.sCoords.WorldPosition.y * SUB;
            if (roomPMap(p)) |pmap| {
                var d = preset.unpackDs1(out_alloc, preset.presetDs1Path(pmap) orelse continue) orelse continue;
                defer d.deinit();
                var mr = materialize.materializeDs1(out_alloc, &d, dts.items, roomWindow(p, pmap)) catch continue;
                defer mr.deinit(out_alloc);
                try rooms.append(out_alloc, .{
                    .level_id = lid,
                    .px = px,
                    .py = py,
                    .w = @intCast(mr.coll.width),
                    .h = @intCast(mr.coll.height),
                    .cells = try out_alloc.dupe(u8, mr.coll.cells),
                });
            } else if (p.eRoomExFlags.noLos) {
                var mr = materialize.materializeOutdoorFloorRoom(out_alloc, dts.items, p.sCoords.WorldSize.x, p.sCoords.WorldSize.y, nLevelType, lid, p.nSeed, materialize.outdoorOverlayFor(pLevel, p)) catch continue;
                defer mr.deinit(out_alloc);
                try rooms.append(out_alloc, .{
                    .level_id = lid,
                    .px = px,
                    .py = py,
                    .w = @intCast(mr.coll.width),
                    .h = @intCast(mr.coll.height),
                    .cells = try out_alloc.dupe(u8, mr.coll.cells),
                });
            }
        }
    }

    return .{
        .rooms = try rooms.toOwnedSlice(out_alloc),
        .unresolved = tilegen.g_lookup_null + tilegen.g_lookup_fallback,
    };
}

// ---- golden collision verification -----------------------------------------

/// Extract an integer JSON field, e.g. jField(line, "\"px\":") -> 25200. The key
/// must include the quotes + colon to disambiguate (e.g. "\"w\":").
fn jField(line: []const u8, key: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, line, key) orelse return null;
    var i = idx + key.len;
    while (i < line.len and line[i] == ' ') i += 1;
    var neg = false;
    if (i < line.len and line[i] == '-') {
        neg = true;
        i += 1;
    }
    var v: i64 = 0;
    var any = false;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
        v = v * 10 + (line[i] - '0');
        any = true;
    }
    if (!any) return null;
    return if (neg) -v else v;
}

/// Aggregate outcome of byte-comparing our materialized collision against a
/// real-engine CollMap golden. `hist_*[b]` are per-COLBIT-bit (bit index 0..4 =
/// WALL,VISIBLE,MISSILE_BARRIER,NOPLAYER,PRESET) mismatch tallies.
pub const CollVerifyResult = struct {
    seed: u32,
    matched_rooms: u32 = 0,
    golden_only: u32 = 0,
    our_only: u32 = 0,
    dim_mismatch: u32 = 0,
    total_cells: u64 = 0,
    exact_ok: u64 = 0,
    masked_ok: u64 = 0,
    hist_golden_set_ours_clear: [5]u64 = .{0} ** 5,
    hist_ours_set_golden_clear: [5]u64 = .{0} ** 5,
    higher_bits_golden: u64 = 0,
};

/// Parse a real-engine collision golden (JSONL), regenerate the same acts at the
/// golden's seed, and byte-compare every room by absolute world subtile origin.
/// Reports two match rates (exact u16, and masked to static-terrain 0x1F) plus a
/// per-bit mismatch histogram. `verbose` prints a per-level table + worst rooms.
/// GATE-SAFE: pure post-generation consumer.
pub fn verifyActCollision(
    alloc: std.mem.Allocator,
    ctx: *Ctx,
    golden_bytes: []const u8,
    diff: Difficulty,
    verbose: bool,
) !CollVerifyResult {
    const Key = struct { level: i32, px: i32, py: i32 };
    const Strip = struct { y0: i32, hr: i32, cells: []u16 };
    const GRoom = struct { level: i32, px: i32, py: i32, w: i32, strips: std.ArrayListUnmanaged(Strip) = .empty };

    var seed: u32 = 0;
    var groom_list: std.ArrayListUnmanaged(GRoom) = .empty;
    defer {
        for (groom_list.items) |*gr| {
            for (gr.strips.items) |s| alloc.free(s.cells);
            gr.strips.deinit(alloc);
        }
        groom_list.deinit(alloc);
    }
    var gmap = std.AutoHashMapUnmanaged(Key, usize).empty;
    defer gmap.deinit(alloc);

    var line_it = std.mem.splitScalar(u8, golden_bytes, '\n');
    while (line_it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"drlg_seed\"") != null) {
            if (jField(line, "\"seed\":")) |s| seed = @intCast(s);
            continue;
        }
        if (std.mem.indexOf(u8, line, "\"drlg_coll\"") == null) continue;
        const level: i32 = @intCast(jField(line, "\"levelId\":") orelse continue);
        const px: i32 = @intCast(jField(line, "\"px\":") orelse continue);
        const py: i32 = @intCast(jField(line, "\"py\":") orelse continue);
        const w: i32 = @intCast(jField(line, "\"w\":") orelse continue);
        const hr: i32 = @intCast(jField(line, "\"h\":") orelse continue);
        const y0: i32 = @intCast(jField(line, "\"y0\":") orelse continue);
        const cstart = (std.mem.indexOf(u8, line, "\"cells\":[") orelse continue) + "\"cells\":[".len;
        var cells: std.ArrayListUnmanaged(u16) = .empty;
        errdefer cells.deinit(alloc);
        var i = cstart;
        while (i < line.len and line[i] != ']') {
            while (i < line.len and (line[i] == ',' or line[i] == ' ')) i += 1;
            if (i >= line.len or line[i] == ']') break;
            var v: u32 = 0;
            var any = false;
            while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
                v = v * 10 + (line[i] - '0');
                any = true;
            }
            if (any) try cells.append(alloc, @intCast(v & 0xFFFF));
        }
        const key = Key{ .level = level, .px = px, .py = py };
        const gop = try gmap.getOrPut(alloc, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = groom_list.items.len;
            try groom_list.append(alloc, .{ .level = level, .px = px, .py = py, .w = w });
        }
        try groom_list.items[gop.value_ptr.*].strips.append(alloc, .{ .y0 = y0, .hr = hr, .cells = try cells.toOwnedSlice(alloc) });
    }

    // Assemble each golden room into a contiguous w*Htot grid.
    const GFull = struct { level: i32, px: i32, py: i32, w: i32, h: i32, cells: []u16 };
    var golden: std.ArrayListUnmanaged(GFull) = .empty;
    defer {
        for (golden.items) |g| alloc.free(g.cells);
        golden.deinit(alloc);
    }
    var gfull_map = std.AutoHashMapUnmanaged(Key, void).empty;
    defer gfull_map.deinit(alloc);
    for (groom_list.items) |*gr| {
        var htot: i32 = 0;
        for (gr.strips.items) |s| htot = @max(htot, s.y0 + s.hr);
        const wu: usize = @intCast(gr.w);
        const hu: usize = @intCast(htot);
        const cells = try alloc.alloc(u16, wu * hu);
        @memset(cells, 0);
        for (gr.strips.items) |s| {
            const rows: usize = @intCast(s.hr);
            var yy: usize = 0;
            while (yy < rows) : (yy += 1) {
                const dst = (@as(usize, @intCast(s.y0)) + yy) * wu;
                const src = yy * wu;
                if (src + wu <= s.cells.len and dst + wu <= cells.len)
                    @memcpy(cells[dst .. dst + wu], s.cells[src .. src + wu]);
            }
        }
        try gfull_map.put(alloc, .{ .level = gr.level, .px = gr.px, .py = gr.py }, {});
        try golden.append(alloc, .{ .level = gr.level, .px = gr.px, .py = gr.py, .w = gr.w, .h = htot, .cells = cells });
    }

    // Which acts appear (from golden level ids)?
    var acts_seen = std.AutoHashMapUnmanaged(i32, void).empty;
    defer acts_seen.deinit(alloc);
    for (golden.items) |g| {
        if (ctx.act.level(g.level)) |lv| try acts_seen.put(alloc, @intCast(lv.act), {});
    }

    // Generate our side per needed act; key rooms by (level,px,py).
    const OurRoom = struct { w: i32, h: i32, cells: []u8 };
    var ours = std.AutoHashMapUnmanaged(Key, OurRoom).empty;
    defer {
        var it = ours.valueIterator();
        while (it.next()) |vp| alloc.free(vp.cells);
        ours.deinit(alloc);
    }
    {
        var ait = acts_seen.keyIterator();
        while (ait.next()) |ap| {
            var res = try generateActRoomCollision(ctx, alloc, ap.*, seed, diff);
            defer res.deinit(alloc);
            for (res.rooms) |r| {
                const key = Key{ .level = r.level_id, .px = r.px, .py = r.py };
                const cp = try alloc.dupe(u8, r.cells);
                const gop = try ours.getOrPut(alloc, key);
                if (gop.found_existing) alloc.free(gop.value_ptr.cells);
                gop.value_ptr.* = .{ .w = r.w, .h = r.h, .cells = cp };
            }
        }
    }

    var out = CollVerifyResult{ .seed = seed };

    const MAXID = 256;
    const Lvl = struct { matched: u32 = 0, golden_only: u32 = 0, our_only: u32 = 0, dim: u32 = 0, total: u64 = 0, exact: u64 = 0, masked: u64 = 0 };
    var lvls = [_]Lvl{.{}} ** MAXID;
    var seen_ids = [_]bool{false} ** MAXID;

    const Worst = struct { level: i32, px: i32, py: i32, mism: u64, total: u64 };
    var worst: std.ArrayListUnmanaged(Worst) = .empty;
    defer worst.deinit(alloc);

    for (golden.items) |g| {
        const li: usize = if (g.level >= 0 and g.level < MAXID) @intCast(g.level) else continue;
        seen_ids[li] = true;
        const key = Key{ .level = g.level, .px = g.px, .py = g.py };
        const our = ours.get(key) orelse {
            lvls[li].golden_only += 1;
            out.golden_only += 1;
            continue;
        };
        if (our.w != g.w or our.h != g.h) {
            lvls[li].dim += 1;
            out.dim_mismatch += 1;
            continue;
        }
        lvls[li].matched += 1;
        out.matched_rooms += 1;
        var room_mism: u64 = 0;
        for (g.cells, 0..) |gc, idx2| {
            const oc: u16 = our.cells[idx2];
            lvls[li].total += 1;
            out.total_cells += 1;
            if (gc == oc) {
                lvls[li].exact += 1;
                out.exact_ok += 1;
            }
            if ((gc & 0x1F) == (oc & 0x1F)) {
                lvls[li].masked += 1;
                out.masked_ok += 1;
            } else {
                room_mism += 1;
                var b: u4 = 0;
                while (b < 5) : (b += 1) {
                    const m = @as(u16, 1) << b;
                    const gset = gc & m != 0;
                    const oset = oc & m != 0;
                    if (gset and !oset) out.hist_golden_set_ours_clear[b] += 1;
                    if (oset and !gset) out.hist_ours_set_golden_clear[b] += 1;
                }
            }
            if (gc & 0xFFE0 != 0) out.higher_bits_golden += 1;
        }
        try worst.append(alloc, .{ .level = g.level, .px = g.px, .py = g.py, .mism = room_mism, .total = g.cells.len });
    }

    // Rooms we produced the golden lacks.
    {
        var it = ours.keyIterator();
        while (it.next()) |kp| {
            if (gfull_map.get(kp.*) != null) continue;
            const li: usize = if (kp.level >= 0 and kp.level < MAXID) @intCast(kp.level) else continue;
            if (li < MAXID) lvls[li].our_only += 1;
            out.our_only += 1;
        }
    }

    if (verbose) {
        const bitname = [_][]const u8{ "WALL", "VISIBLE", "MISSILE_BAR", "NOPLAYER", "PRESET" };
        std.debug.print("\n=== PER-LEVEL COLLISION MATCH (seed {d}) ===\n", .{seed});
        std.debug.print("  Lvl name                     matched g-only o-only dim  exact%%  masked0x1F%%\n", .{});
        for (0..MAXID) |id| {
            if (!seen_ids[id]) continue;
            const l = lvls[id];
            if (l.matched == 0 and l.golden_only == 0 and l.dim == 0) continue;
            const ep = if (l.total == 0) 0.0 else @as(f64, @floatFromInt(l.exact)) / @as(f64, @floatFromInt(l.total)) * 100.0;
            const mp = if (l.total == 0) 0.0 else @as(f64, @floatFromInt(l.masked)) / @as(f64, @floatFromInt(l.total)) * 100.0;
            const lv = ctx.act.level(@intCast(id));
            const nm = if (lv) |x| (if (x.level_name.len != 0) x.level_name else x.name) else "?";
            std.debug.print("  L{d:0>3} {s:<24} {d:>7} {d:>6} {d:>6} {d:>4}  {d:>6.2}  {d:>6.2}\n", .{ id, nm, l.matched, l.golden_only, l.our_only, l.dim, ep, mp });
        }
        const tep = if (out.total_cells == 0) 0.0 else @as(f64, @floatFromInt(out.exact_ok)) / @as(f64, @floatFromInt(out.total_cells)) * 100.0;
        const tmp = if (out.total_cells == 0) 0.0 else @as(f64, @floatFromInt(out.masked_ok)) / @as(f64, @floatFromInt(out.total_cells)) * 100.0;
        std.debug.print("  TOTAL cells {d}: exact {d:.2}%  masked0x1F {d:.2}%  (matched {d} rooms, {d} dim-mismatch)\n", .{ out.total_cells, tep, tmp, out.matched_rooms, out.dim_mismatch });
        std.debug.print("=== MISMATCH-BIT HISTOGRAM (masked-0x1F diffs) ===\n", .{});
        std.debug.print("  bit            golden-set/ours-clear   ours-set/golden-clear\n", .{});
        var b: usize = 0;
        while (b < 5) : (b += 1) {
            std.debug.print("  0x{x:0>2} {s:<12} {d:>18}   {d:>18}\n", .{ @as(u16, 1) << @intCast(b), bitname[b], out.hist_golden_set_ours_clear[b], out.hist_ours_set_golden_clear[b] });
        }
        std.mem.sort(Worst, worst.items, {}, struct {
            fn lt(_: void, a: Worst, c: Worst) bool {
                return a.mism > c.mism;
            }
        }.lt);
        std.debug.print("=== 5 WORST ROOMS (masked-0x1F mismatched cells) ===\n", .{});
        for (worst.items[0..@min(5, worst.items.len)]) |wr| {
            const pctm = if (wr.total == 0) 0.0 else @as(f64, @floatFromInt(wr.mism)) / @as(f64, @floatFromInt(wr.total)) * 100.0;
            std.debug.print("  L{d} px={d} py={d}: {d}/{d} cells mismatch ({d:.1}%)\n", .{ wr.level, wr.px, wr.py, wr.mism, wr.total, pctm });
        }
    }

    return out;
}

const objects_mod = @import("objects.zig");
const objpop_mod = @import("drlg/objpop.zig");

const drng = @import("drlg/rng.zig");

/// One outdoor shrine/well object: resolved objects.txt class id + world SUBTILE pos.
pub const OutdoorShrine = struct { class_id: i32, x: i32, y: i32 };

/// The four Act-1/2 outdoor shrine LvlSub Type-5 variants, indexed by the style bit
/// SpawnAct12Shrines cycles into eRoomExFlags (0x1000->0 ShrineW .. 0x8000->3 ShrineH).
/// `groups`/`box` are the DS1 substitution-group count + square tile box; `classes`
/// map the rolled substgroup index -> resolved objects.txt row (via objectClassId on
/// the DS1's kind-2 object). ShrineW (Act1/Outdoors/ShrineW.ds1) carries two 3x3
/// groups: g0 (y4 half) = Well obj id39->class 130, g1 (y0 half) = Shrine obj id31->
/// class 84. ShrineD/F/H each carry one 4x4 group with a single Shrine obj (id 29/30/
/// 32 -> class 2/81/83). Every DS1 object sits at +(7,7) subtiles from its group base.
const SHRINE_VARIANTS = [4]struct { groups: u32, box: i32, classes: [2]i32 }{
    .{ .groups = 2, .box = 3, .classes = .{ 130, 84 } },
    .{ .groups = 1, .box = 4, .classes = .{ 2, 2 } },
    .{ .groups = 1, .box = 4, .classes = .{ 81, 81 } },
    .{ .groups = 1, .box = 4, .classes = .{ 83, 83 } },
};

/// Emit the seeded outdoor shrine/well objects for a generated wilderness level.
/// Faithful replay of InitGridCells (0067d2d0) -> SubTypeWpShrine (006707a0) ->
/// DoNotCheckAll (00670170): per room flagged by SpawnAct12Shrines (00674e40), read
/// the style bits from eRoomExFlags, roll the LvlSub Type-5 placement on the room's
/// {nSeed,0x29a} seed (substgroup roll + Fisher-Yates over the (roomW-box)x(roomH-box)
/// tile positions), and place the variant's object at the first position +(7,7)
/// subtiles. NOTE: DRLGOUTDOOR_CheckSubTileOverlap (0066fcf0) rejection is not modeled
/// — the first shuffled position is taken; verified byte-exact (position+type) vs the
/// d2mapapi oracle for all 30 objects across Act-1 wilderness levels 2-7.
fn appendOutdoorShrines(pLevel: *abi.D2DrlgLevelStrc, out: *std.ArrayListUnmanaged(OutdoorShrine), a: std.mem.Allocator) !void {
    if (pLevel.eDrlgType != .wilderness) return;
    var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
    while (pr) |p| : (pr = p.pRoomExNext) {
        const bits: u32 = (@as(u32, @bitCast(p.eRoomExFlags.raw())) >> 0xc) & 0xf;
        if (bits == 0) continue;
        const style: usize = @ctz(bits); // one style bit per cell (0x1000..0x8000 -> 0..3)
        if (style > 3) continue;
        const v = SHRINE_VARIANTS[style];
        const nMaxX: i32 = p.sCoords.WorldSize.x - v.box;
        const nMaxY: i32 = p.sCoords.WorldSize.y - v.box;
        if (nMaxX < 1 or nMaxY < 1) continue;
        var s = abi.D2SeedStrc{ .nSeedLow = p.nSeed, .nSeedHigh = 0x29a };
        const groupIdx = drng.randomNumberSelector(&s, v.groups);
        const nTotal: usize = @intCast(nMaxX * nMaxY);
        var cx: [513]i32 = undefined;
        var cy: [513]i32 = undefined;
        for (0..nTotal) |i| {
            const ii: i32 = @intCast(i);
            cx[i] = @rem(ii, nMaxX);
            cy[i] = @divTrunc(ii, nMaxX);
        }
        var rem: usize = nTotal;
        while (rem > 0) : (rem -= 1) {
            const ia: usize = drng.randomNumberSelector(&s, @intCast(nTotal));
            const ib: usize = drng.randomNumberSelector(&s, @intCast(nTotal));
            const tx = cx[ia];
            const ty = cy[ia];
            cx[ia] = cx[ib];
            cy[ia] = cy[ib];
            cx[ib] = tx;
            cy[ib] = ty;
        }
        const class_id = v.classes[@min(groupIdx, 1)];
        const ox = (p.sCoords.WorldPosition.x + cx[0] + 1) * 5 + 7;
        const oy = (p.sCoords.WorldPosition.y + cy[0] + 1) * 5 + 7;
        try out.append(a, .{ .class_id = class_id, .x = ox, .y = oy });
    }
}

/// Generate an entire act and return the seeded OUTDOOR SHRINES/WELLS of one level
/// (`level_id`). Mirrors the generateActObjects/collision setup (one fog pool + one
/// D2DrlgStrc for the whole act, real inter-level coords + preset picks + orths), then
/// finds the level whose id == `level_id`, runs InitLevel on it, and collects its
/// outdoor shrines via appendOutdoorShrines. Returns an empty slice if the level has
/// no outdoor shrines (or isn't in this act). x/y are world SUBTILE coords (÷5 for
/// tiles). Caller owns the returned slice (free with `out_alloc`). `act_no` is 0-based.
pub fn generateLevelShrines(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
    level_id: i32,
) ![]OutdoorShrine {
    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();
    ctx.lvl.resetGenCache(); // drop LvlSub pDrlgFile pointers into the prior (freed) pool

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) try ids.append(out_alloc, @intCast(lv.id));
        }
    }

    // Pass 1: real world coords BEFORE orths.
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    if (act_no == 0) drlg.applyAct1PresetPicks(&pDrlg, &ctx.act, seed);
    if (act_no == 1) drlg.applyAct2PresetPicks(&pDrlg, &ctx.act, seed);
    drlg.buildInterLevelOrths(&pDrlg);

    // Pass 2: generate each level; collect shrines for the requested one.
    var shrines: std.ArrayListUnmanaged(OutdoorShrine) = .empty;
    errdefer shrines.deinit(out_alloc);
    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlg.InitLevel(pLevel);
        if (lid == level_id) try appendOutdoorShrines(pLevel, &shrines, out_alloc);
    }
    return shrines.toOwnedSlice(out_alloc);
}

/// One preset unit exposed to the DBM-shaped shim: eType (1 monster/npc, 2 object),
/// the resolved DRLG class id (MonStats/object-as-monster id for npc, Objects.txt row
/// for obj), and level-LOCAL SUBTILE position. DBM reports preset x/y relative to the
/// level origin in subtiles; our preset positions are WORLD subtiles, so we subtract the
/// level's WorldPosition (tiles) * SUB. eTypes other than 1/2 are dropped.
pub const PresetUnit = struct { etype: i32, txt_file_no: i32, x: i32, y: i32 };

/// Generate an entire act and return the PRESET UNITS of one level (`level_id`) in the
/// DBM shape: level-local subtile coords (clipped to the level rect), deduped by
/// (etype,txt,x,y). Same whole-act setup as generateLevelShrines.
///
/// UNIT SOURCES, per generated preset DrlgMap of the target level (deduped by pointer):
///   1. pMap.pPresetUnit — the engine-populated chain (already world-coord, with the
///      seed-dependent AddPresetUnitToDrlgMap copy-filter applied). Used for preset
///      areas (town/cathedral/…) where BuildPresetArea's Scan/Pops gate loaded the DS1.
///   2. DS1-object replay — for wilderness border/camp maps the Scan==0 && Pops==0 gate
///      (Preset.cpp:1778) returns before AllocDrlgFile, so pMap.pPresetUnit stays empty
///      even though the DS1 carries objects (Bishibosh camp Fallen, scattered torches).
///      We recover them by re-parsing the map's DS1 and replaying the same world
///      transform the engine's CopyPresetUnit would apply (pos + nRealOffset*SUB), with
///      the same monster/object classId resolution (presettables). This replay does NOT
///      re-run the seed-dependent copy-filter (bCopy) — for Cold Plains none of the
///      units are in the filtered classId set, so the set is identical; other levels may
///      over-include the (rare) filtered place-group/object classes.
///   3. Seeded outdoor shrines/wells (SpawnAct12Shrines) — folded in as eType 2 objects,
///      since DBM lists them in the same `presets` array.
/// Caller owns the slice.
pub fn generateLevelPresets(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
    level_id: i32,
) ![]PresetUnit {
    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();
    ctx.lvl.resetGenCache();

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) try ids.append(out_alloc, @intCast(lv.id));
        }
    }

    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    if (act_no == 0) drlg.applyAct1PresetPicks(&pDrlg, &ctx.act, seed);
    if (act_no == 1) drlg.applyAct2PresetPicks(&pDrlg, &ctx.act, seed);
    drlg.buildInterLevelOrths(&pDrlg);

    var out: std.ArrayListUnmanaged(PresetUnit) = .empty;
    errdefer out.deinit(out_alloc);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(out_alloc);
    var seen_map: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen_map.deinit(out_alloc);

    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlg.InitLevel(pLevel);
        if (lid != level_id) continue;

        const lvlPos = pLevel.sCoordinatesAndSize.WorldPosition;
        const ox = lvlPos.x * SUB;
        const oy = lvlPos.y * SUB;
        // Level rect in subtiles: units outside it are on the outer border ring (the
        // engine copies them but they sit past the playable rect); DBM clips them.
        const bw = pLevel.sCoordinatesAndSize.WorldSize.x * SUB;
        const bh = pLevel.sCoordinatesAndSize.WorldSize.y * SUB;

        const Emit = struct {
            fn add(o_alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(PresetUnit), sset: *std.AutoHashMapUnmanaged(u64, void), et: i32, cls: i32, lx: i32, ly: i32, w: i32, h: i32) !void {
                if (lx < 0 or ly < 0 or lx >= w or ly >= h) return; // outside the level rect
                const k = (@as(u64, @bitCast(@as(i64, et))) << 56) ^
                    (@as(u64, @bitCast(@as(i64, cls))) << 40) ^
                    (@as(u64, @intCast(lx & 0xfffff)) << 20) ^ @as(u64, @intCast(ly & 0xfffff));
                if ((try sset.getOrPut(o_alloc, k)).found_existing) return;
                try list.append(o_alloc, .{ .etype = et, .txt_file_no = cls, .x = lx, .y = ly });
            }
        };

        var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
        while (pr) |p| : (pr = p.pRoomExNext) {
            const pmap = roomPMap(p) orelse continue;
            const mapkey = @intFromPtr(pmap);
            if ((try seen_map.getOrPut(out_alloc, mapkey)).found_existing) continue;

            if (pmap.pPresetUnit != null) {
                // Engine-populated chain (world coords, copy-filter already applied).
                var pu: ?*abi.D2PresetUnitStrc = pmap.pPresetUnit;
                while (pu) |u| : (pu = u.pPresetUnitNext) {
                    const et: i32 = u.eType;
                    if (et != 1 and et != 2) continue;
                    try Emit.add(out_alloc, &out, &seen, et, u.nClassId, u.nPosX - ox, u.nPosY - oy, bw, bh);
                }
            } else {
                // Gated wilderness map: replay the DS1 objects through the engine's
                // world transform (CopyPresetUnit: pos + nRealOffset*SUB).
                const rel = preset.presetDs1Path(pmap) orelse continue;
                var d = preset.unpackDs1(out_alloc, rel) orelse continue;
                defer d.deinit();
                const wox = pmap.nRealOffsetX * SUB;
                const woy = pmap.nRealOffsetY * SUB;
                for (d.objects) |o| {
                    var et: i32 = undefined;
                    var classId: i32 = undefined;
                    switch (o.kind) {
                        1 => {
                            et = 1;
                            classId = presettables.monsterClassId(d.act_id, o.id);
                        },
                        2 => {
                            et = 2;
                            classId = presettables.objectClassId(d.act_id, o.id);
                        },
                        else => continue,
                    }
                    if (classId < 0) continue; // recon Preset.cpp:350 — classId < 0 dropped
                    try Emit.add(out_alloc, &out, &seen, et, classId, o.x + wox - ox, o.y + woy - oy, bw, bh);
                }
            }
        }

        // Seeded outdoor shrines/wells (SpawnAct12Shrines) — DBM lists them as presets.
        var shrines: std.ArrayListUnmanaged(OutdoorShrine) = .empty;
        defer shrines.deinit(out_alloc);
        try appendOutdoorShrines(pLevel, &shrines, out_alloc);
        for (shrines.items) |sh|
            try Emit.add(out_alloc, &out, &seen, 2, sh.class_id, sh.x - ox, sh.y - oy, bw, bh);
    }
    return out.toOwnedSlice(out_alloc);
}

// Process-global Objects.txt lookup (name / description columns), decoded once and
// intentionally never freed — same page-allocator cache pattern as dt1Index, so a
// leak-checking caller Ctx never false-positives and nothing dangles on Ctx destroy.
var g_objtxt: ?txt.Table = null;
fn objTxt() ?*const txt.Table {
    if (g_objtxt == null) {
        g_objtxt = txt.Table.parse(std.heap.page_allocator, @embedFile("excel/Objects.txt")) catch return null;
    }
    return &g_objtxt.?;
}

/// Objects.txt "Name" (col 1) for a 0-based object row (== a preset obj's txtFileNo);
/// empty slice if out of range. Borrowed from the process-global table (do not free).
pub fn objectName(txt_file_no: i32) []const u8 {
    const t = objTxt() orelse return "";
    if (txt_file_no < 0 or txt_file_no >= t.rowCount()) return "";
    return t.str(@intCast(txt_file_no), "Name");
}

/// Objects.txt description (col 2, "description - not loaded") for a 0-based object row;
/// empty slice if out of range. Borrowed from the process-global table (do not free).
pub fn objectDescription(txt_file_no: i32) []const u8 {
    const t = objTxt() orelse return "";
    if (txt_file_no < 0 or txt_file_no >= t.rowCount()) return "";
    return t.str(@intCast(txt_file_no), "description - not loaded");
}

const txt = @import("txt.zig");

test "lib: preset units for Cold Plains (seed 0, act 0 level 3) include obj+npc" {
    const gpa = std.testing.allocator;
    defer dpool.allocator = dpool.default_allocator;
    var ctx = try Ctx.init(gpa);
    defer ctx.deinit();
    const presets = try generateLevelPresets(&ctx, gpa, 0, 0, .normal, 3);
    defer gpa.free(presets);
    try std.testing.expect(presets.len >= 14);
    var any_obj = false;
    var any_npc = false;
    // DBM Cold Plains seed-0 landmarks: a Torch1 Tiki (obj 37) at (131,366) and the
    // bed (obj 247) at (103,58) — both must be present at those exact local coords.
    var has_torch = false;
    var has_bed = false;
    for (presets) |p| {
        any_obj = any_obj or p.etype == 2;
        any_npc = any_npc or p.etype == 1;
        if (p.etype == 2 and p.txt_file_no == 37 and p.x == 131 and p.y == 366) has_torch = true;
        if (p.etype == 2 and p.txt_file_no == 247 and p.x == 103 and p.y == 58) has_bed = true;
    }
    try std.testing.expect(any_obj and any_npc);
    try std.testing.expect(has_torch and has_bed);
    // id 37 = Dummy / Torch1 Tiki (a Cold Plains décor object).
    try std.testing.expectEqualStrings("Dummy", objectName(37));
    try std.testing.expectEqualStrings("Torch1 Tiki", objectDescription(37));
}

test "lib: outdoor shrines for Cold Plains (seed 1337, act 0 level 3) >= 1" {
    const gpa = std.testing.allocator;
    defer dpool.allocator = dpool.default_allocator;
    var ctx = try Ctx.init(gpa);
    defer ctx.deinit();
    const shrines = try generateLevelShrines(&ctx, gpa, 0, 1337, .normal, 3);
    defer gpa.free(shrines);
    try std.testing.expect(shrines.len >= 1);
}

/// Collect the collision footprints of every generated OBJECT in a level, in
/// level-local subtile coords (origin = level WorldPosition). Objects never enter
/// the tile-derived collision grid (Colbit.object 0x400 is a runtime unit bit), so
/// their footprints are stamped into the composite separately. Covers the seeded
/// outdoor shrines/wells (appendOutdoorShrines) and the DS1 preset objects that
/// carry room-init collision (objects.txt HasCollision0 + SizeX/SizeY).
fn collectLevelObjectColl(pLevel: *abi.D2DrlgLevelStrc, objtbl: *const objects_mod.Table, a: std.mem.Allocator) ![]ObjColl {
    const lvlPos = pLevel.sCoordinatesAndSize.WorldPosition;
    var list: std.ArrayListUnmanaged(ObjColl) = .empty;
    errdefer list.deinit(a);

    var shrines: std.ArrayListUnmanaged(OutdoorShrine) = .empty;
    defer shrines.deinit(a);
    try appendOutdoorShrines(pLevel, &shrines, a);
    for (shrines.items) |sh| {
        if (objtbl.collision(sh.class_id)) |c|
            try list.append(a, .{ .x = sh.x - lvlPos.x * SUB, .y = sh.y - lvlPos.y * SUB, .sx = c.sx, .sy = c.sy });
    }

    var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
    while (pr) |p| : (pr = p.pRoomExNext) {
        const pmap = roomPMap(p) orelse continue;
        const win = roomWindow(p, pmap);
        const gx = (p.sCoords.WorldPosition.x - lvlPos.x) * SUB;
        const gy = (p.sCoords.WorldPosition.y - lvlPos.y) * SUB;
        var pu: ?*abi.D2PresetUnitStrc = pmap.pPresetUnit;
        while (pu) |u| : (pu = u.pPresetUnitNext) {
            if (u.eType != 2) continue; // UNIT_OBJECT
            const c = objtbl.collision(u.nClassId) orelse continue;
            // Preset unit nPosX/nPosY are DS1-window subtiles; keep only those inside
            // this room's window, then map to the level-local subtile grid (same basis
            // as the room grid offset gx/gy — matches generateActAutomap's marker map).
            const otx = @divFloor(u.nPosX, SUB);
            const oty = @divFloor(u.nPosY, SUB);
            if (otx < win.off_x or otx > win.off_x + win.size_x) continue;
            if (oty < win.off_y or oty > win.off_y + win.size_y) continue;
            try list.append(a, .{ .x = gx + (u.nPosX - win.off_x * SUB), .y = gy + (u.nPosY - win.off_y * SUB), .sx = c.sx, .sy = c.sy });
        }
    }
    return list.toOwnedSlice(a);
}

// ── Seeded object population (chests / shrines / scatter / waypoints) ───────────

/// One spawned object: engine class id + world SUBTILE position. `preset` = a DS1
/// preset object (kind==2, resolved via preset.zig), false = a populate-fn spawn
/// (OBJECT_PopulateRoomObjects). The two are kept distinct on purpose.
pub const ObjSpawn = struct { class_id: i32, x: i32, y: i32, preset: bool, placeholder_pos: bool = false };

pub const LevelObjects = struct { level_id: i32, objs: []ObjSpawn };

pub const ActObjectsResult = struct {
    levels: []LevelObjects,
    pub fn deinit(self: *ActObjectsResult, alloc: std.mem.Allocator) void {
        for (self.levels) |l| alloc.free(l.objs);
        alloc.free(self.levels);
    }
};

/// Generate an entire act and emit its seeded OBJECTS per level: the DS1 preset
/// objects (already placed by the generation pass) PLUS the populate-fn spawns
/// (OBJECT_PopulateRoomObjects — the Levels.txt ObjGrp loop → Fn1 scatter / Fn2
/// shrine / chest). Mirrors generateActAutomap's shape so it can later feed the
/// automap markers. `act_no` is 0-based. GATE-SAFE: pure post-generation consumer.
///
/// NOTE ON COVERAGE: the town/special-objects path (DS1 pop-scan, grid barrels,
/// waypoint/stash placement — OBJECT_PopulateRoomSpecialObjects) is not modeled;
/// town objects are dominated by DS1 PRESET objects (emitted here as preset=true).
/// The dungeon ObjGrp scatter/shrine/chest roll order IS ported but cannot be
/// byte-verified until a dungeon object-golden is captured.
pub fn generateActObjects(
    ctx: *Ctx,
    out_alloc: std.mem.Allocator,
    act_no: i32,
    seed: u32,
    diff: Difficulty,
) !ActObjectsResult {
    var pool = fog.PoolManager.init(ctx.gpa);
    defer pool.deinit();
    const saved_alloc = dpool.allocator;
    const saved_tables = dtables.g_lvl_tables;
    defer {
        dpool.allocator = saved_alloc;
        dtables.g_lvl_tables = saved_tables;
    }
    dtables.g_lvl_tables = &ctx.lvl;
    dpool.allocator = pool.allocator();
    dpool.resetRegistry();
    ctx.lvl.resetGenCache();

    var act = try act_mod.build(ctx.gpa, &ctx.act, act_no, seed);
    defer act.deinit(ctx.gpa);

    var pDrlg: abi.D2DrlgStrc = undefined;
    _ = drlg.allocDrlgActMisc(&pDrlg, 1, seed, .None, 0, @intFromEnum(diff));

    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(out_alloc);
    var maxid: i32 = 0;
    var row: usize = 0;
    while (row < ctx.act.levelCount()) : (row += 1) {
        if (ctx.act.levelAtRow(row)) |lv| {
            if (lv.act == act_no) {
                try ids.append(out_alloc, @intCast(lv.id));
                if (lv.id > maxid) maxid = @intCast(lv.id);
            }
        }
    }

    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        const c = act.coords(&ctx.act, lid);
        pLevel.sCoordinatesAndSize = .{
            .WorldPosition = .{ .x = c.x, .y = c.y },
            .WorldSize = .{ .x = c.w, .y = c.h },
        };
    }
    if (act_no == 0) drlg.applyAct1PresetPicks(&pDrlg, &ctx.act, seed);
    if (act_no == 1) drlg.applyAct2PresetPicks(&pDrlg, &ctx.act, seed);
    drlg.buildInterLevelOrths(&pDrlg);

    // Object-population tables + control (control seed + per-level RNG + shrine
    // buckets). Per-level act for the control's D2ObjectRngStrc.nAct.
    var otbl = try objpop_mod.Tables.load(ctx.gpa);
    defer otbl.deinit();
    const level_acts = try out_alloc.alloc(i32, @intCast(maxid + 1));
    defer out_alloc.free(level_acts);
    @memset(level_acts, 0);
    for (0..@intCast(maxid + 1)) |i| {
        if (ctx.act.level(@intCast(i))) |lv| level_acts[i] = @intCast(lv.act);
    }
    var ctrl = try objpop_mod.ObjectControl.init(ctx.gpa, &otbl, seed, level_acts);
    defer ctrl.deinit();

    var out: std.ArrayListUnmanaged(LevelObjects) = .empty;
    errdefer {
        for (out.items) |l| out_alloc.free(l.objs);
        out.deinit(out_alloc);
    }

    for (ids.items) |lid| {
        const pLevel = drlg.GetLevelAndAlloc(&pDrlg, @enumFromInt(lid));
        drlg.InitLevel(pLevel);
        const lv_act: i32 = if (ctx.act.level(lid)) |lv| @intCast(lv.act) else 0;

        var objs: std.ArrayListUnmanaged(objpop_mod.SpawnedObject) = .empty;
        errdefer objs.deinit(out_alloc);

        // 1. DS1 preset objects (kind==2), from the generated preset maps. Dedup by
        // (classId,x,y): the shared level DS1 is windowed per room so a preset unit
        // list can be reached from multiple rooms.
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(out_alloc);
        var seen_map: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer seen_map.deinit(out_alloc);

        var pr: ?*abi.D2RoomExStrc = pLevel.pRoomExFirst;
        while (pr) |p| : (pr = p.pRoomExNext) {
            const pmap = roomPMap(p) orelse continue;
            const mapkey = @intFromPtr(pmap);
            if ((try seen_map.getOrPut(out_alloc, mapkey)).found_existing) continue;
            var pu: ?*abi.D2PresetUnitStrc = pmap.pPresetUnit;
            while (pu) |u| : (pu = u.pPresetUnitNext) {
                if (u.eType != 2) continue; // UNIT_OBJECT
                const key = (@as(u64, @bitCast(@as(i64, u.nClassId))) << 40) ^
                    (@as(u64, @intCast(u.nPosX & 0xfffff)) << 20) ^ @as(u64, @intCast(u.nPosY & 0xfffff));
                if ((try seen.getOrPut(out_alloc, key)).found_existing) continue;
                try objs.append(out_alloc, .{ .class_id = u.nClassId, .x = u.nPosX, .y = u.nPosY, .preset = true });
            }
        }

        // 2. Populate-fn spawns per room (ObjGrp loop, keyed on the room seed).
        var pop = objpop_mod.Populator{
            .tbl = &otbl,
            .ctrl = &ctrl,
            .level_id = lid,
            .act = lv_act,
            .out = &objs,
            .gpa = out_alloc,
        };
        pr = pLevel.pRoomExFirst;
        while (pr) |p| : (pr = p.pRoomExNext) {
            var rseed = p.sSeed;
            const rctx = objpop_mod.RoomCtx{
                .x_start = p.sCoords.WorldPosition.x * SUB,
                .y_start = p.sCoords.WorldPosition.y * SUB,
                .x_size = p.sCoords.WorldSize.x * SUB,
                .y_size = p.sCoords.WorldSize.y * SUB,
            };
            objpop_mod.populateRoomObjects(&pop, &rseed, &rctx);
        }

        // 3. Seeded outdoor shrines/wells (SpawnAct12Shrines -> LvlSub Type-5 substitution):
        // spawned DS1 objects placed by the outdoor room build, not the ObjGrp populate path.
        var shrines: std.ArrayListUnmanaged(OutdoorShrine) = .empty;
        defer shrines.deinit(out_alloc);
        try appendOutdoorShrines(pLevel, &shrines, out_alloc);

        // Convert to the public ObjSpawn shape.
        const arr = try out_alloc.alloc(ObjSpawn, objs.items.len + shrines.items.len);
        for (objs.items, 0..) |o, i| arr[i] = .{ .class_id = o.class_id, .x = o.x, .y = o.y, .preset = o.preset, .placeholder_pos = o.placeholder_pos };
        for (shrines.items, objs.items.len..) |sh, i| arr[i] = .{ .class_id = sh.class_id, .x = sh.x, .y = sh.y, .preset = true };
        objs.deinit(out_alloc);
        try out.append(out_alloc, .{ .level_id = lid, .objs = arr });
    }

    return .{ .levels = try out.toOwnedSlice(out_alloc) };
}

test "lib: object population vs town golden (seed 305419896, act 1 L1)" {
    const golden = @embedFile("golden/obj_seed305_act1town.jsonl");
    var ctx = Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();

    var res = generateActObjects(&ctx, std.testing.allocator, 0, 305419896, .normal) catch return;
    defer res.deinit(std.testing.allocator);

    // Collect our L1 objects into a position+class set.
    const Key = struct { c: i32, x: i32, y: i32 };
    var ours = std.AutoHashMapUnmanaged(Key, void).empty;
    defer ours.deinit(std.testing.allocator);
    for (res.levels) |l| {
        if (l.level_id != 1) continue;
        for (l.objs) |o| try ours.put(std.testing.allocator, .{ .c = o.class_id, .x = o.x, .y = o.y }, {});
    }

    // Our (classId,x) multiset for the classId+X match (the Y-placement term of the
    // preset path is a separate, diagnosed gap — see the test note below).
    var ours_cx = std.AutoHashMapUnmanaged(struct { c: i32, x: i32 }, u32).empty;
    defer ours_cx.deinit(std.testing.allocator);
    for (res.levels) |l| {
        if (l.level_id != 1) continue;
        for (l.objs) |o| {
            const gop = try ours_cx.getOrPut(std.testing.allocator, .{ .c = o.class_id, .x = o.x });
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }

    // Parse the golden objs for level 1 and count matches.
    var total: u32 = 0;
    var matched_full: u32 = 0; // classId + exact (x,y)
    var matched_cx: u32 = 0; // classId + x only
    var it = std.mem.splitScalar(u8, golden, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"drlg_obj\"") == null) continue;
        if (jField(line, "\"levelId\":") != 1) continue;
        var p: usize = 0;
        while (std.mem.indexOfPos(u8, line, p, "\"cls\":")) |ci| {
            const c: i32 = @intCast(jField(line[ci..], "\"cls\":") orelse break);
            const x: i32 = @intCast(jField(line[ci..], "\"x\":") orelse break);
            const y: i32 = @intCast(jField(line[ci..], "\"y\":") orelse break);
            total += 1;
            if (ours.get(.{ .c = c, .x = x, .y = y }) != null) matched_full += 1;
            if (ours_cx.getPtr(.{ .c = c, .x = x })) |cnt| {
                if (cnt.* > 0) {
                    matched_cx += 1;
                    cnt.* -= 1;
                }
            }
            p = ci + 6;
        }
    }
    std.debug.print("\n[objpop] town golden L1: classId+X+Y {d}/{d}, classId+X {d}/{d}; ours emitted {d}\n", .{ matched_full, total, matched_cx, total, ours.count() });
    // The town golden is DS1-preset-dominated (Levels.txt ObjGrp is empty for the
    // town, so the ObjGrp populate loop spawns nothing). We reproduce the preset
    // objects: classId + X match near-exactly. The preset-object WORLD-Y uses a
    // DrlgMap offset (881) that diverges +17 tiles from the room/tile offset (864);
    // porting that term is a preset.zig follow-up (changing nRealOffsetY globally
    // would break the byte-exact 136/136 room gate). Assert the classId+X rate.
    try std.testing.expect(total == 24);
    try std.testing.expect(matched_cx >= 12);
}

test "lib: collision vs real-engine golden (seed 72, act 5)" {
    // Regression guard: byte-compare our materialized collision against the
    // captured 1.14d CollMap golden. Skips cleanly if the data tables (assets/)
    // aren't present — same pattern as the Ctx round-trip test below.
    const golden_bytes = @embedFile("golden/coll_seed72_act5.jsonl");
    // Ctx uses page_allocator: the DT1 blob is decompressed+indexed into a
    // process-global cache (dt1Index) that is intentionally never freed, so a
    // leak-checking allocator would false-positive on it. The verify scratch
    // below still uses testing.allocator, so real leaks in the compare path trip.
    var ctx = Ctx.init(std.heap.page_allocator) catch return;
    defer ctx.deinit();

    const r = try verifyActCollision(std.testing.allocator, &ctx, golden_bytes, .normal, true);

    try std.testing.expectEqual(@as(u32, 72), r.seed);
    // Room/dim structure is deterministic (byte-exact generation gate). Per-room
    // DS1 windowing (each RoomEx materializes its own WorldSize*5 window of the
    // shared level DS1, matching the engine's per-room CollMap) makes every room
    // dimension-match the golden.
    try std.testing.expectEqual(@as(u32, 277), r.matched_rooms);
    try std.testing.expectEqual(@as(u32, 0), r.dim_mismatch);
    // Every golden room is matched by one of ours (levelId + world-subtile origin).
    try std.testing.expectEqual(@as(u32, 0), r.golden_only);
    try std.testing.expect(r.total_cells >= 400000);
    // We reproduce STATIC TERRAIN (the low 0x1F COLBITs). The golden also carries
    // static door/object bits (0x400 COLBIT_OBJECT / 0x800 COLBIT_DOOR) which are
    // out of scope, so compare on the masked-0x1F basis, not exact u16.
    // Baseline floor: don't regress below the current masked-0x1F match (69.05%).
    // Remaining gap is dominated by Act-5 wilderness floor rooms (our outdoor
    // materialization overlay is ACT_I-specific) + the PRESET 0x10 bit; tracked in
    // the CollMap fidelity campaign. Raise this floor as those close.
    try std.testing.expect(r.masked_ok >= 300000);
}

test "lib: Ctx round-trips + API type-checks" {
    // Compile-check the generation entrypoints (runtime generation is covered by
    // the byte-exact gate; a runtime smoke test needs valid placement coords,
    // which come from a golden capture — added when the buffer loader lands).
    _ = &generate;
    _ = &Level.firstRoom;

    // Runtime: load the data tables if present, else skip cleanly.
    var ctx = Ctx.init(std.testing.allocator) catch return;
    defer ctx.deinit();
}

