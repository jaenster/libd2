//! Seeded MONSTER-population subsystem — faithful port of D2 1.14d's server-side
//! monster spawner. This is the sibling of objpop.zig (object population): after a
//! room is built and loaded (InitNewRooms), the engine seeds it with monsters per
//! the level's MonsterRegion density.
//!
//! Ghidra session 62fbfe69. Addresses in comments are 1.14d Game.exe.
//!
//! THREE seed streams drive monster population (mirrors objpop's two):
//!   - REGION seed  {gameSeedLow, 0x29A} — one continuous stream over ALL levels in
//!     AllocMonsterRegion (0x5479c0): PopulateMonsterTypes picks each level's monster
//!     roster from Levels.txt, then SEED_RollChampionPack rolls GFX variants.
//!   - GAME seed    pGame->pGameSeed     — the per-density-slot spawn roll in
//!     MONSTER_SpawnRoomMonsters (0x54ec90). Advanced IN PLACE, one advance per slot
//!     (plus one more for a sparsePopulate monster). This is a SEPARATE stream from
//!     the DRLG/object/region seeds and persists across every room and level.
//!   - ROOM seed    pRoom->sSeed         — the monster-type roll, spawn-density class,
//!     unique/boss gating, group position, and wandering-monster init all roll off the
//!     room seed (RANDOM_RandomNumberSelector / D2_SEED_NEXT).
//!
//! WHAT IS FAITHFULLY MODELED (seed-deterministic, no runtime geometry needed):
//!   - The per-level monster ROSTER (MONREGION_PopulateMonsterTypes 0x5475e0): which
//!     N of the level's mon[]/nmon[] class-ids are picked, in roll order, with rarity.
//!   - The per-slot density gate (game seed % 100000 <= MonDen), the weighted-rarity
//!     monster-type roll (MONREGION_RollRandomMonsterType 0x5bde80), the unique/normal
//!     classification (MONSTERREGION_CheckSpawnDensity 0x5be020), fallen/scarab group
//!     override (0x54ec40), sparsePopulate skip, and normal group min size.
//!
//! RESIDUALS (documented, need unmodeled runtime state):
//!   - CHAMPION PACK (SEED_RollChampionPack 0x5bdb20) rolls GFX component variants per
//!     roster monster and ADVANCES the region seed. It needs MonStats2.txt aComponents
//!     (not shipped in this repo). We SKIP it — so the region roster is byte-faithful
//!     only for the FIRST monster-bearing level in the stream; later levels diverge by
//!     exactly the champion-roll count. Adding monstats2 closes this. It never touches
//!     the class SET of a monster, only its appearance, and does not affect the GAME or
//!     ROOM spawn streams.
//!   - POSITION: SPAWN_FindRandomPositionForMonster / SPAWN_SpawnMonsterGroupAtRandom
//!     (0x54ddc0) pick x,y off the room seed AND collision (GetRoomCorners +
//!     ROOM_CheckSpawnCollision). Without the room collision grid + coord-list sub-rects
//!     we emit placeholder positions (room center) and do NOT replay their room-seed
//!     advances — so the room-seed stream diverges after the first spawn in a room.
//!   - COUNT: SPAWN_SpawnMonsterWithMinions (0x54df80) draws the minion count off the
//!     freshly-created unit's OWN seed (assigned in CreateUnit, unmodeled). We emit the
//!     guaranteed minimum group size (MinGrp); the random extra up to MaxGrp is a gap.
//!   - UNIQUE PACK internals (SpawnUniquePack) + SetMinionsForBoss are not replayed;
//!     we emit the unique boss (flags.unique) with count 1.
//!   - COORD LIST: the engine iterates DRLGROOM_GetCoordList sub-rects; we approximate
//!     each room as a single rect (its world bounds). This changes the density-slot
//!     count and thus the game-seed stream vs a real capture.

const std = @import("std");
const rng = @import("rng.zig");
const s = @import("structs.zig");
const txt = @import("../txt.zig");

const sEEDNEXT = rng.sEEDNEXT;
const randSel = rng.randomNumberSelector;

pub const MAX_MON_DATA = 13; // D2MonsterRegionFieldStrc[13]

// ── Data tables ────────────────────────────────────────────────────────────────

/// One MonStats.txt row's population-relevant fields, indexed by class id (the
/// value that mon[]/nmon[]/umon[] resolve to and that pTxtMonStats is indexed by).
pub const MonStat = struct {
    rarity: i32, // Rarity — weighted-selection weight
    is_spawn: bool, // isSpawn — gates roster inclusion + density spawn
    ranged_type: bool, // rangedtype — rangedspawn first-pick retry gate
    min_grp: i32, // MinGrp
    max_grp: i32, // MaxGrp
    sparse_populate: i32, // sparsePopulate — % skip gate
    spawn: i32, // spawn (resolved class id, -1 = none) — spawn-replacement target
    place_spawn: i32, // placespawn
    base_id: i32, // BaseId (resolved class id) — fallen(19)/scarab(91) check
    /// MonStats2.txt fields (linked via MonStats.MonStatsEx -> MonStats2.Id), used by
    /// the spawn-position collision probe: SizeX selects the sampled subtile shape and
    /// spawnCol selects the collision mask (see spawnColMask). Empty spawnCol -> 0.
    size_x: i32, // MonStats2.SizeX
    spawn_col: i32, // MonStats2.spawnCol (0..3; empty -> 0)
};

/// A level's Levels.txt monster fields (resolved to class ids). `mon`/`nmon`/`umon`
/// hold only the non-empty entries (nValidMonCount / nValinNMonCount / nValidUMonCount).
pub const LevelMon = struct {
    id: i32,
    act: i32,
    quest: i32,
    num_mon: i32, // NumMon (distinct types picked, capped 13)
    ranged_spawn: i32, // rangedspawn
    mon_wander: i32, // MonWndr
    spc_walk: i32, // MonSpcWalk
    mon_den: [3]i32, // MonDen / MonDen(N) / MonDen(H)
    mon_umin: [3]i32, // MonUMin / (N) / (H)
    mon_umax: [3]i32, // MonUMax / (N) / (H)
    mon: []i32, // normal candidate pool
    nmon: []i32, // NM/Hell candidate pool
    umon: []i32, // unique-monster pool (normal-difficulty unique packs)
};

pub const Tables = struct {
    gpa: std.mem.Allocator,
    /// MonStats indexed by class id (the MonStats.txt "Expansion" divider row is
    /// removed so class ids >= 410 line up with the engine's pTxtMonStats).
    mon_stats: []MonStat,
    /// Levels monster data keyed by level id (dense, index == id; gaps are undefined).
    levels: []LevelMon,
    max_level_id: i32,

    pub fn load(gpa: std.mem.Allocator) !Tables {
        var mt = try txt.Table.parse(gpa, @embedFile("../excel/MonStats.txt"));
        defer mt.deinit();

        // First pass: build class-id list skipping the "Expansion" sentinel row, and
        // a name -> class-id map for BaseId/spawn/mon[] resolution.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(gpa);
        var name_to_id = std.StringHashMapUnmanaged(i32){};
        defer name_to_id.deinit(gpa);
        {
            var r: usize = 0;
            while (r < mt.rowCount()) : (r += 1) {
                const nm = mt.str(r, "Id");
                if (std.mem.eql(u8, nm, "Expansion")) continue; // divider, not a monster
                const cid: i32 = @intCast(names.items.len);
                try names.append(gpa, nm);
                try name_to_id.put(gpa, nm, cid);
            }
        }
        const resolve = struct {
            fn f(map: *std.StringHashMapUnmanaged(i32), tbl: *const txt.Table, row: usize, col: []const u8) i32 {
                const nm = tbl.str(row, col);
                if (nm.len == 0) return -1;
                return map.get(nm) orelse -1;
            }
        }.f;

        // MonStats2.txt collision fields, keyed by MonStats2.Id (the value a MonStats
        // row's MonStatsEx column points at). Parsed here; the table (and its backing
        // strings, which the map keys borrow) stays alive until the fill loop below runs.
        var m2t = try txt.Table.parse(gpa, @embedFile("../excel/MonStats2.txt"));
        defer m2t.deinit();
        const Stat2 = struct { size_x: i32, spawn_col: i32 };
        var ex_to_stat2 = std.StringHashMapUnmanaged(Stat2){};
        defer ex_to_stat2.deinit(gpa);
        {
            var r: usize = 0;
            while (r < m2t.rowCount()) : (r += 1) {
                const ex_id = m2t.str(r, "Id");
                if (ex_id.len == 0) continue;
                try ex_to_stat2.put(gpa, ex_id, .{
                    .size_x = @intCast(m2t.int(r, "SizeX")),
                    .spawn_col = @intCast(m2t.int(r, "spawnCol")), // empty -> 0
                });
            }
        }

        const mon_stats = try gpa.alloc(MonStat, names.items.len);
        errdefer gpa.free(mon_stats);
        {
            var out_i: usize = 0;
            var r: usize = 0;
            while (r < mt.rowCount()) : (r += 1) {
                const nm = mt.str(r, "Id");
                if (std.mem.eql(u8, nm, "Expansion")) continue;
                const ex = mt.str(r, "MonStatsEx");
                const s2 = ex_to_stat2.get(ex) orelse Stat2{ .size_x = 1, .spawn_col = 0 };
                mon_stats[out_i] = .{
                    .rarity = @intCast(mt.int(r, "Rarity")),
                    .is_spawn = mt.int(r, "isSpawn") != 0,
                    .ranged_type = mt.int(r, "rangedtype") != 0,
                    .min_grp = @intCast(mt.int(r, "MinGrp")),
                    .max_grp = @intCast(mt.int(r, "MaxGrp")),
                    .sparse_populate = @intCast(mt.int(r, "sparsePopulate")),
                    .spawn = resolve(&name_to_id, &mt, r, "spawn"),
                    .place_spawn = @intCast(mt.int(r, "placespawn")),
                    .base_id = resolve(&name_to_id, &mt, r, "BaseId"),
                    .size_x = s2.size_x,
                    .spawn_col = s2.spawn_col,
                };
                out_i += 1;
            }
        }

        // Levels.txt monster fields.
        var lt = try txt.Table.parse(gpa, @embedFile("../excel/Levels.txt"));
        defer lt.deinit();
        var max_id: i32 = 0;
        {
            var r: usize = 0;
            while (r < lt.rowCount()) : (r += 1) {
                const id: i32 = @intCast(lt.int(r, "Id"));
                if (id > max_id) max_id = id;
            }
        }
        const levels = try gpa.alloc(LevelMon, @intCast(max_id + 1));
        errdefer gpa.free(levels);
        @memset(levels, LevelMon{
            .id = 0, .act = 0, .quest = 0, .num_mon = 0, .ranged_spawn = 0,
            .mon_wander = 0, .spc_walk = 0, .mon_den = .{ 0, 0, 0 }, .mon_umin = .{ 0, 0, 0 },
            .mon_umax = .{ 0, 0, 0 }, .mon = &.{}, .nmon = &.{}, .umon = &.{},
        });
        errdefer for (levels) |lv| {
            if (lv.mon.len != 0) gpa.free(lv.mon);
            if (lv.nmon.len != 0) gpa.free(lv.nmon);
            if (lv.umon.len != 0) gpa.free(lv.umon);
        };

        const readPool = struct {
            fn f(alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged(i32), tbl: *const txt.Table, row: usize, prefix: []const u8) ![]i32 {
                var tmp: [25]i32 = undefined;
                var n: usize = 0;
                var k: usize = 1;
                while (k <= 25) : (k += 1) {
                    var buf: [16]u8 = undefined;
                    const col = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, k }) catch break;
                    if (tbl.col(col) == null) break; // only mon1..mon10 exist in 1.14d
                    const nm = tbl.str(row, col);
                    if (nm.len == 0) continue;
                    const cid = map.get(nm) orelse continue;
                    tmp[n] = cid;
                    n += 1;
                }
                if (n == 0) return &.{};
                const out = try alloc.alloc(i32, n);
                @memcpy(out, tmp[0..n]);
                return out;
            }
        }.f;

        {
            var r: usize = 0;
            while (r < lt.rowCount()) : (r += 1) {
                const id: i32 = @intCast(lt.int(r, "Id"));
                if (id < 0 or id > max_id) continue;
                levels[@intCast(id)] = .{
                    .id = id,
                    .act = @intCast(lt.int(r, "Act")),
                    .quest = @intCast(lt.int(r, "Quest")),
                    .num_mon = @intCast(lt.int(r, "NumMon")),
                    .ranged_spawn = @intCast(lt.int(r, "rangedspawn")),
                    .mon_wander = @intCast(lt.int(r, "MonWndr")),
                    .spc_walk = @intCast(lt.int(r, "MonSpcWalk")),
                    .mon_den = .{
                        @intCast(lt.int(r, "MonDen")),
                        @intCast(lt.int(r, "MonDen(N)")),
                        @intCast(lt.int(r, "MonDen(H)")),
                    },
                    .mon_umin = .{
                        @intCast(lt.int(r, "MonUMin")),
                        @intCast(lt.int(r, "MonUMin(N)")),
                        @intCast(lt.int(r, "MonUMin(H)")),
                    },
                    .mon_umax = .{
                        @intCast(lt.int(r, "MonUMax")),
                        @intCast(lt.int(r, "MonUMax(N)")),
                        @intCast(lt.int(r, "MonUMax(H)")),
                    },
                    .mon = try readPool(gpa, &name_to_id, &lt, r, "mon"),
                    .nmon = try readPool(gpa, &name_to_id, &lt, r, "nmon"),
                    .umon = try readPool(gpa, &name_to_id, &lt, r, "umon"),
                };
            }
        }

        return .{ .gpa = gpa, .mon_stats = mon_stats, .levels = levels, .max_level_id = max_id };
    }

    pub fn deinit(self: *Tables) void {
        for (self.levels) |lv| {
            if (lv.mon.len != 0) self.gpa.free(lv.mon);
            if (lv.nmon.len != 0) self.gpa.free(lv.nmon);
            if (lv.umon.len != 0) self.gpa.free(lv.umon);
        }
        self.gpa.free(self.levels);
        self.gpa.free(self.mon_stats);
    }

    pub fn stat(self: *const Tables, class_id: i32) ?*const MonStat {
        if (class_id < 0 or class_id >= self.mon_stats.len) return null;
        return &self.mon_stats[@intCast(class_id)];
    }

    pub fn levelMon(self: *const Tables, level_id: i32) ?*const LevelMon {
        if (level_id < 0 or level_id >= self.levels.len) return null;
        return &self.levels[@intCast(level_id)];
    }
};

// ── Monster region (AllocMonsterRegion 0x5479c0 / D2MonsterRegionStrc) ───────────

pub const MonField = struct { class_id: i32, rarity: i32 };

/// Per-level monster region — the subset of D2MonsterRegionStrc that drives spawns.
/// `mon_data`/`n_total_rarity` are the roster from MONREGION_PopulateMonsterTypes.
/// The `n_rooms_count`/`n_level_rooms_count`/`dw_unique_count` counters are runtime
/// state that MONSTERREGION_CheckSpawnDensity reads; a generation run drives them.
pub const Region = struct {
    level_id: i32 = 0,
    act: i32 = 0,
    quest: i32 = 0,
    n_monster_density: i32 = 0, // MonDen[diff] (clamped to 10000 at spawn time)
    n_boss_min: i32 = 0, // MonUMin[diff]
    n_boss_max: i32 = 0, // MonUMax[diff]
    n_mon_wander: i32 = 0, // MonWndr
    dungeon_level: i32 = 0, // MonLvl[diff]

    mon_data: [MAX_MON_DATA]MonField = undefined,
    n_counter: i32 = 0, // valid entries in mon_data
    n_total_rarity: i32 = 0,

    // runtime counters (reset per generation)
    n_rooms_count: i32 = 0, // rooms processed (CanSpawnInRoom++)
    n_rooms_with_monsters: i32 = 0,
    n_level_rooms_count: i32 = -1, // populated rooms in level, -1 = unset
    dw_unique_count: i32 = 0,
    n_monster_counter: i32 = 0, // wandering monster counter (max 3)
};

/// MONREGION_PopulateMonsterTypes (0x5475e0). Copies the level's mon[] (normal) or
/// nmon[] (NM/Hell) candidate pool, then draws up to NumMon (capped 13) DISTINCT
/// entries via the region seed, removing each from the pool. rangedspawn levels
/// retry the FIRST pick (up to 20 rerolls) until a rangedtype monster lands. Each
/// accepted isSpawn monster is written to region.mon_data with its Rarity.
pub fn populateMonsterTypes(reg: *Region, tbl: *const Tables, lm: *const LevelMon, seed: *s.D2SeedStrc, is_not_normal: bool) void {
    reg.n_counter = 0;
    reg.n_total_rarity = 0;

    var max_mons: i32 = lm.num_mon;
    if (max_mons > 13) max_mons = 13;
    const src_pool: []const i32 = if (is_not_normal) lm.nmon else lm.mon;
    var pool_count: i32 = @intCast(src_pool.len);
    if (pool_count < max_mons) max_mons = pool_count;
    if (max_mons <= 0 or pool_count == 0) return;

    // Mutable working pool (removal by shrink-memmove, faithful to the stack buffer).
    var pool: [25]i32 = undefined;
    @memcpy(pool[0..@intCast(pool_count)], src_pool);

    var picked: i32 = 0;
    while (picked < max_mons) {
        if (pool_count < 1) break;
        const pool_start = pool_count; // pool size for this pick (pre-removal)
        var r: i32 = @intCast(randSel(seed, @intCast(pool_count)));
        var class_id = pool[@intCast(r)];

        // rangedspawn: first pick must be a ranged monster (up to 20 rerolls).
        if (picked == 0 and lm.ranged_spawn != 0) {
            var tries: i32 = 0;
            while (tries < 20) : (tries += 1) {
                if (tbl.stat(class_id)) |ms| if (ms.ranged_type) break;
                r = @intCast(randSel(seed, @intCast(pool_start)));
                class_id = pool[@intCast(r)];
            }
        }

        // Remove pool[r] by shifting the tail down (pMonData stays a distinct set).
        pool_count -= 1;
        if (r < pool_count) {
            var i: i32 = r;
            while (i < pool_count) : (i += 1) pool[@intCast(i)] = pool[@intCast(i + 1)];
        }

        if (tbl.stat(class_id)) |ms| {
            if (ms.is_spawn and reg.n_counter < MAX_MON_DATA) {
                reg.mon_data[@intCast(reg.n_counter)] = .{ .class_id = class_id, .rarity = ms.rarity };
                reg.n_total_rarity += ms.rarity;
                reg.n_counter += 1;
            }
        }
        picked += 1;
    }
}

/// Build a Region for every level id (1..max), sharing ONE region seed stream, as
/// AllocMonsterRegion does. `diff` is 0/1/2 (normal/nm/hell). Champion-pack rolls
/// are skipped (see module header residual). Returns regions indexed by level id.
pub fn buildAllRegions(gpa: std.mem.Allocator, tbl: *const Tables, game_seed: u32, diff: u2) ![]Region {
    const regions = try gpa.alloc(Region, @intCast(tbl.max_level_id + 1));
    errdefer gpa.free(regions);
    for (regions) |*rg| rg.* = .{};

    var seed = s.D2SeedStrc{ .nSeedLow = @bitCast(game_seed), .nSeedHigh = 0x29a };
    const is_not_normal = diff != 0;
    const d: usize = diff;

    var lid: i32 = 1;
    while (lid <= tbl.max_level_id) : (lid += 1) {
        const rg = &regions[@intCast(lid)];
        const lm = tbl.levelMon(lid) orelse continue;
        rg.* = .{
            .level_id = lid,
            .act = lm.act,
            .quest = lm.quest,
            .n_monster_density = lm.mon_den[d],
            .n_boss_min = lm.mon_umin[d],
            .n_boss_max = lm.mon_umax[d],
            .n_mon_wander = lm.mon_wander,
        };
        populateMonsterTypes(rg, tbl, lm, &seed, is_not_normal);
        // RESIDUAL: SEED_RollChampionPack(&seed, &mon_data[k], 3) for k in 0..n_counter
        // would advance `seed` here (GFX variants). Skipped — needs MonStats2.
    }
    return regions;
}

// ── Room spawn (MONSTER_SpawnRoomMonsters 0x54ec90) ──────────────────────────────

pub const MonSpawnFlags = packed struct(u8) {
    unique: bool = false,
    champion: bool = false,
    minion: bool = false,
    wander: bool = false,
    _pad: u4 = 0,
};

/// One spawn event = the (classId, x, y) that SpawnMonster would receive. `count` is
/// the group size (>=1). Position is a placeholder when `placeholder_pos` (see header).
pub const MonSpawn = struct {
    class_id: i32,
    x: i32,
    y: i32,
    count: i32 = 1,
    flags: MonSpawnFlags = .{},
    placeholder_pos: bool = false,
};

/// A room's spawn context: world-subtile bounds of a coord-list rect. In the engine
/// each room has a coord-list of spawnable sub-rects; we approximate with one rect.
pub const RoomCtx = struct {
    x_start: i32,
    y_start: i32,
    x_size: i32, // world subtiles (right-left)
    y_size: i32, // world subtiles (bottom-top)
};

/// low % 100000 on the unsigned low word (MONSTER_SpawnRoomMonsters density gate,
/// via the *0x4f8b588f magic division). Result fits in i32.
inline fn mod100000(seed_low: i32) i32 {
    return @intCast(@as(u32, @bitCast(seed_low)) % 100000);
}
/// low % 100 on the unsigned low word (CheckSpawnDensity / spawn-replacement / sparse).
inline fn mod100(seed_low: i32) i32 {
    return @intCast(@as(u32, @bitCast(seed_low)) % 100);
}
inline fn advance(seed: *s.D2SeedStrc) void {
    seed.* = sEEDNEXT(seed.*);
}

/// CheckIfBaseIsFallenOrScarabAndSet (0x54ec40): BaseId resolves to 19 (fallen) or
/// 91 (scarab) — those spawn singly (their AI self-groups), overriding MinGrp/MaxGrp.
fn isFallenOrScarab(tbl: *const Tables, class_id: i32) bool {
    const ms = tbl.stat(class_id) orelse return false;
    return ms.base_id == 19 or ms.base_id == 91;
}

/// MONREGION_RollRandomMonsterType (0x5bde80). Rolls a class off the ROOM seed.
/// `n_param==0` (or NM/Hell) → weighted-rarity pick from the region roster, with a
/// spawn-replacement roll (bParam gate). `n_param!=0` on NORMAL → uniform pick from
/// the level's umon[] (unique-monster) list. Returns -1 when the source is empty.
pub fn rollRandomMonsterType(reg: *Region, tbl: *const Tables, lm: *const LevelMon, room_seed: *s.D2SeedStrc, b_param: i32, n_param: i32, is_not_normal: bool) i32 {
    if (n_param != 0 and !is_not_normal) {
        // unique-monster path (normal difficulty)
        if (lm.umon.len == 0) return -1;
        const u = randSel(room_seed, @intCast(lm.umon.len));
        return lm.umon[@intCast(u)];
    }
    // weighted-rarity roster path
    if (reg.n_counter == 0) return -1;
    const rand_rarity: i32 = @intCast(randSel(room_seed, @intCast(reg.n_total_rarity)));
    var bucket = rand_rarity + 1;
    var idx: i32 = 0;
    while (idx < reg.n_counter) {
        bucket -= reg.mon_data[@intCast(idx)].rarity;
        if (bucket < 1) break;
        idx += 1;
    }
    if (idx >= reg.n_counter) idx = reg.n_counter - 1;
    var class_id = reg.mon_data[@intCast(idx)].class_id;

    // spawn-replacement: if the monster has a spawn variant and placespawn, roll.
    if (tbl.stat(class_id)) |ms| {
        if (ms.spawn >= 0 and ms.place_spawn != 0) {
            advance(room_seed);
            if (b_param < mod100(room_seed.nSeedLow)) class_id = ms.spawn;
        }
    }
    return class_id;
}

/// MONSTERREGION_CheckSpawnDensity (0x5be020). Returns 0 = spawn a UNIQUE pack, or
/// 1/2 = normal group (the caller remaps 1→2, so both mean "normal"). Rolls the ROOM
/// seed up to 3 times against the unique-density / 6% / 35% thresholds.
pub fn checkSpawnDensity(reg: *Region, room_seed: *s.D2SeedStrc) i32 {
    const uc = reg.dw_unique_count & 0xff;
    if (uc < reg.n_boss_min and reg.n_level_rooms_count != 0) {
        advance(room_seed);
        if (mod100(room_seed.nSeedLow) < @divTrunc(reg.n_rooms_count * 100, reg.n_level_rooms_count)) return 0;
    }
    if (uc < reg.n_boss_max) {
        advance(room_seed);
        if (mod100(room_seed.nSeedLow) < 6) return 0;
    }
    advance(room_seed);
    return if (mod100(room_seed.nSeedLow) > 0x23) 2 else 1;
}

/// MONSTER_SpawnRoomMonsters (0x54ec90) for one room rect. Threads the GAME seed
/// (in place) per density slot and the ROOM seed for the type/unique rolls, emitting
/// a MonSpawn per hit. Returns true if anything spawned. See header for residuals
/// (position, minion count, unique-pack internals, coord-list approximation).
pub fn spawnRoomMonsters(
    reg: *Region,
    tbl: *const Tables,
    lm: *const LevelMon,
    game_seed: *s.D2SeedStrc,
    room_seed: *s.D2SeedStrc,
    room: *const RoomCtx,
    is_not_normal: bool,
    out: *std.ArrayListUnmanaged(MonSpawn),
    gpa: std.mem.Allocator,
    coll: ?*SpawnColl,
) bool {
    var density = reg.n_monster_density;
    if (density > 10000) density = 10000;
    if (density == 0) return false;

    const cx = room.x_start + @divTrunc(room.x_size, 2);
    const cy = room.y_start + @divTrunc(room.y_size, 2);
    // GetRoomCorners (0x54dac0) inset bounds for the leader position roll.
    const rleft = room.x_start + 1;
    const rtop = room.y_start + 1;
    const rwidth = room.x_size - 1;
    const rheight = room.y_size - 1;

    var any_spawned = false;
    var slots: i32 = @divTrunc(room.y_size, 3) * @divTrunc(room.x_size, 3);
    while (slots > 0) : (slots -= 1) {
        advance(game_seed);
        if (mod100000(game_seed.nSeedLow) > density) continue;

        const class_id = rollRandomMonsterType(reg, tbl, lm, room_seed, 0x14, 0, is_not_normal);
        if (class_id < 0 or tbl.stat(class_id) == null) return any_spawned; // pMonStatLine == 0 → stop room

        var dens = checkSpawnDensity(reg, room_seed);
        if (dens == 1) dens = 2;

        if (dens == 0) {
            // UNIQUE PACK — reroll type (umon on normal), emit boss at its rolled position.
            const boss_id = rollRandomMonsterType(reg, tbl, lm, room_seed, 0, 1, is_not_normal);
            if (boss_id >= 0) {
                const bs = tbl.stat(boss_id).?;
                const pos = findRandomPosition(room_seed, rleft, rtop, rwidth, rheight, bs.size_x, spawnColMask(bs.spawn_col), coll);
                out.append(gpa, .{
                    .class_id = boss_id, .x = if (pos) |p| p.x else cx, .y = if (pos) |p| p.y else cy, .count = 1,
                    .flags = .{ .unique = true }, .placeholder_pos = pos == null,
                }) catch {};
                reg.dw_unique_count += 1;
                any_spawned = true;
            }
        } else {
            // NORMAL GROUP with minions.
            var min_grp: i32 = 1;
            var max_grp: i32 = 1;
            if (!isFallenOrScarab(tbl, class_id)) {
                const ms = tbl.stat(class_id).?;
                min_grp = ms.min_grp;
                max_grp = ms.max_grp;
            }
            const ms = tbl.stat(class_id).?;
            if (ms.sparse_populate != 0) {
                advance(game_seed);
                if (ms.sparse_populate < mod100(game_seed.nSeedLow)) continue; // sparse skip
            }
            if (min_grp != 0 and max_grp != 0 and min_grp <= max_grp) {
                // SPAWN_SpawnMonsterWithMinions: the LEADER position rolls off the room
                // seed (findRandomPosition); the minion COUNT rolls off the leader's own
                // unit seed (unmodeled) and minion ring positions don't touch the room
                // seed — so the group is emitted as its leader at the real position with
                // count = min_grp (per-minion spread is a documented residual).
                const pos = findRandomPosition(room_seed, rleft, rtop, rwidth, rheight, ms.size_x, spawnColMask(ms.spawn_col), coll);
                out.append(gpa, .{
                    .class_id = class_id, .x = if (pos) |p| p.x else cx, .y = if (pos) |p| p.y else cy,
                    .count = min_grp, // guaranteed min; random extra up to max_grp = residual
                    .placeholder_pos = pos == null,
                }) catch {};
                any_spawned = true;
            }
        }
    }
    if (any_spawned) reg.n_rooms_with_monsters += 1;
    return any_spawned;
}

// ── Seeded position placement (SPAWN_FindRandomPositionForMonster 0x54dc40 + the
//    CreateMonster ring-walk probe 0x5B2A00 at nSpawnRadius=-1) ────────────────────
//
// See docs/re/monster-spawn-position.md. Each placement rolls a candidate off the ROOM
// seed and probes it; on collision reject it retries (≤20), each attempt advancing the
// room seed by exactly 5 (2 for the x/y roll + 3 for the probe). Replaying these
// advances is what keeps the room-seed stream — and therefore every LATER monster's type
// roll in the room — faithful to the engine.

/// CreateMonster spawnCol switch (0x5B2AA7): MonStats2.spawnCol -> collision mask.
/// 3 (or any unmapped) selects the no-check mask 0.
pub inline fn spawnColMask(spawn_col: i32) u16 {
    return switch (spawn_col) {
        1 => 0x01C0,
        2 => 0x3F11,
        3 => 0x0000,
        else => 0x3C01, // 0 / empty / default
    };
}

/// Optional room collision view for the spawn probe: room-local u16 subtile cells
/// (same bits as the engine's Room1.pColl.pMapStart), plus the world-subtile origin.
/// `blocked` samples the SizeX shape and ANDs the spawnCol mask; `place` writes a
/// placed monster's footprint so later spawns in the room avoid it (the engine mutates
/// pMapStart via PATH_AddUnitCollision mid-pass). When no view is supplied the probe
/// accepts the first candidate (the open-room common case) — collision-driven retries
/// are then a documented gap for that room.
pub const SpawnColl = struct {
    cells: []u16,
    x_start: i32,
    y_start: i32,
    width: i32,
    height: i32,
    /// Bit a placed monster stamps into the map (npc collision, tested by mask 0x3C01).
    pub const UNIT_BIT: u16 = 0x1000;

    fn at(self: *const SpawnColl, x: i32, y: i32) u16 {
        const lx = x - self.x_start;
        const ly = y - self.y_start;
        if (lx < 0 or ly < 0 or lx >= self.width or ly >= self.height) return 0xFFFF; // off-map = blocked
        return self.cells[@intCast(ly * self.width + lx)];
    }

    /// CheckCollision_BlockAll_Width (0x64D9B0): OR the SizeX-shaped sample, AND the mask.
    pub fn blocked(self: *const SpawnColl, x: i32, y: i32, size_x: i32, mask: u16) bool {
        if (mask == 0) return false;
        var acc: u16 = self.at(x, y);
        switch (size_x) {
            2 => { // SMALL cross
                acc |= self.at(x - 1, y) | self.at(x + 1, y) | self.at(x, y - 1) | self.at(x, y + 1);
            },
            3 => { // BIG 3x3 box
                var dy: i32 = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) acc |= self.at(x + dx, y + dy);
                }
            },
            else => {}, // 0/1 single cell (already sampled)
        }
        return (acc & mask) != 0;
    }

    /// Stamp a placed unit's footprint (single cell — the engine footprint over SizeX is
    /// approximated by the center cell; refine with the true PATH_AddUnitCollision shape).
    pub fn place(self: *SpawnColl, x: i32, y: i32) void {
        const lx = x - self.x_start;
        const ly = y - self.y_start;
        if (lx < 0 or ly < 0 or lx >= self.width or ly >= self.height) return;
        self.cells[@intCast(ly * self.width + lx)] |= UNIT_BIT;
    }
};

/// One CreateMonster probe (0x5B2A00) at nSpawnRadius=-1: 3 room-seed advances
/// (parity; the RANDOM(seed,0) between them does not advance; sign-x; sign-y). The
/// offsets are 0 at radius -1 so the candidate is exactly (nx,ny).
inline fn createMonsterProbe(room_seed: *s.D2SeedStrc) void {
    advance(room_seed); // parity
    _ = randSel(room_seed, 0); // RANDOM(seed,0) -> 0, no advance
    advance(room_seed); // sign x (offset 0 -> no effect)
    advance(room_seed); // sign y
}

/// SPAWN_FindRandomPositionForMonster (0x54dc40): roll a candidate off the room seed,
/// probe it, retry on collision (≤20). `left/top/width/height` are the GetRoomCorners
/// inset bounds (rect.left+1, rect.top+1, rect.right-rect.left-1, rect.bottom-rect.top-1).
/// Returns the accepted world-subtile position, or null after 20 failures. Advances the
/// room seed by 5 per attempt regardless of accept/reject.
pub fn findRandomPosition(
    room_seed: *s.D2SeedStrc,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    size_x: i32,
    mask: u16,
    coll: ?*SpawnColl,
) ?struct { x: i32, y: i32 } {
    const w: u32 = @intCast(@max(1, width));
    const h: u32 = @intCast(@max(1, height));
    var tries: u32 = 0;
    while (tries < 20) : (tries += 1) {
        const nx = @as(i32, @intCast(randSel(room_seed, w))) + left;
        const ny = @as(i32, @intCast(randSel(room_seed, h))) + top;
        createMonsterProbe(room_seed);
        // Pure accept checks (no seed advances): PtInRect holds by construction here;
        // MONSTERAI_CanSpawnMonsterAt returns 1 for ordinary monsters.
        if (coll) |cv| {
            if (cv.blocked(nx, ny, size_x, mask)) continue;
            cv.place(nx, ny);
        }
        return .{ .x = nx, .y = ny };
    }
    return null;
}

// ── Wandering monsters (MONSTER_InitWanderingForLevel 0x54eff0) ──────────────────

/// gaActWanderingMonsterParams[act][0]=base offset into gaWanderMonPool, [1]=count.
/// (RE'd table at 0x54ef50; the pool ids live at int32_t_00731b2c and are not dumped
/// here — modeling the region seed CONSUMPTION, class id is a documented residual.)
/// MONSTER_InitWanderingForLevel: advance ROOM seed once; if low%100 < 3 and the
/// region's wandering counter < 3, init one wandering monster (act < 5). Returns true
/// when a wandering-monster init would fire (consumes an extra room-seed roll inside
/// MONSTER_InitWanderingMonsterRegion for the class pick, modeled as one advance).
pub fn tryInitWandering(reg: *Region, lm: *const LevelMon, room_seed: *s.D2SeedStrc, wander_count: [5]u8) bool {
    advance(room_seed);
    if (mod100(room_seed.nSeedLow) >= 3) return false;
    if (reg.n_monster_counter >= 3) return false;
    if (lm.act >= 5) return false;
    if (wander_count[@intCast(lm.act)] == 0) return false;
    // MONSTER_InitWanderingMonsterRegion: one UNIT_GetModuloFromSeed(roomSeed, count).
    _ = randSel(room_seed, wander_count[@intCast(lm.act)]);
    reg.n_monster_counter += 1;
    return true;
}

// ── Preset monster-code resolver (SpawnMonster 0x54e600) ─────────────────────────

/// SpawnMonster (0x54e600) resolves a preset/level "monster code" into a concrete
/// class id. This ports the SEED-INDEPENDENT codes (fixed-id + passthrough). The
/// quest/difficulty-override and GetMonsterClassByDifficulty branches (codes 0x18/
/// 0x1a act-boss groups, 10/0xb swamp critters, unique-pack code 2) need runtime
/// state and are returned as -1 (documented). Used for DS1 preset monster units.
pub fn resolveSpawnMonsterCode(code: i32, mon_stats_size: i32) i32 {
    if (code < 0) return -1;
    if (code < mon_stats_size) return code; // plain monster id (passthrough)
    return switch (code) {
        4 => 0x10a,
        5 => 0x10b,
        8 => 0x11c,
        0x11 => 0x13,
        0x12 => 0x3a,
        0x16 => 0x8d,
        0x17 => 0x116,
        0x1d => 0x1c5,
        0x1f => 0x20a,
        0x20 => 0x1b6,
        else => -1, // needs runtime (quest flags / difficulty / area) — residual
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "monpop tables load: monstats class-ids + levels monster pools" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();
    // skeleton1 = class id 0, fallen1 = 19, scarab1 = 91 (Expansion divider removed).
    try testing.expect(t.mon_stats.len > 500);
    try testing.expect(t.mon_stats[0].is_spawn); // skeleton1 spawns
    // Den of Evil (L8) uses 3 monster types: zombie1, brute1, fallenshaman1.
    const l8 = t.levelMon(8) orelse return error.NoLevel;
    try testing.expectEqual(@as(i32, 3), l8.num_mon);
    try testing.expect(l8.mon.len == 3);
    // Town (L1) has no monster density in normal.
    const l1 = t.levelMon(1) orelse return error.NoLevel;
    try testing.expectEqual(@as(i32, 0), l1.mon_den[0]);
    // fallen/scarab detection resolves via BaseId.
    try testing.expect(isFallenOrScarab(&t, 19));
    try testing.expect(isFallenOrScarab(&t, 91));
    try testing.expect(!isFallenOrScarab(&t, 0));
}

test "region roster: deterministic + classes come from the level pool" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();

    const regions = try buildAllRegions(testing.allocator, &t, 305419896, 0);
    defer testing.allocator.free(regions);
    const regions2 = try buildAllRegions(testing.allocator, &t, 305419896, 0);
    defer testing.allocator.free(regions2);

    // Determinism: same seed -> identical rosters.
    for (regions, regions2) |a, b| {
        try testing.expectEqual(a.n_counter, b.n_counter);
        try testing.expectEqual(a.n_total_rarity, b.n_total_rarity);
        for (0..@intCast(a.n_counter)) |i| {
            try testing.expectEqual(a.mon_data[i].class_id, b.mon_data[i].class_id);
        }
    }

    // The FIRST monster-bearing level's roster is byte-faithful (before any champion
    // rolls advance the seed). Its classes must all come from that level's mon[] pool.
    var lid: i32 = 1;
    while (lid <= t.max_level_id) : (lid += 1) {
        const rg = &regions[@intCast(lid)];
        if (rg.n_counter == 0) continue;
        const lm = t.levelMon(lid).?;
        for (0..@intCast(rg.n_counter)) |i| {
            const cid = rg.mon_data[i].class_id;
            var found = false;
            for (lm.mon) |m| if (m == cid) {
                found = true;
            };
            try testing.expect(found); // roster class is in the level pool
            try testing.expect(t.stat(cid).?.is_spawn);
        }
        break;
    }
}

test "room spawn: deterministic + density scaling + plausible classes" {
    var t = try Tables.load(testing.allocator);
    defer t.deinit();

    // A dungeon level with monsters: Den of Evil (L8, MonDen normal = 600).
    const lm = t.levelMon(8).?;
    try testing.expect(lm.mon_den[0] > 0);

    const runOnce = struct {
        fn f(tbl: *const Tables, level: *const LevelMon, game_lo: u32, room_lo: u32, xs: i32, ys: i32, alloc: std.mem.Allocator) !std.ArrayListUnmanaged(MonSpawn) {
            var regions = try buildAllRegions(alloc, tbl, game_lo, 0);
            defer alloc.free(regions);
            const rg = &regions[@intCast(level.id)];
            rg.n_level_rooms_count = 4; // pretend a small level
            rg.n_rooms_count = 1;
            var gseed = s.D2SeedStrc{ .nSeedLow = @bitCast(game_lo), .nSeedHigh = 0x29a };
            var rseed = s.D2SeedStrc{ .nSeedLow = @bitCast(room_lo), .nSeedHigh = 0x29a };
            var out: std.ArrayListUnmanaged(MonSpawn) = .empty;
            const rctx = RoomCtx{ .x_start = 0, .y_start = 0, .x_size = xs, .y_size = ys };
            _ = spawnRoomMonsters(rg, tbl, level, &gseed, &rseed, &rctx, false, &out, alloc, null);
            return out;
        }
    }.f;

    // Determinism: identical seeds + room -> identical spawn list.
    var a = try runOnce(&t, lm, 111, 222, 60, 60, testing.allocator);
    defer a.deinit(testing.allocator);
    var b = try runOnce(&t, lm, 111, 222, 60, 60, testing.allocator);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |x, y| {
        try testing.expectEqual(x.class_id, y.class_id);
        try testing.expectEqual(x.count, y.count);
        try testing.expectEqual(x.flags.unique, y.flags.unique);
    }

    // Every spawned class must be a valid, spawnable monster from the region roster
    // (or a umon unique / spawn-replacement) — never garbage.
    try testing.expect(a.items.len > 0);
    for (a.items) |m| {
        try testing.expect(m.class_id >= 0 and m.class_id < t.mon_stats.len);
        try testing.expect(m.count >= 1);
    }

    // Density scaling: a bigger room yields >= the spawns of a smaller room (same
    // seeds), since it has more density slots.
    var small = try runOnce(&t, lm, 7, 9, 30, 30, testing.allocator);
    defer small.deinit(testing.allocator);
    var big = try runOnce(&t, lm, 7, 9, 90, 90, testing.allocator);
    defer big.deinit(testing.allocator);
    try testing.expect(big.items.len >= small.items.len);
}

test "findRandomPosition: deterministic, in-bounds, exactly 5 room-seed advances" {
    const left: i32 = 100;
    const top: i32 = 200;
    const width: i32 = 38;
    const height: i32 = 38;

    var seed = s.D2SeedStrc{ .nSeedLow = 0x12345, .nSeedHigh = 0x29a };
    // One accepted attempt = 5 advances: RANDOM(width), RANDOM(height), then the probe's
    // parity + sign-x + sign-y (the RANDOM(seed,0) in the probe does not advance).
    var expect = seed;
    inline for (0..5) |_| expect = sEEDNEXT(expect);

    const p = findRandomPosition(&seed, left, top, width, height, 1, spawnColMask(0), null).?;
    try testing.expect(p.x >= left and p.x < left + width);
    try testing.expect(p.y >= top and p.y < top + height);
    try testing.expectEqual(expect.nSeedLow, seed.nSeedLow);
    try testing.expectEqual(expect.nSeedHigh, seed.nSeedHigh);

    // Determinism: same seed -> same position.
    var seed2 = s.D2SeedStrc{ .nSeedLow = 0x12345, .nSeedHigh = 0x29a };
    const p2 = findRandomPosition(&seed2, left, top, width, height, 1, spawnColMask(0), null).?;
    try testing.expectEqual(p.x, p2.x);
    try testing.expectEqual(p.y, p2.y);
}

test "findRandomPosition: a blocked first candidate forces a retry to a free cell" {
    const left: i32 = 100;
    const top: i32 = 200;
    const width: i32 = 38;
    const height: i32 = 38;

    // First, learn the free-roll candidate (no collision view).
    var s0 = s.D2SeedStrc{ .nSeedLow = 0x777, .nSeedHigh = 0x29a };
    const p1 = findRandomPosition(&s0, left, top, width, height, 1, spawnColMask(0), null).?;

    // Build a collision view spanning the bounds and block exactly p1's cell.
    const gx = left - 1;
    const gy = top - 1;
    const gw: i32 = width + 2;
    const gh: i32 = height + 2;
    const cells = try testing.allocator.alloc(u16, @intCast(gw * gh));
    defer testing.allocator.free(cells);
    @memset(cells, 0);
    var coll = SpawnColl{ .cells = cells, .x_start = gx, .y_start = gy, .width = gw, .height = gh };
    coll.place(p1.x, p1.y); // stamp UNIT_BIT at the first candidate

    // Re-roll from the same seed with collision on: the first candidate is now blocked
    // so it must retry (>= 2 attempts => >= 10 advances) and land elsewhere.
    var s1 = s.D2SeedStrc{ .nSeedLow = 0x777, .nSeedHigh = 0x29a };
    var after5 = s1;
    inline for (0..5) |_| after5 = sEEDNEXT(after5); // exactly one attempt's worth
    const p2 = findRandomPosition(&s1, left, top, width, height, 1, spawnColMask(0), &coll).?;
    // Moved off the blocked cell (findRandomPosition only returns cells that passed the
    // collision check; it then stamps its own footprint, so a post-hoc blocked() check
    // would see that footprint — the accept guarantee is internal).
    try testing.expect(p2.x != p1.x or p2.y != p1.y);
    // More than one attempt was consumed (seed is past the single-attempt state).
    try testing.expect(s1.nSeedLow != after5.nSeedLow or s1.nSeedHigh != after5.nSeedHigh);
}

test "resolveSpawnMonsterCode: fixed codes + passthrough" {
    // Plain ids pass through.
    try testing.expectEqual(@as(i32, 42), resolveSpawnMonsterCode(42, 700));
    // Fixed special codes.
    try testing.expectEqual(@as(i32, 0x10a), resolveSpawnMonsterCode(4, 0));
    try testing.expectEqual(@as(i32, 0x11c), resolveSpawnMonsterCode(8, 0));
    try testing.expectEqual(@as(i32, 0x1b6), resolveSpawnMonsterCode(0x20, 0));
    // Runtime-dependent code -> -1 (documented residual).
    try testing.expectEqual(@as(i32, -1), resolveSpawnMonsterCode(2, 0));
}
