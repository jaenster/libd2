//! Seeded OBJECT-population subsystem — faithful port of D2 1.14d's
//! OBJECT_PopulateRoomObjects (0x552610) and its leaf populate fns. This is the
//! step that spawns objects (chests, shrines, wells, barrels/urns, waypoints, …)
//! into rooms deterministically from the seed, AFTER a room is built.
//!
//! RE map: docs/re/object-population.md (Ghidra session 62fbfe69). Addresses in
//! comments are 1.14d Game.exe. The RNG is the shared seed64 LCG (rng.zig); this
//! module reuses it — the whole point is matching the roll ORDER exactly.
//!
//! TWO seeds drive the process:
//!   - Room seed   `pRoom->sSeed`             — the ObjGrp/ObjProb slot loop + Fn2 gate.
//!   - Control seed`pGame->pObjectControl->sSeed` — dispatch/placement/shrine/chest rolls.
//! AllocObjectControl (0x546C60) seeds control Low = advanced game seed, High = 0x29A.
//!
//! Scope of this first pass: the Levels.txt ObjGrp loop (dungeon/wilderness path)
//! + Fn1 scatter + Fn2 shrine + MakeRandomChest. The town/special-objects path
//! (OBJECT_PopulateRoomSpecialObjects, DS1 pop-scan) is NOT the ObjGrp path and is
//! documented as a remaining gap (see generateActObjects note + object-population.md).

const std = @import("std");
const rng = @import("rng.zig");
const s = @import("structs.zig");
const txt = @import("../txt.zig");

const sEEDNEXT = rng.sEEDNEXT;

pub const MAX_SHRINE_BUCKETS = 8; // shrines.txt effectclass 0..7

// ── Data tables ───────────────────────────────────────────────────────────────

/// objgroup.txt row: up to 8 (objectId, density, probability) entries + the
/// shrine/well flags. Looked up by the Levels.txt ObjGrp value == this row's
/// `Offset` column (DATATBLS_GetObjGroupTxtRecord).
pub const ObjGroup = struct {
    offset: i32,
    id: [8]i32,
    density: [8]i32,
    prob: [8]i32,
    shrines: i32,
    wells: i32,
};

/// One shrines.txt row's population-relevant fields.
pub const Shrine = struct {
    effect_class: i32, // objgroup bucket 0..7 (SelectRandomShrineType)
    level_min: i32, // dwLevelMin — retry gate in SelectRandomShrineType
};

/// Loaded, read-only object-population data. Long-lived; shared across calls.
pub const Tables = struct {
    gpa: std.mem.Allocator,

    // Objects.txt, indexed by objects.txt row (== the classId CreateUnit receives).
    populate_fn: []i32, // PopulateFn column (0..9 → OBJECTSPOPULATEFN index)
    sub_class: []i32, // SubClass column (density-full gate + special path)
    obj_size_x: []i32,
    obj_size_y: []i32,
    obj_act: []i32,
    obj_gore: []i32,

    // objgroup.txt rows (indexed by array position; look up by `offset`).
    groups: []ObjGroup,

    // shrines.txt rows (indexed by array position).
    shrines: []Shrine,

    // Levels.txt ObjGrp[8]/ObjPrb[8] per level id (keyed by Id via findByInt).
    levels_tbl: txt.Table,

    pub fn load(gpa: std.mem.Allocator) !Tables {
        var ot = try txt.Table.parse(gpa, @embedFile("../excel/Objects.txt"));
        defer ot.deinit();
        const n = ot.rowCount();
        const populate_fn = try gpa.alloc(i32, n);
        errdefer gpa.free(populate_fn);
        const sub_class = try gpa.alloc(i32, n);
        errdefer gpa.free(sub_class);
        const obj_size_x = try gpa.alloc(i32, n);
        errdefer gpa.free(obj_size_x);
        const obj_size_y = try gpa.alloc(i32, n);
        errdefer gpa.free(obj_size_y);
        const obj_act = try gpa.alloc(i32, n);
        errdefer gpa.free(obj_act);
        const obj_gore = try gpa.alloc(i32, n);
        errdefer gpa.free(obj_gore);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            populate_fn[i] = @intCast(ot.int(i, "PopulateFn"));
            sub_class[i] = @intCast(ot.int(i, "SubClass"));
            obj_size_x[i] = @intCast(ot.int(i, "SizeX"));
            obj_size_y[i] = @intCast(ot.int(i, "SizeY"));
            obj_act[i] = @intCast(ot.int(i, "Act"));
            obj_gore[i] = @intCast(ot.int(i, "Gore"));
        }

        var gt = try txt.Table.parse(gpa, @embedFile("../excel/objgroup.txt"));
        defer gt.deinit();
        const gn = gt.rowCount();
        const groups = try gpa.alloc(ObjGroup, gn);
        errdefer gpa.free(groups);
        for (groups, 0..) |*g, r| {
            g.offset = @intCast(gt.int(r, "Offset"));
            g.shrines = @intCast(gt.int(r, "SHRINES"));
            g.wells = @intCast(gt.int(r, "WELLS"));
            inline for (0..8) |k| {
                var b0: [8]u8 = undefined;
                var b1: [12]u8 = undefined;
                var b2: [8]u8 = undefined;
                g.id[k] = @intCast(gt.int(r, std.fmt.bufPrint(&b0, "ID{d}", .{k}) catch unreachable));
                g.density[k] = @intCast(gt.int(r, std.fmt.bufPrint(&b1, "DENSITY{d}", .{k}) catch unreachable));
                g.prob[k] = @intCast(gt.int(r, std.fmt.bufPrint(&b2, "PROB{d}", .{k}) catch unreachable));
            }
        }

        var st = try txt.Table.parse(gpa, @embedFile("../excel/shrines.txt"));
        defer st.deinit();
        const sn = st.rowCount();
        const shrines = try gpa.alloc(Shrine, sn);
        errdefer gpa.free(shrines);
        for (shrines, 0..) |*sh, r| {
            sh.effect_class = @intCast(st.int(r, "effectclass"));
            sh.level_min = @intCast(st.int(r, "LevelMin"));
        }

        const levels_tbl = try txt.Table.parse(gpa, @embedFile("../excel/Levels.txt"));

        return .{
            .gpa = gpa,
            .populate_fn = populate_fn,
            .sub_class = sub_class,
            .obj_size_x = obj_size_x,
            .obj_size_y = obj_size_y,
            .obj_act = obj_act,
            .obj_gore = obj_gore,
            .groups = groups,
            .shrines = shrines,
            .levels_tbl = levels_tbl,
        };
    }

    pub fn deinit(self: *Tables) void {
        self.gpa.free(self.populate_fn);
        self.gpa.free(self.sub_class);
        self.gpa.free(self.obj_size_x);
        self.gpa.free(self.obj_size_y);
        self.gpa.free(self.obj_act);
        self.gpa.free(self.obj_gore);
        self.gpa.free(self.groups);
        self.gpa.free(self.shrines);
        self.levels_tbl.deinit();
    }

    /// objgroup.txt row whose Offset == `obj_grp` (Levels.txt ObjGrp value).
    pub fn group(self: *const Tables, obj_grp: i32) ?*const ObjGroup {
        if (obj_grp <= 0) return null;
        for (self.groups) |*g| if (g.offset == obj_grp) return g;
        return null;
    }

    /// Levels.txt ObjGrp[slot] for a level id.
    pub fn levelObjGrp(self: *const Tables, level_id: i32, slot: usize) i32 {
        const row = self.levels_tbl.findByInt("Id", level_id) orelse return 0;
        var b: [8]u8 = undefined;
        return @intCast(self.levels_tbl.int(row, std.fmt.bufPrint(&b, "ObjGrp{d}", .{slot}) catch unreachable));
    }

    /// Levels.txt ObjPrb[slot] for a level id.
    pub fn levelObjPrb(self: *const Tables, level_id: i32, slot: usize) i32 {
        const row = self.levels_tbl.findByInt("Id", level_id) orelse return 0;
        var b: [8]u8 = undefined;
        return @intCast(self.levels_tbl.int(row, std.fmt.bufPrint(&b, "ObjPrb{d}", .{slot}) catch unreachable));
    }
};

// ── Object control (AllocObjectControl 0x546C60) ────────────────────────────────

/// Per-level object RNG state — D2ObjectRngStrc (0x90 in the engine). Only the
/// population-relevant fields are modeled. `nMinDistance` starts at the sentinel
/// 0x7FFFFFFF and is lazily set to the level's populated-room count; `fill` is the
/// rooms-processed counter (RollAndDispatchPopulateFn reads raw offsets +4/+8/+0xc
/// as fill/area/threshold).
pub const LevelRng = struct {
    n_mon_class_id: i32 = -1,
    n_act: i32 = 0,
    n_min_distance: i32 = 0x7fff_ffff, // sentinel/MAX
    fill: i32 = 0, // pad_0x4 — rooms-processed / fill counter
    pad_0x10: i32 = 0,
};

/// AllocObjectControl (0x546C60). Control seed Low = advanced game seed, High =
/// 0x29A; per-level RNG (nAct from Levels.txt, nMinDistance sentinel); shrine RNG
/// buckets keyed by shrines.txt effectclass 0..7.
///
/// The "advanced game seed" is pGame->pGameSeed stepped once. In the standalone we
/// derive it as one advance of {seed, 0x29A} (== the act start seed low). This only
/// affects the CONTROL-seed rolls (dispatch/scatter/shrine/chest), which have no
/// golden yet — documented assumption.
pub const ObjectControl = struct {
    gpa: std.mem.Allocator,
    sSeed: s.D2SeedStrc,
    levels: []LevelRng, // indexed by level id
    /// aShrinesRng[effectClass] = shrine line indices in that class (0..7).
    shrine_buckets: [MAX_SHRINE_BUCKETS][]i32,

    pub fn init(gpa: std.mem.Allocator, tbl: *const Tables, game_seed: u32, level_acts: []const i32) !ObjectControl {
        // Control seed: advance {seed, 0x29A} once, take the low word (SEED_InitDefault
        // sets High = 0x29A, then AllocObjectControl overwrites Low from the advanced
        // game seed and keeps High = 0x29A).
        const advanced = sEEDNEXT(.{ .nSeedLow = @bitCast(game_seed), .nSeedHigh = 0x29a });
        const sSeed = s.D2SeedStrc{ .nSeedLow = advanced.nSeedLow, .nSeedHigh = 0x29a };

        const levels = try gpa.alloc(LevelRng, level_acts.len);
        errdefer gpa.free(levels);
        for (levels, 0..) |*lr, i| lr.* = .{ .n_act = level_acts[i] };

        var buckets: [MAX_SHRINE_BUCKETS][]i32 = .{&[_]i32{}} ** MAX_SHRINE_BUCKETS;
        // First pass: count shrines per effectclass (< 8).
        var counts = [_]usize{0} ** MAX_SHRINE_BUCKETS;
        for (tbl.shrines) |sh| {
            if (sh.effect_class >= 0 and sh.effect_class < MAX_SHRINE_BUCKETS) counts[@intCast(sh.effect_class)] += 1;
        }
        // Alloc + fill (aShrinesRng[class][n++] = shrine line index).
        var fill_idx = [_]usize{0} ** MAX_SHRINE_BUCKETS;
        for (0..MAX_SHRINE_BUCKETS) |c| {
            if (counts[c] == 0) continue;
            buckets[c] = try gpa.alloc(i32, counts[c]);
        }
        errdefer for (buckets) |b| if (b.len != 0) gpa.free(b);
        for (tbl.shrines, 0..) |sh, line| {
            if (sh.effect_class >= 0 and sh.effect_class < MAX_SHRINE_BUCKETS) {
                const c: usize = @intCast(sh.effect_class);
                buckets[c][fill_idx[c]] = @intCast(line);
                fill_idx[c] += 1;
            }
        }

        return .{ .gpa = gpa, .sSeed = sSeed, .levels = levels, .shrine_buckets = buckets };
    }

    pub fn deinit(self: *ObjectControl) void {
        self.gpa.free(self.levels);
        for (self.shrine_buckets) |b| if (b.len != 0) self.gpa.free(b);
    }

    pub fn levelRng(self: *ObjectControl, level_id: i32) ?*LevelRng {
        if (level_id < 0 or level_id >= self.levels.len) return null;
        return &self.levels[@intCast(level_id)];
    }
};

// ── Leaf helpers (faithful, deterministic, unit-testable) ──────────────────────

/// Direction offset tables (0x731b7c / 0x731b9c) — the 8 compass dirs.
pub const gnDirectionXOffsets = [8]i32{ -1, 0, 1, -1, 1, -1, 0, 1 };
pub const gnDirectionYOffsets = [8]i32{ -1, -1, -1, 0, 0, 1, 1, 1 };

/// OBJECT_SelectRandomShrineType (0x54F770). Clamps category (0 or >4 → 2), rolls
/// a shrine line from the effectclass bucket via the CONTROL seed, retrying up to
/// 8× while the picked shrine's LevelMin > nLevelId. Returns the shrines.txt line
/// index (never 0 → clamped to 1). One control-seed advance per retry.
pub fn selectRandomShrineType(ctrl: *ObjectControl, tbl: *const Tables, n_level_id: i32, category_in: i32) i32 {
    var category = category_in;
    if (category == 0 or category > 4) category = 2;
    const bucket = ctrl.shrine_buckets[@intCast(category)];
    if (bucket.len == 0) return 1; // engine HALTs; we return the clamped-min line
    var shrine_line: i32 = 1;
    var retries: i32 = 8;
    while (true) {
        const idx = rng.randomNumberSelector(&ctrl.sSeed, @intCast(bucket.len));
        shrine_line = bucket[@intCast(idx)];
        if (shrine_line == 0) shrine_line = 1;
        const lvl_min: i32 = if (shrine_line >= 0 and shrine_line < tbl.shrines.len) tbl.shrines[@intCast(shrine_line)].level_min else 0;
        retries -= 1;
        if (!(n_level_id < lvl_min and retries > 0)) break;
    }
    return shrine_line;
}

/// MakeRandomChest (0x54F180). One CONTROL-seed roll into an act/level-specific
/// chest-id table. `n_mon_stats_id == 0x173` forces chest id 0x173. Returns the
/// object class id to spawn.
pub fn makeRandomChest(ctrl: *ObjectControl, level_id: i32, act: i32, n_mon_stats_id: i32) i32 {
    if (n_mon_stats_id == 0x173) return 0x173;
    // Act II Arcane Sanctuary (level 74): seed.low & 3 → {0x183,0x185,0x186,0x187}.
    if (level_id == 74) {
        const t = [4]i32{ 0x183, 0x185, 0x186, 0x187 };
        return t[rng.randomNumberSelector(&ctrl.sSeed, 4)];
    }
    // Act III Travincal (level 83): seed.low & 3 → {0x149,0x14a,0x14b,0x14c}.
    if (level_id == 83) {
        const t = [4]i32{ 0x149, 0x14a, 0x14b, 0x14c };
        return t[rng.randomNumberSelector(&ctrl.sSeed, 4)];
    }
    // Act II other: {0x57,0x58} via (seed.low & 1).
    if (act == 1) {
        const t = [2]i32{ 0x57, 0x58 };
        return t[rng.randomNumberSelector(&ctrl.sSeed, 2)];
    }
    // Act III other: {0xb5,0xb7} via (seed.low & 1).
    if (act == 2) {
        const t = [2]i32{ 0xb5, 0xb7 };
        return t[rng.randomNumberSelector(&ctrl.sSeed, 2)];
    }
    // Default (13 entries): seed.low % 13.
    const t = [13]i32{ 5, 6, 0x8b, 0x8c, 0x8d, 0x90, 0xb0, 0xb1, 0xc6, 0xf0, 0xf1, 0xf2, 0xf3 };
    return t[rng.randomNumberSelector(&ctrl.sSeed, 13)];
}

// ── Room population (OBJECT_PopulateRoomObjects 0x552610) ───────────────────────

/// A spawned object: class id + world subtile position. `preset` distinguishes DS1
/// preset objects (already handled by preset.zig) from populate-fn spawns.
/// `placeholder_pos` marks spawns whose POSITION could not be faithfully modeled —
/// the spawn-point/biased placers (Fn2 shrine, Fn8 well: OBJECT_PlaceAtBiasedPosition
/// / OBJECT_PlaceWithCallback near a level spawn point, which we do not model) — so we
/// record the object at the room CENTER. The object's existence + class + per-room
/// COUNT are room-seed-faithful; only the exact tile is a placeholder. Consumers that
/// need real coordinates (e.g. the automap) should skip placeholder-position spawns.
pub const SpawnedObject = struct { class_id: i32, x: i32, y: i32, preset: bool = false, placeholder_pos: bool = false };

/// A world subtile position (named so Fn3's optional return unifies with its local).
const Pos = struct { x: i32, y: i32 };

/// A room's spatial context for population (world subtile coords + a collision
/// probe). The engine reads DRLGROOM_GetRoomCoordinates (dwXStart/dwYStart/XSize/
/// YSize) + ROOM_CheckSpawnCollision(pRoom, x, y, sx, sy) → 1 = clear.
pub const RoomCtx = struct {
    x_start: i32,
    y_start: i32,
    x_size: i32, // subtiles
    y_size: i32,
    /// ROOM_CheckSpawnCollision: return true when (x,y) footprint is clear. Default
    /// always-clear when no collision map is wired (positions then unfaithful).
    collision: *const fn (ctx: *anyopaque, x: i32, y: i32, sx: i32, sy: i32) bool = alwaysClear,
    collision_ctx: *anyopaque = undefined,

    fn check(self: *const RoomCtx, x: i32, y: i32, sx: i32, sy: i32) bool {
        return self.collision(self.collision_ctx, x, y, sx, sy);
    }
};

fn alwaysClear(_: *anyopaque, _: i32, _: i32, _: i32, _: i32) bool {
    return true;
}

/// The per-run population state threaded through the leaf fns.
pub const Populator = struct {
    tbl: *const Tables,
    ctrl: *ObjectControl,
    level_id: i32,
    act: i32,
    out: *std.ArrayListUnmanaged(SpawnedObject),
    gpa: std.mem.Allocator,
    gore_gate: i32 = 1, // gbObjectPopulateInitialized (expansion/difficulty gate)

    fn emit(self: *Populator, class_id: i32, x: i32, y: i32) void {
        self.out.append(self.gpa, .{ .class_id = class_id, .x = x, .y = y, .preset = false }) catch {};
    }

    /// Emit a spawn whose exact tile is a placeholder (spawn-point placement unmodeled).
    fn emitPlaceholder(self: *Populator, class_id: i32, x: i32, y: i32) void {
        self.out.append(self.gpa, .{ .class_id = class_id, .x = x, .y = y, .preset = false, .placeholder_pos = true }) catch {};
    }
};

/// OBJECT_PopulateRoomObjects (0x552610) — the Levels.txt ObjGrp/ObjProb 8-slot
/// loop, keyed on the ROOM seed. The special-objects path (0x552560) runs first in
/// the engine; here it is a no-op that returns "run the ObjGrp loop" (we do not
/// model the DS1 special-populate mask / grid-pop fns — see module header).
///
/// Roll order per slot 0..7 (verbatim from the RE map):
///   1. advance ROOM seed → nGrpEntryIdx = %100.
///   2. density-full force: nGrpEntryIdx = 100 when the level's fill exceeds ~75%
///      of its room count and the group object has SubClass != 0.
///   3. gate: nObjGrpId != 0 && nGrpEntryIdx <= ObjPrb[slot].
///   4. advance ROOM seed again → pick roll %100; walk group entries accumulating
///      PROB[i]; first entry where pick < cum (and Gore <= gate) is chosen.
///   5. dispatch OBJECTSPOPULATEFN[PopulateFn(id)] (0 = NULL/no-op).
pub fn populateRoomObjects(pop: *Populator, room_seed: *s.D2SeedStrc, room: *const RoomCtx) void {
    const lr = pop.ctrl.levelRng(pop.level_id);
    var slot: usize = 0;
    while (slot < 8) : (slot += 1) {
        const obj_grp = pop.tbl.levelObjGrp(pop.level_id, slot);
        var grp_entry_idx: i32 = @intCast(rng.randomNumberSelector(room_seed, 100));

        // Density-full force-100. nMinDistance is the level's populated-room count;
        // fill is rooms processed so far. (Inert in the standalone unless a caller
        // drives fill/nMinDistance.) Uses ObjectsTxt(obj_grp).SubClass per the RE
        // decompile — an ambiguous index (obj_grp is a group offset); kept faithful.
        if (lr) |l| {
            if (l.n_min_distance > 0 and l.pad_0x10 == 0) {
                const ratio = @divTrunc(l.fill << 7, l.n_min_distance);
                const sub = if (obj_grp >= 0 and obj_grp < pop.tbl.sub_class.len) pop.tbl.sub_class[@intCast(obj_grp)] else 0;
                if (ratio > 0x60 and sub != 0) grp_entry_idx = 100;
            }
        }

        const obj_prb = pop.tbl.levelObjPrb(pop.level_id, slot);
        if (!(obj_grp != 0 and grp_entry_idx <= obj_prb)) continue;

        const grp = pop.tbl.group(obj_grp) orelse return;

        // Advance ROOM seed again — the cumulative-probability pick roll.
        const pick_roll: i32 = @intCast(rng.randomNumberSelector(room_seed, 100));
        var cum: i32 = 0;
        var chosen: ?usize = null;
        for (0..8) |i| {
            cum += grp.prob[i];
            const id = grp.id[i];
            const gore = if (id >= 0 and id < pop.tbl.obj_gore.len) pop.tbl.obj_gore[@intCast(id)] else 0;
            if (pick_roll < cum and gore <= pop.gore_gate) {
                chosen = i;
                break;
            }
        }
        const ci = chosen orelse continue;
        const class_id = grp.id[ci];
        const density = grp.density[ci];
        if (density > 0x7f) continue;
        if (class_id < 0 or class_id >= pop.tbl.populate_fn.len) continue;
        const fn_idx = pop.tbl.populate_fn[@intCast(class_id)];
        dispatchPopulateFn(pop, fn_idx, room_seed, room, @intCast(@as(u8, @intCast(@min(density, 0x7f)))), class_id, 100);
    }
}

/// Dispatch OBJECTSPOPULATEFN[idx] (the 1.14d function table). Index 0 = NULL
/// (no-op). Every leaf 1..9 is ported. `room_seed` is `pRoom->sSeed`; the control
/// seed lives on `pop.ctrl.sSeed`. CRUCIAL for the ObjGrp slot loop: Fn2/Fn8/Fn9
/// gate on the ROOM seed (advancing it once), Fn1/Fn3/Fn4/Fn5/Fn7 gate on the
/// CONTROL seed (leaving the room seed untouched). `chance` is always 100 from
/// OBJECT_PopulateRoomObjects, so the entry chance gate never rejects — but the
/// seed advance it performs is faithful and must happen.
fn dispatchPopulateFn(pop: *Populator, idx: i32, room_seed: *s.D2SeedStrc, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) void {
    switch (idx) {
        0 => {}, // NULL slot — no populate fn
        1 => populateFn1(pop, room, density, class_id, chance),
        2 => populateFn2Shrine(pop, room_seed, room, density, class_id, chance),
        3 => {
            _ = populateFn3Scatter(pop, room, density, class_id, chance);
        },
        4 => populateFn4(pop, room, density, chance),
        5 => populateFn5(pop, room, density, class_id, chance),
        6 => populateFn6(pop, room, density, class_id, chance),
        7 => populateFn7(pop, room, density, class_id, chance),
        8 => populateFn8Well(pop, room_seed, room, density, class_id, chance),
        9 => populateFn9Scatter(pop, room_seed, room, density, class_id, chance),
        else => {},
    }
}

/// Advance `seed` once and return low % 100 (the engine's inlined chance roll:
/// `low - (low/100)*100` on the unsigned low word). Returns true when the caller
/// should PROCEED, i.e. `roll <= chance` (equivalently NOT `chance < roll`).
inline fn chanceGate(seed: *s.D2SeedStrc, chance: u16) bool {
    const next = rng.sEEDNEXT(seed.*);
    seed.* = next;
    const roll: u32 = @as(u32, @bitCast(next.nSeedLow)) % 100;
    return roll <= @as(u32, chance);
}

/// scatter target count = (int)((ySize*xSize >> 7) * density) >> 8 (signed shifts).
inline fn scatterTarget(room: *const RoomCtx, density: u8) i32 {
    const area = (room.y_size * room.x_size) >> 7;
    return (area * @as(i32, density)) >> 8;
}

inline fn objSize(pop: *Populator, class_id: i32) struct { x: i32, y: i32 } {
    const sx = if (class_id >= 0 and class_id < pop.tbl.obj_size_x.len) pop.tbl.obj_size_x[@intCast(class_id)] else 1;
    const sy = if (class_id >= 0 and class_id < pop.tbl.obj_size_y.len) pop.tbl.obj_size_y[@intCast(class_id)] else 1;
    return .{ .x = sx, .y = sy };
}

/// Objects_PopulateFn1 (0x550C20) — decorative/destructible scatter (barrels id3,
/// racks id0x59, light id4, urns id0xd0/0xd1). CONTROL-seed chance gate, then a
/// scatter loop that (per iteration) rolls a variant index, an X and a Y in the
/// room rect, collision-checks, and on success grows an 8-dir cluster chain.
///
/// RESIDUAL: the per-class variant id tables (gnObjectClassIdBarrel /
/// gaObjectSpawnRackIds / gaObjectSpawnChanceTbl …) and their counts were not
/// dumped, and cluster growth is gated by ROOM_CheckSpawnCollision which needs the
/// room collision grid we don't wire here (RoomCtx.check defaults to always-clear).
/// We therefore roll the variant index off a non-zero placeholder count (the seed
/// advance is identical for any modulus >= 1, so the roll ORDER is preserved) and
/// emit the objgroup base `class_id`. All Fn1 objects have objects.txt AutoMap=0,
/// so they never reach the automap — only the seed accounting matters here.
fn populateFn1(pop: *Populator, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) void {
    if (!chanceGate(&pop.ctrl.sSeed, chance)) return;
    const sz = objSize(pop, class_id);
    var target = scatterTarget(room, density);
    if (target < 1) return;
    // nMaxRetries: 0x12 for barrels (id 3), else 0xc. spreadMax/spreadRadius 5/5,
    // except light(4)/urns(0xd0,0xd1) which use spreadMax 0 (no chain spread).
    var retries: i32 = if (class_id == 3) 0x12 else 0xc;
    const spread_max: i32 = if (class_id == 4 or class_id == 0xd0 or class_id == 0xd1) 0 else 5;
    const spread_radius: i32 = 5;
    const variant_count: u32 = 2; // placeholder (see RESIDUAL) — modulus>=1 => identical advance
    while (retries > 0 and target > 0) {
        _ = rng.randomNumberSelector(&pop.ctrl.sSeed, variant_count); // variant pick roll
        const rx = pickPos(&pop.ctrl.sSeed, room.x_size - sz.x - 1) + room.x_start;
        const ry = pickPos(&pop.ctrl.sSeed, room.y_size - sz.y - 1) + room.y_start;
        if (!room.check(rx, ry, sz.x, sz.y)) {
            retries -= 1;
            continue;
        }
        pop.emit(class_id, rx, ry);
        // Cluster chain — grow while collision keeps clearing (bounded).
        var chain_len: i32 = 1;
        var cx = rx;
        var cy = ry;
        var walk: i32 = @max(target, 4) * 3;
        while (walk > 0) : (walk -= 1) {
            const r = chain_len >> 1;
            if (r > 0 and rng.randomNumberSelector(&pop.ctrl.sSeed, @intCast(r)) != 0) break;
            const dir: usize = @intCast(@as(u32, @bitCast(rng.RollRandomSeed(&pop.ctrl.sSeed))) & 7);
            const mx: i32 = if (spread_max > 0) @intCast(rng.randomNumberSelector(&pop.ctrl.sSeed, @intCast(spread_max))) else 0;
            const my: i32 = if (spread_max > 0) @intCast(rng.randomNumberSelector(&pop.ctrl.sSeed, @intCast(spread_max))) else 0;
            cx += (mx + spread_radius) * gnDirectionXOffsets[dir] * 2;
            cy += (my + spread_radius) * gnDirectionYOffsets[dir] * 2;
            if (!room.check(cx, cy, sz.x, sz.y)) continue;
            _ = rng.randomNumberSelector(&pop.ctrl.sSeed, variant_count);
            pop.emit(class_id, cx, cy);
            chain_len += 1;
        }
        target -= 1;
    }
}

/// Objects_PopulateFn2 (0x552B50) — shrine. Advances the ROOM seed once for the
/// chance gate (density-force path inert here), then places ONE shrine near a level
/// spawn point via OBJECT_PlaceAtBiasedPosition (up to 3 retries).
///
/// RESIDUAL: OBJECT_PlaceAtBiasedPosition biases toward the level's spawn-point set
/// and consumes control-seed rolls we don't model, and OBJECT_SelectRandomShrineType
/// / SetShrineTxtRecordInObjectData (density-force only) picks the concrete shrine
/// txt line without changing the OBJECT class. We emit the objgroup shrine class
/// (objects.txt AutoMap=310) at the room CENTER as a placeholder position; the COUNT
/// (one per room reaching Fn2) is room-seed-deterministic and faithful.
fn populateFn2Shrine(pop: *Populator, room_seed: *s.D2SeedStrc, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) void {
    _ = density;
    if (!chanceGate(room_seed, chance)) return;
    pop.emitPlaceholder(class_id, room.x_start + @divTrunc(room.x_size, 2), room.y_start + @divTrunc(room.y_size, 2));
}

/// Objects_PopulateFn3 (0x551470) — density scatter via OBJECT_PlaceAtRandomPosition.
/// CONTROL-seed chance gate; count = (area>>7 * density)>>8; one X/Y control-seed
/// position roll per unit. Returns the last placed (x,y) for Fn6's bonus chest.
fn populateFn3Scatter(pop: *Populator, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) ?Pos {
    if (!chanceGate(&pop.ctrl.sSeed, chance)) return null;
    const sz = objSize(pop, class_id);
    var target = scatterTarget(room, density);
    var last: ?Pos = null;
    while (target > 0) : (target -= 1) {
        const rx = pickPos(&pop.ctrl.sSeed, room.x_size - sz.x - 1) + room.x_start;
        const ry = pickPos(&pop.ctrl.sSeed, room.y_size - sz.y - 1) + room.y_start;
        if (room.check(rx, ry, sz.x, sz.y)) {
            pop.emit(class_id, rx, ry);
            last = .{ .x = rx, .y = ry };
        }
    }
    return last;
}

/// Objects_PopulateFn4 (0x551850) — CONTROL-seed scatter of object cluster class
/// ~0xb (0xb or 0x7 via a low&3 roll), footprint from objects.txt line 7. Positions
/// are full-size room-rect rolls (rand(xSize)/rand(ySize)); on a clear cell it grows
/// a chain (up to 8) offset by the object's XSpace/YSpace. All Fn4 classes have
/// AutoMap=0. RESIDUAL: XSpace/YSpace + ROOM_CheckSpawnCollisionSimple (collision
/// grid) unmodeled — chain positions approximate; base class 0xb emitted.
fn populateFn4(pop: *Populator, room: *const RoomCtx, density: u8, chance: u16) void {
    if (!chanceGate(&pop.ctrl.sSeed, chance)) return;
    const sz = objSize(pop, 7);
    var target = scatterTarget(room, density);
    var retries: i32 = target * 2;
    var total: i32 = 0;
    while (target > 0 and retries > 0) : (retries -= 1) {
        const variant = rng.randomNumberSelector(&pop.ctrl.sSeed, 3); // low%3 -> 0xb/0x7
        const rx = pickPos(&pop.ctrl.sSeed, room.x_size) + room.x_start;
        const ry = pickPos(&pop.ctrl.sSeed, room.y_size) + room.y_start;
        if (!room.check(rx, ry, sz.x, sz.y)) continue;
        const cls: i32 = if (variant != 0) 0x7 else 0xb;
        pop.emit(cls, rx, ry);
        total += 1;
        if (total >= 8) return;
        target -= 1;
    }
}

/// Objects_PopulateFn5 (0x551C00) — CONTROL-seed scatter of nObjectClassId (or, when
/// class==0x2e, a pick from gaObjectSpawnChanceTbl). Full-size room-rect position
/// rolls + 8-dir chain via XSpace/YSpace. AutoMap=0 for these classes. RESIDUAL:
/// gaObjectSpawnChanceTbl/gnObjectClassIdLight + collision grid unmodeled — we emit
/// nObjectClassId and preserve the roll count for the 0x2e table pick.
fn populateFn5(pop: *Populator, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) void {
    if (!chanceGate(&pop.ctrl.sSeed, chance)) return;
    const sz = objSize(pop, class_id);
    var target = scatterTarget(room, density);
    if (target < 1) return;
    var retries: i32 = target * 2;
    var total: i32 = 0;
    while (retries > 0 and target > 0) : (retries -= 1) {
        if (class_id == 0x2e) _ = rng.randomNumberSelector(&pop.ctrl.sSeed, 2); // table pick roll
        const rx = pickPos(&pop.ctrl.sSeed, room.x_size) + room.x_start;
        const ry = pickPos(&pop.ctrl.sSeed, room.y_size) + room.y_start;
        if (!room.check(rx, ry, sz.x, sz.y)) continue;
        pop.emit(class_id, rx, ry);
        total += 1;
        if (total >= 8) return;
        target -= 1;
    }
}

/// Objects_PopulateFn6 (0x551690) — runs Fn3, then (if a unit was placed) rolls a
/// bonus super-chest on it (OBJECT_SpawnBonusChest).
fn populateFn6(pop: *Populator, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) void {
    if (populateFn3Scatter(pop, room, density, class_id, chance)) |p| spawnBonusChest(pop, p.x, p.y);
}

/// Objects_PopulateFn7 (0x551200) — CONTROL-seed chance gate, then picks a spawn
/// offset group and tries up to 8 room-rect positions; on a clear cell it walks the
/// group's offset table creating class 0x39/0x3a units, each seeding a bonus chest.
/// RESIDUAL: gObjectSpawnOffsetCounts / PTR_DAT_00731eb4 offset tables + collision
/// grid unmodeled — we place a single 0x39/0x3a unit per clear cell (AutoMap=0) and
/// roll the bonus chest so the seed accounting is preserved.
fn populateFn7(pop: *Populator, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) void {
    _ = density; // Fn7 ignores nDensity (fixed 8-position try, not area-scaled)
    if (!chanceGate(&pop.ctrl.sSeed, chance)) return;
    _ = rng.randomNumberSelector(&pop.ctrl.sSeed, 4); // spawn-group index roll (count placeholder)
    const sz = objSize(pop, class_id);
    var tries: i32 = 8;
    while (tries > 0) : (tries -= 1) {
        const rx = pickPos(&pop.ctrl.sSeed, room.x_size - sz.x - 1) + room.x_start;
        const ry = pickPos(&pop.ctrl.sSeed, room.y_size - sz.y - 1) + room.y_start;
        if (!room.check(rx, ry, sz.x, sz.y)) continue;
        const cls: i32 = 0x39 + @as(i32, @intCast(@as(u32, @bitCast(rng.RollRandomSeed(&pop.ctrl.sSeed))) & 1));
        pop.emit(cls, rx, ry);
        spawnBonusChest(pop, rx, ry);
        return;
    }
}

/// Objects_PopulateFn8 (0x5516C0) — well. Quest-status gated (inert here), advances
/// the ROOM seed once for the chance gate, then places the object near a spawn point
/// via OBJECT_PlaceWithCallback. RESIDUAL: quest status + spawn-point placement
/// unmodeled — we emit the objgroup well class (objects.txt AutoMap=309) at the room
/// CENTER; the COUNT (one per room reaching Fn8) is room-seed-deterministic.
fn populateFn8Well(pop: *Populator, room_seed: *s.D2SeedStrc, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) void {
    _ = density;
    if (!chanceGate(room_seed, chance)) return;
    pop.emitPlaceholder(class_id, room.x_start + @divTrunc(room.x_size, 2), room.y_start + @divTrunc(room.y_size, 2));
}

/// Objects_PopulateFn9 (0x551580) — DISTINCT from Fn3: identical density scatter via
/// OBJECT_PlaceAtRandomPosition but the chance gate advances the ROOM seed (Fn3 uses
/// the CONTROL seed). Getting the gated seed right keeps the ObjGrp slot loop's
/// room-seed stream faithful for later slots in the same room.
fn populateFn9Scatter(pop: *Populator, room_seed: *s.D2SeedStrc, room: *const RoomCtx, density: u8, class_id: i32, chance: u16) void {
    if (!chanceGate(room_seed, chance)) return;
    const sz = objSize(pop, class_id);
    var target = scatterTarget(room, density);
    while (target > 0) : (target -= 1) {
        const rx = pickPos(&pop.ctrl.sSeed, room.x_size - sz.x - 1) + room.x_start;
        const ry = pickPos(&pop.ctrl.sSeed, room.y_size - sz.y - 1) + room.y_start;
        if (room.check(rx, ry, sz.x, sz.y)) pop.emit(class_id, rx, ry);
    }
}

/// OBJECT_SpawnBonusChest (0x551150). One CONTROL-seed advance; if low%100 > 0x46
/// (~29% chance) spawns a super-chest (class 0x67) at the unit's position.
fn spawnBonusChest(pop: *Populator, x: i32, y: i32) void {
    const next = rng.sEEDNEXT(pop.ctrl.sSeed);
    pop.ctrl.sSeed = next;
    if (@as(u32, @bitCast(next.nSeedLow)) % 100 > 0x46) pop.emit(0x67, x, y);
}

/// rand(n) off a seed, guarding n < 1 (RANDOM_RandomNumberSelector semantics).
inline fn pickPos(seed: *s.D2SeedStrc, n: i32) i32 {
    if (n < 1) return 0;
    return @intCast(rng.randomNumberSelector(seed, @intCast(n)));
}

const testing = std.testing;

test "objpop tables load + objgroup lookup" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    // objgroup Offset 3 = "Indoor Chests": ID0=5 (chest), density0=48, prob0=50.
    const g = t.group(3) orelse return error.NoGroup;
    try testing.expectEqual(@as(i32, 5), g.id[0]);
    try testing.expectEqual(@as(i32, 48), g.density[0]);
    try testing.expectEqual(@as(i32, 50), g.prob[0]);
    // Cave 1 (L8) uses ObjGrp0 = 6.
    try testing.expectEqual(@as(i32, 6), t.levelObjGrp(8, 0));
    // Town (L1) uses no object groups.
    try testing.expectEqual(@as(i32, 0), t.levelObjGrp(1, 0));
    // Objects.txt: chest (id 5) has a populate fn.
    try testing.expect(t.populate_fn.len > 400);
}

test "object control init: seed + shrine buckets" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    const acts = [_]i32{ 0, 0, 0 };
    var ctrl = try ObjectControl.init(testing.allocator, &t, 305419896, &acts);
    defer ctrl.deinit();
    // Control seed High is always 0x29A; Low = advanced game seed low.
    try testing.expectEqual(@as(i32, 0x29a), ctrl.sSeed.nSeedHigh);
    const adv = sEEDNEXT(.{ .nSeedLow = @bitCast(@as(u32, 305419896)), .nSeedHigh = 0x29a });
    try testing.expectEqual(adv.nSeedLow, ctrl.sSeed.nSeedLow);
    // Shrine buckets partition every shrine line by effectclass (0..7).
    var total: usize = 0;
    for (ctrl.shrine_buckets) |b| total += b.len;
    var expect: usize = 0;
    for (t.shrines) |sh| if (sh.effect_class >= 0 and sh.effect_class < 8) {
        expect += 1;
    };
    try testing.expectEqual(expect, total);
}

test "makeRandomChest: faithful table pick + deterministic roll order" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    const acts = [_]i32{0} ** 200;
    var ctrl = try ObjectControl.init(testing.allocator, &t, 12345, &acts);
    defer ctrl.deinit();

    // MonStats id 0x173 forces chest 0x173 with NO seed advance.
    const before = ctrl.sSeed;
    try testing.expectEqual(@as(i32, 0x173), makeRandomChest(&ctrl, 8, 0, 0x173));
    try testing.expectEqual(before.nSeedLow, ctrl.sSeed.nSeedLow);

    // Default 13-entry table: exactly one advance, index = low % 13.
    var probe = ctrl.sSeed;
    const expect_idx = rng.randomNumberSelector(&probe, 13);
    const t13 = [13]i32{ 5, 6, 0x8b, 0x8c, 0x8d, 0x90, 0xb0, 0xb1, 0xc6, 0xf0, 0xf1, 0xf2, 0xf3 };
    try testing.expectEqual(t13[expect_idx], makeRandomChest(&ctrl, 8, 0, 0));
    try testing.expectEqual(probe.nSeedLow, ctrl.sSeed.nSeedLow); // advanced exactly once

    // Arcane Sanctuary (level 74) uses the 4-entry 0x18x table.
    const c = makeRandomChest(&ctrl, 74, 1, 0);
    try testing.expect(c == 0x183 or c == 0x185 or c == 0x186 or c == 0x187);
    // Travincal (level 83) uses the 0x149.. table.
    const tv = makeRandomChest(&ctrl, 83, 2, 0);
    try testing.expect(tv >= 0x149 and tv <= 0x14c);
}

test "selectRandomShrineType: category clamp + LevelMin retry order" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    const acts = [_]i32{0} ** 200;
    var ctrl = try ObjectControl.init(testing.allocator, &t, 999, &acts);
    defer ctrl.deinit();

    // Category 0/>4 clamps to 2; result is a valid shrines.txt line index.
    const line = selectRandomShrineType(&ctrl, &t, 99, 0);
    try testing.expect(line >= 0 and line < t.shrines.len);
    // With a high nLevelId the retry never trips LevelMin; deterministic single roll.
    var ctrl2 = try ObjectControl.init(testing.allocator, &t, 999, &acts);
    defer ctrl2.deinit();
    var probe = ctrl2.sSeed;
    const bucket = ctrl2.shrine_buckets[2];
    if (bucket.len > 0) {
        const idx = rng.randomNumberSelector(&probe, @intCast(bucket.len));
        try testing.expectEqual(bucket[idx], selectRandomShrineType(&ctrl2, &t, 99, 2));
    }
}
