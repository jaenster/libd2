//! DRLG (map generation) boundary for the standalone server.
//!
//! Thin adapter over the clean-room map generator at
//! /Users/jaenster/code/zig/d2-drlg (imported as the `d2-drlg` module). It runs the
//! REAL, byte-exact D2 1.14d generation for a seed + level and reduces it to a
//! LevelSummary (room/tile/collision counts + a sample of room rects) that the game
//! host consumes. Faithful map generation — not a synthetic stand-in.
//!
//! The `generate()` signature and the LevelSummary shape are kept stable so the
//! call site (GameInstance) does not change.

const std = @import("std");
const realdrlg = @import("d2-drlg");

pub const Difficulty = enum(u8) { normal = 0, nightmare = 1, hell = 2 };

/// The faithful unit pathfinder + its collision-view adapter, re-exported from
/// d2-drlg so the game host can path monsters over a level's real collision.
pub const path = realdrlg.path;
pub const PathGrid = realdrlg.PathGrid;
pub const Point = realdrlg.path.Point;

/// A room's placement in world (tile) space, as the real generator reports it.
pub const RoomRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// What the game host needs out of map generation to stand up a level instance.
/// Mirrors (a subset of) what d2-drlg's Level exposes.
pub const LevelSummary = struct {
    level_id: u16,
    seed: u32,
    difficulty: Difficulty,
    room_count: u32,
    tile_count: u32,
    collision_cells: u32,
    /// First few room rects (bounded sample; the real generator yields all rooms).
    rooms: std.ArrayListUnmanaged(RoomRect) = .empty,

    pub fn deinit(self: *LevelSummary, gpa: std.mem.Allocator) void {
        self.rooms.deinit(gpa);
    }
};

/// Generate a level for `seed` via the real d2-drlg generator. Walks the generated
/// room list for the room/tile counts (and a bounded rect sample) and rasterizes
/// the level's real preset subtile collision for the collision-cell count.
pub fn generate(
    gpa: std.mem.Allocator,
    seed: u32,
    level_id: u16,
    difficulty: Difficulty,
) !LevelSummary {
    var ctx = try realdrlg.Ctx.init(gpa);
    defer ctx.deinit();

    const diff: realdrlg.Difficulty = @enumFromInt(@intFromEnum(difficulty));

    // Placement rect from Levels.txt size at the origin (the level's own size),
    // mirroring d2-drlg's own collision path default of 64x64 when unknown.
    var w: i32 = 64;
    var h: i32 = 64;
    if (ctx.act.level(level_id)) |tlv| {
        if (tlv.size_x > 0 and tlv.size_y > 0) {
            w = @intCast(tlv.size_x);
            h = @intCast(tlv.size_y);
        }
    }

    const lvl = try realdrlg.generate(&ctx, seed, @enumFromInt(level_id), diff, .{ .x = 0, .y = 0, .w = w, .h = h });
    defer lvl.deinit();

    var summary = LevelSummary{
        .level_id = level_id,
        .seed = seed,
        .difficulty = difficulty,
        .room_count = 0,
        .tile_count = 0,
        .collision_cells = 0,
    };
    errdefer summary.rooms.deinit(gpa);

    var room_count: u32 = 0;
    var tile_count: u32 = 0;
    var pr = lvl.firstRoom();
    while (pr) |p| : (pr = p.pRoomExNext) {
        const rw = p.sCoords.WorldSize.x;
        const rh = p.sCoords.WorldSize.y;
        tile_count += @intCast(@max(0, rw) * @max(0, rh));
        if (room_count < 8) {
            try summary.rooms.append(gpa, .{
                .x = p.sCoords.WorldPosition.x,
                .y = p.sCoords.WorldPosition.y,
                .w = rw,
                .h = rh,
            });
        }
        room_count += 1;
    }
    summary.room_count = room_count;
    summary.tile_count = tile_count;

    // Real subtile collision from the level's preset DrlgMaps.
    var coll = try realdrlg.generateLevelCollision(&ctx, gpa, seed, level_id, diff);
    defer coll.deinit(gpa);
    var cells: u32 = 0;
    for (coll.grids) |g| cells += @intCast(@max(0, g.w) * @max(0, g.h));
    summary.collision_cells = cells;

    return summary;
}

/// One monster spawn the game host should instantiate: a resolved monster class id
/// at a world SUBTILE position, with a group `count` and a `unique` flag. Positions
/// are placeholders (room centers) — see d2-drlg monpop residuals (real placement
/// needs the room collision grid + coord-list sub-rects).
pub const Spawn = struct {
    class_id: i32,
    x: i32,
    y: i32,
    count: i32,
    unique: bool,
    /// True for a DS1 PRESET monster (eType==1) — the seeded act boss / quest monster placed
    /// by the level's preset, not the density roller (e.g. Mephisto in Durance of Hate L3).
    /// The game host resolves these to their real MonStats HP + boss flags rather than the
    /// generic density-monster placeholder HP.
    preset: bool = false,
};

/// One outgoing inter-level adjacency of a level: a destination level reachable from this
/// one, plus the warp-type graphic (Levels.txt Warp column) when the transition is a real
/// warp door (stairs/portal); 0 for a borderless wilderness seam (a walk-off-edge border).
pub const WarpTarget = struct {
    dest_level: u16,
    warp_type: u8,
};

/// Warp-type graphic for `dest` as recorded in this level's raw Levels.txt Vis/Warp
/// columns, or 0 when `dest` isn't a Vis-listed warp door (e.g. a wilderness seam, whose
/// transition is a border walk with no portal graphic).
fn warpTypeFor(ctx: *realdrlg.Ctx, level_id: u16, dest: u16) u8 {
    const t = &ctx.act.levels;
    const row = t.findByInt("Id", level_id) orelse return 0;
    var slot: usize = 0;
    while (slot < 8) : (slot += 1) {
        var vname: [8]u8 = undefined;
        var wname: [8]u8 = undefined;
        if (@as(u16, @intCast(@max(0, t.int(row, std.fmt.bufPrint(&vname, "Vis{d}", .{slot}) catch continue)))) != dest) continue;
        const wtype = t.int(row, std.fmt.bufPrint(&wname, "Warp{d}", .{slot}) catch "");
        return @intCast(@max(0, @min(255, wtype)));
    }
    return 0;
}

/// A level's outgoing inter-level adjacency — the REAL traversal graph, from d2-drlg's
/// `generateLevelAdjacents` (per-room warp doors UNION the inter-level placement seams).
/// This is what makes the whole act reachable: e.g. the town (Rogue Encampment) carries no
/// Vis/Warp column at all, yet is stitched to the Blood Moor via a placement seam — the raw
/// Vis columns alone would leave it a dead end. Returns the distinct destination levels;
/// the warp-type graphic is recovered from the Vis/Warp columns for real warp doors.
pub fn warpTargets(ctx: *realdrlg.Ctx, gpa: std.mem.Allocator, seed: u32, diff: Difficulty, level_id: u16) ![]WarpTarget {
    const act_no: i32 = if (ctx.act.level(level_id)) |lv| @intCast(lv.act) else 0;
    const rdiff: realdrlg.Difficulty = @enumFromInt(@intFromEnum(diff));
    const adj = realdrlg.generateLevelAdjacents(ctx, gpa, act_no, seed, rdiff, level_id) catch return &.{};
    defer gpa.free(adj);

    var out: std.ArrayListUnmanaged(WarpTarget) = .empty;
    errdefer out.deinit(gpa);
    for (adj) |a| {
        if (a.dest_level_id <= 0) continue;
        const dest: u16 = @intCast(a.dest_level_id);
        // Dedup: seams emit one entry per touching room-pair (many per neighbour level).
        var dup = false;
        for (out.items) |w| if (w.dest_level == dest) {
            dup = true;
            break;
        };
        if (dup) continue;
        const wtype: u8 = if (a.kind == .warp) warpTypeFor(ctx, level_id, dest) else 0;
        try out.append(gpa, .{ .dest_level = dest, .warp_type = wtype });
    }
    return out.toOwnedSlice(gpa);
}

/// One seeded object (shrine / chest / well / door / waypoint) at a world SUBTILE
/// position, carrying its resolved Objects.txt class id for client CreateObject and
/// its OperateFn (the server's OBJECTSOPERATEFN dispatch index; 0 = not operable).
pub const Object = struct { class_id: i32, x: i32, y: i32, operate_fn: i32 = 0 };

/// A generated + monster-populated level: the summary, the spawn list (owned), and
/// the player entry point in world SUBTILE coords (center of the first room).
pub const Populated = struct {
    summary: LevelSummary,
    spawns: []Spawn,
    warps: []WarpTarget = &.{},
    objects: []Object = &.{},
    entry_x: i32,
    entry_y: i32,
    /// The level's composited walkability grid (world-subtile space) for monster/
    /// player pathfinding, or null when the level has no preset collision grids
    /// (maze/wilderness rooms without a preset DrlgMap — callers fall back to
    /// straight-line movement). Owned; freed by `deinit`.
    path_grid: ?PathGrid = null,

    pub fn deinit(self: *Populated, gpa: std.mem.Allocator) void {
        self.summary.deinit(gpa);
        gpa.free(self.spawns);
        gpa.free(self.warps);
        gpa.free(self.objects);
        if (self.path_grid) |*pg| pg.deinit(gpa);
    }
};

const SUBTILES_PER_TILE: i32 = 5;

/// Generate a level AND run the faithful seeded monster population over its rooms.
/// Returns the level summary, a per-room monster spawn list, and the player entry
/// point. Room world coords are in TILES; monster/entry positions are converted to
/// world SUBTILES (×5) so they can be used directly as on-wire unit positions.
///
/// Self-contained convenience wrapper (spins up its own Ctx + monster tables). The
/// game host uses `World` instead so a single Ctx + table set is reused across every
/// level of a game (and OUTDOOR levels route through the act-placement path). This is
/// still the INTERIOR single-level path and is kept for the existing tests.
pub fn generatePopulated(
    gpa: std.mem.Allocator,
    seed: u32,
    level_id: u16,
    difficulty: Difficulty,
) !Populated {
    var ctx = try realdrlg.Ctx.init(gpa);
    defer ctx.deinit();
    var montbl = try realdrlg.monpop.Tables.load(gpa);
    defer montbl.deinit();
    return populateSingle(&ctx, &montbl, gpa, seed, level_id, difficulty);
}

/// The INTERIOR single-level populate: byte-exact `generate()` + faithful per-room
/// monster population off each live room's own `sSeed`. Crashes on wilderness levels
/// (they need the act placement context) — callers gate this on drlg_type via `World`.
fn populateSingle(
    ctx: *realdrlg.Ctx,
    montbl: *realdrlg.monpop.Tables,
    gpa: std.mem.Allocator,
    seed: u32,
    level_id: u16,
    difficulty: Difficulty,
) !Populated {
    const diff: realdrlg.Difficulty = @enumFromInt(@intFromEnum(difficulty));

    var w: i32 = 64;
    var h: i32 = 64;
    if (ctx.act.level(level_id)) |tlv| {
        if (tlv.size_x > 0 and tlv.size_y > 0) {
            w = @intCast(tlv.size_x);
            h = @intCast(tlv.size_y);
        }
    }

    const lvl = try realdrlg.generate(ctx, seed, @enumFromInt(level_id), diff, .{ .x = 0, .y = 0, .w = w, .h = h });
    defer lvl.deinit();

    var summary = LevelSummary{
        .level_id = level_id,
        .seed = seed,
        .difficulty = difficulty,
        .room_count = 0,
        .tile_count = 0,
        .collision_cells = 0,
    };
    errdefer summary.rooms.deinit(gpa);

    // First pass: count rooms (needed to seed the region's per-level room counters).
    var room_count: u32 = 0;
    {
        var pr = lvl.firstRoom();
        while (pr) |p| : (pr = p.pRoomExNext) room_count += 1;
    }

    // Monster region roster for the whole seed (one shared region-seed stream over
    // all levels, as AllocMonsterRegion does); we index our level out of it.
    const regions = try realdrlg.monpop.buildAllRegions(gpa, montbl, seed, @intCast(@intFromEnum(difficulty)));
    defer gpa.free(regions);

    var spawns: std.ArrayListUnmanaged(Spawn) = .empty;
    errdefer spawns.deinit(gpa);

    const lm = montbl.levelMon(level_id);
    const has_region = lm != null and level_id < regions.len;
    const is_not_normal = @intFromEnum(difficulty) != 0;

    var game_seed = realdrlg.abi.D2SeedStrc{ .nSeedLow = @bitCast(seed), .nSeedHigh = 0x29a };
    var rg: ?*realdrlg.monpop.Region = null;
    if (has_region) {
        rg = &regions[level_id];
        rg.?.n_level_rooms_count = @intCast(room_count);
        rg.?.n_rooms_count = 0;
    }

    // Second pass: build the room summary + populate monsters per room.
    var entry_x: i32 = 0;
    var entry_y: i32 = 0;
    var first_room = true;
    var pr = lvl.firstRoom();
    while (pr) |p| : (pr = p.pRoomExNext) {
        const rx = p.sCoords.WorldPosition.x;
        const ry = p.sCoords.WorldPosition.y;
        const rw = p.sCoords.WorldSize.x;
        const rh = p.sCoords.WorldSize.y;
        summary.tile_count += @intCast(@max(0, rw) * @max(0, rh));
        if (summary.room_count < 8) {
            try summary.rooms.append(gpa, .{ .x = rx, .y = ry, .w = rw, .h = rh });
        }
        summary.room_count += 1;

        // World-subtile room rect (positions on the wire are subtiles).
        const sx = rx * SUBTILES_PER_TILE;
        const sy = ry * SUBTILES_PER_TILE;
        const ssx = rw * SUBTILES_PER_TILE;
        const ssy = rh * SUBTILES_PER_TILE;

        if (first_room) {
            entry_x = sx + @divTrunc(ssx, 2);
            entry_y = sy + @divTrunc(ssy, 2);
            first_room = false;
        }

        if (rg) |region| {
            region.n_rooms_count += 1;
            var room_seed = p.sSeed;
            const rctx = realdrlg.monpop.RoomCtx{
                .x_start = sx,
                .y_start = sy,
                .x_size = ssx,
                .y_size = ssy,
            };
            var tmp: std.ArrayListUnmanaged(realdrlg.monpop.MonSpawn) = .empty;
            defer tmp.deinit(gpa);
            _ = realdrlg.monpop.spawnRoomMonsters(region, montbl, lm.?, &game_seed, &room_seed, &rctx, is_not_normal, &tmp, gpa, null);
            for (tmp.items) |ms| {
                try spawns.append(gpa, .{
                    .class_id = ms.class_id,
                    .x = ms.x,
                    .y = ms.y,
                    .count = ms.count,
                    .unique = ms.flags.unique,
                });
            }
        }
    }

    // DS1 preset monsters (eType==1): the seeded act boss / quest monster the level's
    // preset places (Mephisto in Durance of Hate L3, Andariel, Diablo, Duriel, ...). These
    // are NOT rolled by the density populator above — they come from the level's DS1 preset
    // chain. Coords are level-local subtiles; add the level world origin to land them in the
    // same world-subtile space as the density spawns.
    {
        const act_no: i32 = if (ctx.act.level(level_id)) |tlv| @intCast(tlv.act) else 0;
        const lox = lvl.level.sCoordinatesAndSize.WorldPosition.x * SUBTILES_PER_TILE;
        const loy = lvl.level.sCoordinatesAndSize.WorldPosition.y * SUBTILES_PER_TILE;
        const presets = realdrlg.generateLevelPresets(ctx, gpa, act_no, seed, diff, level_id) catch &.{};
        defer gpa.free(presets);
        for (presets) |pu| {
            if (pu.etype != 1) continue; // only monsters (eType==1); objects come via objpop
            try spawns.append(gpa, .{
                .class_id = pu.txt_file_no,
                .x = pu.x + lox,
                .y = pu.y + loy,
                .count = 1,
                .unique = true,
                .preset = true,
            });
        }
    }

    // Real subtile collision cell count (regenerates the level internally).
    var coll = try realdrlg.generateLevelCollision(ctx, gpa, seed, level_id, diff);
    defer coll.deinit(gpa);
    var cells: u32 = 0;
    for (coll.grids) |g| cells += @intCast(@max(0, g.w) * @max(0, g.h));
    summary.collision_cells = cells;

    // Composited walkability grid for pathfinding (null for maze/wilderness levels
    // without preset collision — the game host then straight-lines movement).
    const pg = realdrlg.buildPathGrid(ctx, gpa, seed, @intCast(level_id), diff) catch null;

    // Outgoing adjacency from the real d2-drlg warp/seam graph (this level's neighbours).
    const warps = try warpTargets(ctx, gpa, seed, difficulty, level_id);
    errdefer gpa.free(warps);

    return .{
        .summary = summary,
        .spawns = try spawns.toOwnedSlice(gpa),
        .warps = warps,
        .entry_x = entry_x,
        .entry_y = entry_y,
        .path_grid = pg,
    };
}

// ---- World: per-game DRLG context with act-placement routing ---------------

/// Levels.txt DrlgType for a level id: 1 = maze (interior), 2 = preset (town/special),
/// 3 = wilderness (outdoor). Wilderness levels need the whole-act placement context and
/// CRASH the single-level generate() path — `World` routes them through `generateAct`.
const DRLG_WILDERNESS: i32 = 3;

/// Subtile-flag bits (dt1.SubtileFlag) as read out of a materialized collision cell.
const COLL_BLOCK_WALK: u8 = 0x01; // impassable to walking
const COLL_NO_FLOOR: u8 = 0x20; // cell carries no floor (not walkable ground)

/// One generated act, cached: every level's rooms (world coords, via the real
/// inter-level placement) + every level's materialized collision. Both are owned,
/// pool-independent copies (the fog pool is torn down inside the generate calls), so
/// this is safe to hold for the game's lifetime.
const ActData = struct {
    act_no: i32,
    rooms: realdrlg.ActResult,
    coll: realdrlg.ActCollResult,
    objs: realdrlg.ActObjectsResult,

    fn levelRooms(self: *const ActData, level_id: u16) ?realdrlg.LevelRooms {
        for (self.rooms.levels) |lr| if (lr.level_id == @as(i32, level_id)) return lr;
        return null;
    }
    fn levelColl(self: *const ActData, level_id: u16) ?realdrlg.LevelColl {
        for (self.coll.levels) |lc| if (lc.level_id == @as(i32, level_id)) return lc;
        return null;
    }
    fn levelObjs(self: *const ActData, level_id: u16) []const realdrlg.ObjSpawn {
        for (self.objs.levels) |lo| if (lo.level_id == @as(i32, level_id)) return lo.objs;
        return &.{};
    }
    fn deinit(self: *ActData, gpa: std.mem.Allocator) void {
        self.rooms.deinit(gpa);
        self.coll.deinit(gpa);
        self.objs.deinit(gpa);
    }
};

/// A game's map-generation world: one long-lived d2-drlg Ctx + monster tables reused
/// across every hosted level, plus a per-act cache. `populated(level_id)` routes each
/// level to the right generation path: INTERIOR levels (maze/preset) use the byte-exact
/// single-level `generate()`; OUTDOOR (wilderness) levels — which crash single-level
/// generation — are extracted from the whole-act placement result (`generateAct` +
/// `generateActCollisionAll`), generated once per act and cached.
pub const World = struct {
    gpa: std.mem.Allocator,
    ctx: realdrlg.Ctx,
    montbl: realdrlg.monpop.Tables,
    /// Objects.txt (OperateFn / collision / automap) — resolves object behaviour ids.
    objtbl: realdrlg.gen.objects.Table,
    seed: u32,
    difficulty: Difficulty,
    acts: std.AutoHashMapUnmanaged(i32, *ActData) = .empty,

    pub fn init(gpa: std.mem.Allocator, seed: u32, difficulty: Difficulty) !World {
        return .{
            .gpa = gpa,
            .ctx = try realdrlg.Ctx.init(gpa),
            .montbl = try realdrlg.monpop.Tables.load(gpa),
            .objtbl = try realdrlg.gen.objects.load(gpa),
            .seed = seed,
            .difficulty = difficulty,
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.acts.valueIterator();
        while (it.next()) |ap| {
            ap.*.deinit(self.gpa);
            self.gpa.destroy(ap.*);
        }
        self.acts.deinit(self.gpa);
        self.objtbl.deinit();
        self.montbl.deinit();
        self.ctx.deinit();
    }

    /// Levels.txt area monster level for a level at a difficulty (MonLvlNEx).
    pub fn monLvl(self: *World, level_id: u16, diff: Difficulty) i64 {
        if (self.ctx.act.level(level_id)) |lv| return lv.monlvl[@intFromEnum(diff)];
        return 0;
    }

    /// The act's [first,last] level area-mlvl at a difficulty — the engine's
    /// eLevelId_ActLevels bounds (act's lowest/highest level id), derived from the
    /// Act column so nothing is hardcoded. Feeds the chest-TC 3-tier mlvl bucket.
    pub fn actMonLvlBounds(self: *World, act_no: i32, diff: Difficulty) [2]i64 {
        var first_id: i64 = std.math.maxInt(i64);
        var last_id: i64 = 0;
        var row: usize = 0;
        const n = self.ctx.act.levelCount();
        while (row < n) : (row += 1) {
            const lv = self.ctx.act.levelAtRow(row) orelse continue;
            if (lv.act != act_no) continue;
            first_id = @min(first_id, lv.id);
            last_id = @max(last_id, lv.id);
        }
        if (last_id == 0) return .{ 0, 0 };
        return .{
            self.monLvl(@intCast(first_id), diff),
            self.monLvl(@intCast(last_id), diff),
        };
    }

    /// Levels.txt Act (0-based) for a level id.
    pub fn actOf(self: *World, level_id: u16) i32 {
        return self.levelAct(level_id);
    }

    /// MonStats.txt DamageRegen for a monster class id (0 if unknown) — drives the
    /// faithful hp-regen stat: hpregen = maxhp * DamageRegen / 16 (engine <<8 space).
    pub fn monDamageRegen(self: *World, class_id: i32) i32 {
        if (self.montbl.stat(class_id)) |ms| return ms.damage_regen;
        return 0;
    }

    /// MonStats.txt maxHP for a monster class id at this world's difficulty, or 0 if unknown.
    /// For act bosses (Mephisto/Andariel/Diablo/...) minHP==maxHP, so this is their fixed HP
    /// (e.g. Mephisto Hell = MaxHP(H) = 1471). The engine rolls uniformly in [minHP,maxHP] and
    /// then applies the /players multiplier; with min==max the roll is a no-op.
    pub fn monMaxHp(self: *World, class_id: i32) i32 {
        const d: usize = @intCast(@intFromEnum(self.difficulty));
        if (self.montbl.stat(class_id)) |ms| return ms.max_hp[d];
        return 0;
    }

    /// MonStats.txt boss flag for a monster class id (act boss / mini-boss).
    pub fn monIsBoss(self: *World, class_id: i32) bool {
        if (self.montbl.stat(class_id)) |ms| return ms.is_boss;
        return false;
    }

    /// Faithful MonLvl-scaled HP [min,max] for a class at a given monster level and this
    /// world's difficulty (MONSTER_CalculateLevelScaledStats 0x6538a0). `mon_level` is the
    /// AREA monster level — pass World.monLvl(level_id, diff) (Levels.txt MonLvlEx) for the
    /// level the monster spawned in. no_ratio summons return their raw MonStats HP.
    pub fn monScaledHp(self: *World, class_id: i32, mon_level: i32) ?[2]i32 {
        return self.montbl.scaledHp(class_id, mon_level, @intCast(@intFromEnum(self.difficulty)));
    }

    /// The MonLvl-scaled HP for a class using its MonStats Level column as the monster level
    /// (the non-champion default MONSTER_InitStats uses when no area override applies). This
    /// is the correct base HP for ordinary monsters and act bosses whose Level is fixed.
    pub fn monBaseScaledHp(self: *World, class_id: i32) ?[2]i32 {
        const d: u2 = @intCast(@intFromEnum(self.difficulty));
        return self.montbl.scaledHp(class_id, self.montbl.monLevelDefault(class_id, d), d);
    }

    /// Deterministic final (non-<<8) HP a monster rolls off `seed` at `mon_level` and this
    /// world's difficulty, with `player_mult` = the /players multiplier (100 for 1 player).
    pub fn monRollHp(self: *World, class_id: i32, mon_level: i32, seed: *realdrlg.abi.D2SeedStrc, player_mult: i32) ?i32 {
        return self.montbl.calcRolledHp(class_id, mon_level, @intCast(@intFromEnum(self.difficulty)), seed, player_mult);
    }

    /// MonStats resistances (phys/magic/fire/light/cold/poison percent) for a class at this
    /// world's difficulty. 100 = immune, negatives amplify. Straight from MonStats, no scaling.
    pub fn monResist(self: *World, class_id: i32) ?realdrlg.monpop.MonResist {
        return self.montbl.resist(class_id, @intCast(@intFromEnum(self.difficulty)));
    }

    /// Levels.txt DrlgType for a level id (0 if unknown).
    fn drlgType(self: *World, level_id: u16) i32 {
        if (self.ctx.act.level(level_id)) |lv| return @intFromEnum(lv.drlg_type);
        return 0;
    }

    /// Levels.txt Act (0-based) for a level id (0 if unknown).
    fn levelAct(self: *World, level_id: u16) i32 {
        if (self.ctx.act.level(level_id)) |lv| return @intCast(lv.act);
        return 0;
    }

    /// True if `level_id` is an outdoor (wilderness) level that must be generated via
    /// the act-placement path rather than single-level generate().
    pub fn isOutdoor(self: *World, level_id: u16) bool {
        return self.drlgType(level_id) == DRLG_WILDERNESS;
    }

    fn ensureAct(self: *World, act_no: i32) !*ActData {
        if (self.acts.get(act_no)) |ad| return ad;
        const ad = try self.gpa.create(ActData);
        errdefer self.gpa.destroy(ad);
        const diff: realdrlg.Difficulty = @enumFromInt(@intFromEnum(self.difficulty));
        // Whole-act room placement (world coords) + materialized collision. Each call
        // generates the act on a private fog pool and returns owned copies.
        var rooms = try realdrlg.generateAct(&self.ctx, self.gpa, act_no, self.seed, diff);
        errdefer rooms.deinit(self.gpa);
        var coll = try realdrlg.generateActCollisionAll(&self.ctx, self.gpa, act_no, self.seed, diff);
        errdefer coll.deinit(self.gpa);
        // Seeded object population per level (DS1 preset objects + ObjGrp scatter/shrine/
        // chest rolls). World-subtile positions, same space as the outdoor spawns.
        var objs = try realdrlg.generateActObjects(&self.ctx, self.gpa, act_no, self.seed, diff);
        errdefer objs.deinit(self.gpa);
        ad.* = .{ .act_no = act_no, .rooms = rooms, .coll = coll, .objs = objs };
        try self.acts.put(self.gpa, act_no, ad);
        return ad;
    }

    /// Generate + populate `level_id` for this world, routing outdoor vs interior.
    pub fn populated(self: *World, level_id: u16) !Populated {
        if (self.isOutdoor(level_id)) return self.populatedOutdoor(level_id);
        return populateSingle(&self.ctx, &self.montbl, self.gpa, self.seed, level_id, self.difficulty);
    }

    /// Build a Populated for an OUTDOOR level out of the cached whole-act result: rooms
    /// come from the placement graph, collision from the act-context materialization
    /// (composited into one world-subtile PathGrid), monsters from the faithful
    /// buildAllRegions/spawnRoomMonsters roster run over the extracted rooms.
    fn populatedOutdoor(self: *World, level_id: u16) !Populated {
        const act_no = self.levelAct(level_id);
        const ad = try self.ensureAct(act_no);
        const gpa = self.gpa;

        var summary = LevelSummary{
            .level_id = level_id,
            .seed = self.seed,
            .difficulty = self.difficulty,
            .room_count = 0,
            .tile_count = 0,
            .collision_cells = 0,
        };
        errdefer summary.rooms.deinit(gpa);

        const lr = ad.levelRooms(level_id);
        const room_slice: []const realdrlg.RoomRect = if (lr) |x| x.rooms else &.{};

        // Path grid from the act-context materialized collision (covers wilderness).
        const pg = if (ad.levelColl(level_id)) |lc| try buildActPathGrid(gpa, lc) else null;

        // Monster roster for the whole seed; index this level's region out of it.
        const regions = try realdrlg.monpop.buildAllRegions(gpa, &self.montbl, self.seed, @intCast(@intFromEnum(self.difficulty)));
        defer gpa.free(regions);
        const lm = self.montbl.levelMon(level_id);
        const has_region = lm != null and level_id < regions.len;
        const is_not_normal = @intFromEnum(self.difficulty) != 0;
        var game_seed = realdrlg.abi.D2SeedStrc{ .nSeedLow = @bitCast(self.seed), .nSeedHigh = 0x29a };
        var rg: ?*realdrlg.monpop.Region = null;
        if (has_region) {
            rg = &regions[level_id];
            rg.?.n_level_rooms_count = @intCast(room_slice.len);
            rg.?.n_rooms_count = 0;
        }

        var spawns: std.ArrayListUnmanaged(Spawn) = .empty;
        errdefer spawns.deinit(gpa);

        var entry_x: i32 = 0;
        var entry_y: i32 = 0;
        var first_room = true;
        for (room_slice, 0..) |r, idx| {
            summary.tile_count += @intCast(@max(0, r.w) * @max(0, r.h));
            if (summary.room_count < 8) try summary.rooms.append(gpa, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
            summary.room_count += 1;

            const sx = r.x * SUBTILES_PER_TILE;
            const sy = r.y * SUBTILES_PER_TILE;
            const ssx = r.w * SUBTILES_PER_TILE;
            const ssy = r.h * SUBTILES_PER_TILE;
            if (first_room) {
                entry_x = sx + @divTrunc(ssx, 2);
                entry_y = sy + @divTrunc(ssy, 2);
                first_room = false;
            }

            if (rg) |region| {
                region.n_rooms_count += 1;
                // ActResult rooms don't carry the live room sSeed (a placement residual),
                // so derive a deterministic per-room seed from the game seed + room world
                // position. Faithful roster + density; room-local placement is a residual.
                var room_seed = deriveRoomSeed(self.seed, r.x, r.y, idx);
                const rctx = realdrlg.monpop.RoomCtx{ .x_start = sx, .y_start = sy, .x_size = ssx, .y_size = ssy };
                var tmp: std.ArrayListUnmanaged(realdrlg.monpop.MonSpawn) = .empty;
                defer tmp.deinit(gpa);
                _ = realdrlg.monpop.spawnRoomMonsters(region, &self.montbl, lm.?, &game_seed, &room_seed, &rctx, is_not_normal, &tmp, gpa, null);
                for (tmp.items) |ms| {
                    try spawns.append(gpa, .{ .class_id = ms.class_id, .x = ms.x, .y = ms.y, .count = ms.count, .unique = ms.flags.unique });
                }
            }
        }

        if (pg) |g| summary.collision_cells = @intCast(@max(0, g.w) * @max(0, g.h));

        const warps = try warpTargets(&self.ctx, gpa, self.seed, self.difficulty, level_id);
        errdefer gpa.free(warps);

        // This level's seeded objects (world-subtile positions from the act cache).
        const src_objs = ad.levelObjs(level_id);
        var objects: std.ArrayListUnmanaged(Object) = .empty;
        errdefer objects.deinit(gpa);
        for (src_objs) |o| try objects.append(gpa, .{
            .class_id = o.class_id,
            .x = o.x,
            .y = o.y,
            .operate_fn = self.objtbl.operateFn(o.class_id),
        });

        return .{
            .summary = summary,
            .spawns = try spawns.toOwnedSlice(gpa),
            .warps = warps,
            .objects = try objects.toOwnedSlice(gpa),
            .entry_x = entry_x,
            .entry_y = entry_y,
            .path_grid = pg,
        };
    }
};

/// Deterministic per-room seed for outdoor monster population. Not the engine's live
/// room sSeed (not exposed by the act result) — a stable hash of game seed + room world
/// position so the roster/density rolls are reproducible across runs of the same seed.
fn deriveRoomSeed(seed: u32, rx: i32, ry: i32, idx: usize) realdrlg.abi.D2SeedStrc {
    var h: u64 = 0x9e3779b97f4a7c15;
    h = (h ^ seed) *% 0x100000001b3;
    h = (h ^ @as(u32, @bitCast(rx))) *% 0x100000001b3;
    h = (h ^ @as(u32, @bitCast(ry))) *% 0x100000001b3;
    h = (h ^ @as(u64, idx)) *% 0x100000001b3;
    return .{ .nSeedLow = @bitCast(@as(u32, @truncate(h ^ (h >> 32)))), .nSeedHigh = 0x29a };
}

/// Composite an act-context level's per-room materialized collision grids into one
/// world-subtile-space PathGrid for the faithful pathfinder. Grid x/y are LEVEL-LOCAL
/// subtiles relative to the level's world TILE origin; a cell is walkable ground unless
/// it carries the no-floor bit, and blocked when the walk-block bit is set. Object
/// footprints are stamped blocked. Returns null if the level has no grids.
fn buildActPathGrid(gpa: std.mem.Allocator, lc: realdrlg.LevelColl) !?PathGrid {
    if (lc.grids.len == 0) return null;
    const org_x = lc.origin_x * SUBTILES_PER_TILE;
    const org_y = lc.origin_y * SUBTILES_PER_TILE;

    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (lc.grids) |g| {
        min_x = @min(min_x, g.x);
        min_y = @min(min_y, g.y);
        max_x = @max(max_x, g.x + g.w);
        max_y = @max(max_y, g.y + g.h);
    }
    for (lc.objects) |o| {
        min_x = @min(min_x, o.x - @divTrunc(o.sx, 2));
        min_y = @min(min_y, o.y - @divTrunc(o.sy, 2));
        max_x = @max(max_x, o.x + @divTrunc(o.sx, 2) + 1);
        max_y = @max(max_y, o.y + @divTrunc(o.sy, 2) + 1);
    }
    const w = max_x - min_x;
    const h = max_y - min_y;
    if (w <= 0 or h <= 0) return null;
    const wu: usize = @intCast(w);
    const hu: usize = @intCast(h);
    const blocked = try gpa.alloc(bool, wu * hu);
    errdefer gpa.free(blocked);
    const ground = try gpa.alloc(bool, wu * hu);
    errdefer gpa.free(ground);
    @memset(blocked, false);
    @memset(ground, false);

    for (lc.grids) |g| {
        const gw: usize = @intCast(g.w);
        const gh: usize = @intCast(g.h);
        var cy: usize = 0;
        while (cy < gh) : (cy += 1) {
            const dy: usize = @intCast(g.y - min_y + @as(i32, @intCast(cy)));
            var cx: usize = 0;
            while (cx < gw) : (cx += 1) {
                const dx: usize = @intCast(g.x - min_x + @as(i32, @intCast(cx)));
                const cell = g.cells[cy * gw + cx];
                const di = dy * wu + dx;
                if (cell & COLL_NO_FLOOR == 0) ground[di] = true;
                if (cell & COLL_BLOCK_WALK != 0) blocked[di] = true;
            }
        }
    }
    for (lc.objects) |o| {
        var dy: i32 = -@divTrunc(o.sy, 2);
        while (dy <= @divTrunc(o.sy - 1, 2)) : (dy += 1) {
            const cy = o.y + dy - min_y;
            if (cy < 0 or cy >= h) continue;
            var dx: i32 = -@divTrunc(o.sx, 2);
            while (dx <= @divTrunc(o.sx - 1, 2)) : (dx += 1) {
                const cx = o.x + dx - min_x;
                if (cx < 0 or cx >= w) continue;
                blocked[@intCast(cy * w + cx)] = true;
            }
        }
    }

    return PathGrid{ .origin_x = org_x + min_x, .origin_y = org_y + min_y, .w = w, .h = h, .blocked = blocked, .ground = ground };
}

test "generatePopulated: monster-bearing level yields spawns + entry point" {
    const gpa = std.testing.allocator;
    // Blood Moor (level id 2, Act I) has monster density in normal difficulty.
    var pop = try generatePopulated(gpa, 0x13572468, 8, .normal);
    defer pop.deinit(gpa);
    try std.testing.expect(pop.summary.room_count >= 1);
    try std.testing.expect(pop.spawns.len >= 1);
    // deterministic
    var pop2 = try generatePopulated(gpa, 0x13572468, 8, .normal);
    defer pop2.deinit(gpa);
    try std.testing.expectEqual(pop.spawns.len, pop2.spawns.len);
    try std.testing.expectEqual(pop.entry_x, pop2.entry_x);
}

test "Durance of Hate L3 (102) places Mephisto as a preset boss" {
    const gpa = std.testing.allocator;
    // Mephisto is a DS1 PRESET monster (eType==1) placed in the Durance L3 preset, resolved
    // via MonPreset "mephisto" -> MonStats class id 242. Not a density roll.
    var pop = try generatePopulated(gpa, 0x13572468, 102, .hell);
    defer pop.deinit(gpa);
    var meph = false;
    for (pop.spawns) |s| {
        if (s.class_id == 242 and s.preset) meph = true;
    }
    try std.testing.expect(meph);
}

test "warpTargets reads the real Levels.txt warp adjacency" {
    const gpa = std.testing.allocator;
    // Jail 1 (29) connects to Jail 2 (30); Jail 2 connects back. Both are interior maze
    // levels that generate standalone (outdoor/wilderness levels need full act context).
    var j1 = try generatePopulated(gpa, 0x13572468, 29, .normal);
    defer j1.deinit(gpa);
    var found_fwd = false;
    for (j1.warps) |w| {
        if (w.dest_level == 30) found_fwd = true;
    }
    try std.testing.expect(found_fwd);

    var j2 = try generatePopulated(gpa, 0x13572468, 30, .normal);
    defer j2.deinit(gpa);
    var found_back = false;
    for (j2.warps) |w| {
        if (w.dest_level == 29) found_back = true;
    }
    try std.testing.expect(found_back);
}

test "the Act-1 outdoor chain is reachable from town via the real adjacency graph" {
    const gpa = std.testing.allocator;
    var ctx = try realdrlg.Ctx.init(gpa);
    defer ctx.deinit();

    // BFS the real warp/seam graph outward from the Rogue Encampment (town, id 1): the core
    // Act-1 chain — Blood Moor (2), Cold Plains (3), Stony Field (4), Den of Evil (8) and
    // Burial Grounds (17) — must all be reachable, proving the town is a live hub into the
    // whole act, not a dead end. Bounded to a small visit budget so the act is only rebuilt
    // a handful of times (each warpTargets call regenerates the act).
    var reached = std.AutoHashMap(u16, void).init(gpa);
    defer reached.deinit();
    var queue: std.ArrayListUnmanaged(u16) = .empty;
    defer queue.deinit(gpa);
    try queue.append(gpa, 1);
    try reached.put(1, {});

    var head: usize = 0;
    var visits: usize = 0;
    while (head < queue.items.len and visits < 8) : (visits += 1) {
        const lvl = queue.items[head];
        head += 1;
        const adj = try warpTargets(&ctx, gpa, 0x13572468, .normal, lvl);
        defer gpa.free(adj);
        for (adj) |w| {
            if (reached.contains(w.dest_level)) continue;
            try reached.put(w.dest_level, {});
            try queue.append(gpa, w.dest_level);
        }
    }

    for ([_]u16{ 2, 3, 4, 8, 17 }) |id| try std.testing.expect(reached.contains(id));
}

test "town (Rogue Encampment) has an outgoing warp to the Blood Moor" {
    const gpa = std.testing.allocator;
    // The town carries no Levels.txt Vis/Warp column, yet is reachable-out to the Blood
    // Moor (2) via the inter-level placement seam. Raw Vis alone leaves it a dead end; the
    // real d2-drlg adjacency graph must expose the exit so the whole act is traversable.
    var town = try generatePopulated(gpa, 0x13572468, 1, .normal);
    defer town.deinit(gpa);
    var to_moor = false;
    for (town.warps) |w| {
        if (w.dest_level == 2) to_moor = true;
    }
    try std.testing.expect(to_moor);
}

test "generate is seed-deterministic" {
    const gpa = std.testing.allocator;
    var a = try generate(gpa, 0x1234, 1, .normal);
    defer a.deinit(gpa);
    var b = try generate(gpa, 0x1234, 1, .normal);
    defer b.deinit(gpa);
    try std.testing.expectEqual(a.room_count, b.room_count);
    try std.testing.expectEqual(a.tile_count, b.tile_count);
    try std.testing.expect(a.room_count >= 1);
}
