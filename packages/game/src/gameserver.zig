//! GameInstance — the D2 GAMESERVER: one live game (a party of clients joins). This is the whole
//! server-side game, independent of transport: it produces each client's packets into a BUFFER and
//! hands them to a write sink. The networked host wires that sink to a socket; a single-player or
//! clientless driver wires it to an in-memory buffer — same server, no OS handle required. The only
//! transport touchpoint is `Client.conn`, an opaque token the server never interprets.
//!
//! A game is TRAVERSABLE: it hosts MULTIPLE levels, generated on demand and kept in a
//! registry keyed by level id (`levels`). Each LevelState owns that level's world — its
//! unit table (players + monsters), tick-local movement/AI/missile/item state, a
//! pathfinding grid, and its outgoing inter-level warps (from d2-drlg's real Levels.txt
//! Vis/Warp graph). A client carries its CURRENT level id; `tick()` steps every populated
//! level and streams each client the visibility deltas of ITS level over the d2-net S<->C
//! protocol. Inbound C->S commands (walk/run/attack/interact/cast/chat) are dispatched
//! against the client's current level via `handleCommand`.
//!
//! Warp/traversal: a level's outgoing warps are streamed as AssignLevelWarp (0x09) units;
//! a client interacts with one (C->S 0x13) to transition — the target level is generated
//! if needed, the player unit moves to it, the client receives a fresh LoadAct + its new
//! surroundings, and the old level's units drop out of its visibility.
//!
//! Persistence goes through the `CharStore` port (a domain interface the host implements with file
//! I/O): on join a client's persisted state is loaded and applied to its player unit + quest state;
//! it is saved on leave. The gameserver itself never touches a file — the wasm/libc-free mandate.
//!
//! Positions are D2 world SUBTILES (the on-wire unit coordinate space). Monster positions
//! and the player entry are placeholders (room centers) — see d2-drlg monpop residuals.

const std = @import("std");
// This file IS part of d2-game, so it reaches the package's own symbols through the root module
// (lib.zig) under the historical `sim.` prefix — same names the host used when this lived outside.
const sim = @import("lib.zig");
const items = @import("d2-item");
const pf = @import("d2-pathfinding");
const drlg = sim.world;

/// Anya (Betrayal of Harrogath) quest all-resist reward per difficulty: +10 / +20 / +30.
/// Assumed CLAIMED for this lvl-99 char (documented assumption). Indexed by eDifficulty.
const ANYA_RESIST = [_]i32{ 10, 20, 30 };

const events = sim.events;

const sc = sim.net.sc;
const cs = sim.net.cs;

/// Monster-AI tunables (aggro/melee/step/cooldown) — decisions live in d2-sim's ai module.
const AI_CONFIG: sim.ai.AiConfig = .{};
/// Pathfinder per-axis delta gate (PATH_CalculatePath rejects >=100 subtiles).
const PATH_GATE: i32 = 99;

const MonsterAI = sim.ai.MonsterAI;

/// The main inventory grid (Inventory.txt "inventory" panel): 10 cells wide x 4 tall.
const INV_W: u8 = 10;
const INV_H: u8 = 4;

/// One item held in a player's server-side inventory: its base code + stack, the top-left grid cell it
/// occupies, and its footprint (invwidth x invheight). Replaces "picked items cease to exist".
const StoredItem = struct {
    guid: u32,
    code: [4]u8,
    quantity: i32 = 1,
    x: u8,
    y: u8,
    w: u8,
    h: u8,
    /// The item's rolled identity (quality + affix/unique/set selection) and its mod-roll seed, so its
    /// stat mods can be reproduced via items.properties.rollDropStats when it is equipped. Zero/`.invalid`
    /// for a plain code-only item (e.g. gold/quiver or a pickup whose provenance wasn't threaded yet).
    drop: items.Drop = .{},
    item_seed: u32 = 0,
};

/// A dropped ground item (moved to d2-game — see levelstate.zig).
const GroundItem = sim.GroundItem;

/// An inter-level warp instantiated in a level (moved to d2-game — see levelstate.zig).
const Warp = sim.Warp;

/// A seeded world object — shrine / chest / well / door / waypoint (moved to d2-game — levelstate.zig).
const WorldObject = sim.WorldObject;

/// OperateFn families acted on (indices into OBJECTSOPERATEFN @0x732d18, values from
/// Objects.txt). Lootables share the open-with-drops flow; the rest are named handlers.
const OPFN_CASKET: i32 = 1;
const OPFN_SHRINE: i32 = 2;
const OPFN_URN: i32 = 3;
const OPFN_CHEST: i32 = 4;
const OPFN_DOOR: i32 = 8;
const OPFN_WELL: i32 = 22;

/// Simple visibility radius (world subtiles). Placeholder: large enough that a joining
/// client sees the level's monsters even with room-center placeholder positions.
pub const VIEW_RADIUS: i32 = 4096;

/// Straight-line movement step per tick (world subtiles). Placeholder pacing.
const MOVE_STEP: i32 = 6;

/// Default left-hand skill a joining client is armed with (normal Attack, Skills.txt Id 0).
const DEFAULT_SKILL: u16 = 0;

/// Ice Bolt's Skills.txt Id (1.14d): the cold single-target bolt the stock sorc left-clicks
/// with. Routing the left attack to this id makes the bot's 0x06 spam cast Ice Bolt.
const SKILL_ICE_BOLT: u16 = 39;

/// Teleport's Skills.txt Id (1.14d, srvdofunc DOFUNC_TELEPORT=27). The sorc right-clicks this to
/// instant-reposition to a passable target cell, ignoring intervening walls/monsters.
const SKILL_TELEPORT: u16 = 54;

/// Maximum teleport hop distance in world subtiles. Skills.txt gives Teleport `range=none` (no
/// engine collision-range gate — it is a reposition, not a targeted-at-unit skill); the CLIENT
/// caps the cast to what is on screen. D2's on-screen teleport reach is roughly a screen ≈ 40
/// subtiles per axis; we use a straight-line cap of 40 subtiles as the faithful client-side gate.
const TELEPORT_RANGE: i32 = 40;

/// Per-client outbound scratch buffer size (one tick's worth of deltas).
const OUT_BUF = 64 * 1024;

const MoveTarget = sim.MoveTarget;

/// A single hosted level's live world state. Moved to d2-game (levelstate.zig) — the runtime world
/// model is pure game state, not hosting. The host still owns the per-tick logic that mutates it.
pub const LevelState = sim.LevelState;

/// A connected client. Carries its current level id, its player unit GUID, cached position,
/// per-hand active skills, the visibility sets it currently knows (units/items/missiles/
/// warps, each a separate diff space), its persisted identity + quest state, and an owned
/// outbound scratch buffer. `pending_loadact` flags a just-warped client so the next diff
/// leads with a fresh LoadAct before re-populating its new surroundings.
pub const Client = struct {
    /// Transport-neutral connection token. The gameserver never interprets it — it just hands it back
    /// to the write sink. The networked host stores the socket fd here; a single-player/clientless
    /// driver stores a buffer index (or -1). This is the ONLY thing standing between the server and a
    /// socket: swap the sink and the same server drives a buffer with no OS handle in sight.
    conn: i32,
    player_guid: u32,
    level_id: u16,
    x: i32 = 0,
    y: i32 = 0,
    last_hp: i32 = -1,
    pending_loadact: bool = false,
    left_skill: u16 = DEFAULT_SKILL,
    right_skill: u16 = DEFAULT_SKILL,
    /// The caster's cold-tree skill build (d2-sim) — the effective (hard-point) levels the sim
    /// elemental damage path reads to build an Ice Bolt Cast (skill + synergies + cold mastery).
    /// Populated at spawn from the standalone's stock Hell-Mephisto cold sorc.
    build: sim.character.SorcColdBuild = .{},
    /// Active timed buffs on this player (Battle Orders / Frozen Armor / Enchant / ...): granted on
    /// cast, ticked down each frame, removed on expiry. Modifies the player unit's StatList.
    buffs: sim.buff.BuffList = .{},
    /// The paladin's currently-active aura skill id (0 = none). Only one aura is active at a time;
    /// casting another replaces it. tickAuras re-applies its stats to units in range each frame.
    active_aura: u16 = 0,
    /// This player's single active golem (guid, 0 = none). A Necromancer has ONE golem regardless of
    /// type — summoning any golem replaces the previous one (enforced in the summon dispatch).
    golem_guid: u32 = 0,
    /// Active shapeshift form (Wearwolf / Wearbear / Delirium), 0 = human. A toggle: casting the same
    /// form skill reverts to human; casting a different one swaps. The form grants its aurastat bonuses
    /// as a near-permanent buff (removed on revert).
    form_skill: u16 = 0,
    /// Assassin martial-arts charge-up accumulator: the last charge-up skill struck with and how many
    /// charges stand (same skill stacks up to 3, a different one resets). Each charge-up hit already
    /// discharges its element; the count is tracked for the finisher-release refinement.
    charge_skill: u16 = 0,
    charge_count: u8 = 0,
    /// Guids of this player's active Revived monsters, oldest-first — capped at the skill's petmax
    /// (=skill level); reviving past the cap retires the oldest. Distinct from skeleton/golem pets,
    /// which the summon column identifies, so revives need their own tally.
    revives: std.ArrayListUnmanaged(u32) = .empty,
    known: std.AutoHashMapUnmanaged(u32, void) = .empty,
    known_items: std.AutoHashMapUnmanaged(u32, void) = .empty,
    known_missiles: std.AutoHashMapUnmanaged(u32, void) = .empty,
    known_warps: std.AutoHashMapUnmanaged(u32, void) = .empty,
    known_objects: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Server-side main inventory (the INV_W x INV_H grid). A picked-up item lands here and occupies its
    /// footprint until moved/dropped, instead of vanishing.
    inventory: std.ArrayListUnmanaged(StoredItem) = .empty,
    /// Worn gear keyed by BodyLocs slot id (head 1, torso 3, r-arm/weapon 4, …). An equipped item's
    /// rolled mods are added to the player unit's stats on equip and removed on unequip.
    equipped: std.AutoHashMapUnmanaged(u8, StoredItem) = .empty,
    outbuf: []u8,
    /// Event packets queued by command handlers between frames (pickup confirmations
    /// etc.), flushed ahead of the visibility diff each tick. Mirrors the engine's
    /// per-client packet buffer the NET_D2GS_SERVER_Send_* helpers append to, drained
    /// by FlushAllClientPackets @0x52e440 once per frame.
    pending: std.ArrayListUnmanaged(u8) = .empty,

    // Persisted identity + quest state (from the .d2s save on join).
    account_buf: [32]u8 = undefined,
    account_len: u8 = 0,
    charname_buf: [16]u8 = undefined,
    charname_len: u8 = 0,
    quests: sim.QuestState = .{},

    pub fn account(self: *const Client) []const u8 {
        return self.account_buf[0..self.account_len];
    }
    pub fn charname(self: *const Client) []const u8 {
        return self.charname_buf[0..self.charname_len];
    }

    pub fn deinit(self: *Client, gpa: std.mem.Allocator) void {
        self.revives.deinit(gpa);
        self.known.deinit(gpa);
        self.known_items.deinit(gpa);
        self.known_missiles.deinit(gpa);
        self.known_warps.deinit(gpa);
        self.known_objects.deinit(gpa);
        self.inventory.deinit(gpa);
        self.equipped.deinit(gpa);
        self.pending.deinit(gpa);
        gpa.free(self.outbuf);
        gpa.destroy(self);
    }

    /// True if grid cell (cx,cy) is covered by an item already in this inventory.
    fn invCellOccupied(self: *const Client, cx: u8, cy: u8) bool {
        for (self.inventory.items) |it| {
            if (cx >= it.x and cx < it.x + it.w and cy >= it.y and cy < it.y + it.h) return true;
        }
        return false;
    }

    /// Find the top-left cell of the first free w x h rectangle in the grid (row-major), or null when the
    /// inventory has no room. Mirrors the engine's left-to-right, top-to-bottom auto-placement scan.
    fn invFindSlot(self: *const Client, w: u8, h: u8) ?[2]u8 {
        if (w == 0 or h == 0 or w > INV_W or h > INV_H) return null;
        var y: u8 = 0;
        while (y + h <= INV_H) : (y += 1) {
            var x: u8 = 0;
            cell: while (x + w <= INV_W) : (x += 1) {
                var dy: u8 = 0;
                while (dy < h) : (dy += 1) {
                    var dx: u8 = 0;
                    while (dx < w) : (dx += 1) {
                        if (self.invCellOccupied(x + dx, y + dy)) continue :cell;
                    }
                }
                return .{ x, y };
            }
        }
        return null;
    }
};

/// Minimal spinlock guarding shared GameInstance state (std.Thread.Mutex was removed in
/// this Zig's 0.16 Io migration). Holds are short and contention is low.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

pub const GameInstance = struct {
    gpa: std.mem.Allocator,
    game_id: u32,
    seed: u32,
    act: u8,
    difficulty: drlg.Difficulty,
    /// The game's starting level id (where joining clients spawn).
    level_id: u16,

    /// Every hosted level, keyed by level id; generated + populated on demand.
    levels: std.AutoHashMapUnmanaged(u16, *LevelState) = .empty,
    /// One A* scratch for the whole game — generation-stamped, so it is reused by every path query
    /// on every level without clearing. `path_buf` is the waypoint list those queries write into.
    pather: pf.Pather,
    path_buf: std.ArrayListUnmanaged(pf.Point) = .empty,
    clients: std.ArrayListUnmanaged(*Client) = .empty,

    /// The map-generation world (one reused d2-drlg Ctx + per-act cache). Lazily built
    /// on first level generation. Routes outdoor (wilderness) levels through the act
    /// placement path and interior levels through single-level generation.
    world: ?drlg.World = null,

    /// Shared data tables (lazily loaded, no external assets).
    skills: ?sim.Skills = null,
    missile_data: ?sim.Missiles = null,
    /// MonLvl-scaled combat stats (AC/AR/attack damage) per (class, monlevel, diff) —
    /// MONSTER_CalculateLevelScaledStats 0x6538a0 via sim.montable. Loaded once, mirrors skills.
    mon_combat: ?sim.MonCombatTables = null,
    /// Cached class id of "baalclone" (Baal's summoned copy); -2 = not yet resolved, -1 = not found.
    baal_clone_class: i32 = -2,
    /// Cache of each monster CLASS's resolved castable skills (MonStats Skill1..8 -> Skills ids +
    /// levels), built lazily on first cast attempt. Keyed by class id (the MonStats row index).
    monster_casters: std.AutoHashMapUnmanaged(u16, sim.skill.MonsterCaster) = .empty,
    /// Owns the ItemStatCost table for driving timed buffs (loaded with the skill tables).
    buff_ctx: ?sim.buff.BuffContext = null,
    item_tables: ?items.Tables = null,
    /// Shrines.txt view — the shrine function pool + effects. Loaded lazily at level-gen time
    /// so shrine objects can be assigned their rolled effect.
    shrine_tables: ?sim.shrines.Table = null,
    tc_set: ?items.TCSet = null,
    drop_seed: items.rng.Seed = .{},
    game_seed: items.rng.Seed = .{}, // per-item roll stream for rollDrop (distinct from the TC-walk drop_seed)
    combat_seed: sim.Seed = .{},

    next_guid: u32 = 1,
    tick_count: u64 = 0,
    /// Per-act environment cycle counter (DRLGENV_UpdateCycleIndex @0x61c040 nTicks). Advanced each
    /// tick by updateActEnvironments; drives the periodic equipped-item recalc.
    env_ticks: u64 = 0,

    /// Character-save root (mirrors the realm data dir); empty disables persistence.
    char_store: ?sim.CharStore = null,

    mutex: SpinLock = .{},

    pub fn init(gpa: std.mem.Allocator, game_id: u32, seed: u32, act: u8, difficulty: drlg.Difficulty) GameInstance {
        return .{
            .gpa = gpa,
            .game_id = game_id,
            .seed = seed,
            .act = act,
            .difficulty = difficulty,
            .level_id = actStartLevel(act),
            .combat_seed = sim.Seed.fromValue(seed),
            .drop_seed = items.rng.Seed.fromValue(seed),
            .pather = pf.Pather.init(gpa),
        };
    }

    /// Override the starting level id (e.g. host a monster-bearing level instead of a town).
    pub fn setLevel(self: *GameInstance, level_id: u16) void {
        self.level_id = level_id;
    }

    pub fn deinit(self: *GameInstance) void {
        for (self.clients.items) |c| c.deinit(self.gpa);
        self.clients.deinit(self.gpa);
        var it = self.levels.valueIterator();
        while (it.next()) |lp| {
            lp.*.deinit(self.gpa);
            self.gpa.destroy(lp.*);
        }
        self.levels.deinit(self.gpa);
        self.pather.deinit();
        self.path_buf.deinit(self.gpa);
        if (self.world) |*w| w.deinit();
        if (self.skills) |*s| s.deinit();
        if (self.missile_data) |*m| m.deinit();
        if (self.mon_combat) |*t| t.deinit();
        self.monster_casters.deinit(self.gpa);
        if (self.buff_ctx) |*b| b.deinit();
        if (self.tc_set) |*s| s.deinit();
        if (self.item_tables) |*t| t.deinit();
        if (self.shrine_tables) |*t| t.deinit();
    }

    fn allocGuid(self: *GameInstance) u32 {
        const g = self.next_guid;
        self.next_guid += 1;
        return g;
    }

    // --- level registry -----------------------------------------------------

    /// Get (or generate + populate) the level with `level_id`. Generation runs the REAL
    /// d2-drlg map generation, instantiates a sim.Unit per monster spawn, and instantiates
    /// this level's outgoing warps from the real Vis/Warp adjacency.
    fn ensureWorld(self: *GameInstance) !*drlg.World {
        if (self.world == null) self.world = try drlg.World.init(self.gpa, self.seed, self.difficulty);
        return &self.world.?;
    }

    pub fn ensureLevel(self: *GameInstance, level_id: u16) !*LevelState {
        if (self.levels.get(level_id)) |ls| return ls;

        const world = try self.ensureWorld();
        try self.ensureMonCombat();
        const pop = try world.populated(level_id);
        defer self.gpa.free(pop.spawns);
        defer self.gpa.free(pop.warps);
        defer self.gpa.free(pop.objects);

        const ls = try self.gpa.create(LevelState);
        errdefer self.gpa.destroy(ls);
        ls.* = .{
            .level_id = level_id,
            .summary = pop.summary,
            .entry_x = pop.entry_x,
            .entry_y = pop.entry_y,
            .level = pop.level, // borrowed from self.world; the LevelState does not own it
        };
        errdefer ls.deinit(self.gpa);

        for (pop.spawns) |spawn| {
            const guid = self.allocGuid();
            const u = self.buildMonsterUnit(guid, spawn.class_id, spawn.x, spawn.y, level_id, spawn.unique);
            try ls.units.put(self.gpa, guid, u);
            // A passive-AI unit is a non-combat NPC (town folk / neutral): it's placed at its real DS1
            // preset position, is interactable (opens the NPC menu), and gets NO AI-think or stat-regen
            // timers. Everything else is a monster: arm MONSTER_StartAiAndRegenTimers @0x5738d0 (delay 0
            // -> immediate, self-rescheduling).
            if (self.aiScript(spawn.class_id) == .passive) {
                try ls.npcs.put(self.gpa, guid, {});
            } else {
                try ls.ai.put(self.gpa, guid, .{});
                ls.timers.trigger(self.gpa, guid, @intFromEnum(sim.UnitType.monster), .aithink) catch {};
                ls.timers.trigger(self.gpa, guid, @intFromEnum(sim.UnitType.monster), .statregen) catch {};
            }
        }

        // Instantiate outgoing warps near the entry point (real warp coords are a residual;
        // the destination-level adjacency is faithful — from the Vis/Warp graph).
        for (pop.warps, 0..) |wt, i| {
            const off: i32 = @intCast((i + 1) * 24);
            try ls.warps.append(self.gpa, .{
                .guid = self.allocGuid(),
                .class_id = wt.warp_type,
                .x = ls.entry_x + off,
                .y = ls.entry_y,
                .dest_level = wt.dest_level,
            });
        }

        // Instantiate this level's seeded objects (shrines/chests/wells/doors/waypoints).
        // Faithful class id + world-subtile position from the DRLG object population; their
        // footprints are already stamped blocked in the path grid. State machines (object
        // timers) are not armed yet — see the EVENT object-timer TODO.
        self.ensureShrineTables() catch {};
        for (pop.objects) |o| {
            const guid = self.allocGuid();
            var wo = WorldObject{
                .guid = guid,
                .class_id = o.class_id,
                .x = o.x,
                .y = o.y,
                .operate_fn = o.operate_fn,
            };
            // Roll a shrine object's function once at spawn (Objects_InitFn01 @0x54f9d0):
            // flat-uniform over Shrines.txt gated by LevelMin vs this level. We use the "any"
            // category (Objects.txt Parm=0) until the object Parm is surfaced from the DRLG,
            // and a per-object seed off the game seed for determinism. LevelMin compares the
            // engine's eLevelId, so we pass this level's id.
            if (o.operate_fn == OPFN_SHRINE) {
                if (self.shrine_tables) |*st| {
                    var sseed = sim.Seed.fromValue(self.seed ^ guid);
                    if (st.pick(&sseed, .any, @intCast(ls.level_id))) |ri| {
                        wo.shrine_effect = st.rows[ri].effect;
                        wo.shrine_reset_min = @intCast(st.rows[ri].reset_minutes);
                    }
                }
            }
            try ls.objects.append(self.gpa, wo);
        }

        try self.levels.put(self.gpa, level_id, ls);
        return ls;
    }

    /// Ensure the starting level exists (kept for the create-game bootstrap + tests).
    pub fn generateLevel(self: *GameInstance) !*LevelState {
        return self.ensureLevel(self.level_id);
    }

    /// Total live monsters across all hosted levels (status).
    pub fn monsterCount(self: *const GameInstance) u32 {
        var n: u32 = 0;
        var it = self.levels.valueIterator();
        while (it.next()) |lp| n += lp.*.monsterCount();
        return n;
    }

    // --- clients ------------------------------------------------------------

    /// Register a new client: create its player unit at the starting level's entry point
    /// (loading + applying its persisted save when an account/charname are given), record
    /// the client, and return it. Caller then sends the join packets (buildJoinPackets).
    pub fn addClient(self: *GameInstance, conn: i32, account: []const u8, charname: []const u8) !*Client {
        const start = try self.ensureLevel(self.level_id);

        const guid = self.allocGuid();
        var build = sim.character.SorcColdBuild{};
        var u = sim.Unit.init(.player);
        u.unit_id = guid;
        u.class_id = 1; // sorceress
        u.set(.level, build.level);
        u.set(.strength, build.strength);
        u.set(.energy, build.energy);
        u.set(.dexterity, build.dexterity);
        u.set(.vitality, build.vitality);
        // Base defense: a naked char has armorclass 0; GetDefense (0x6223f0) adds dexterity/4, so the
        // sorc's real base defense is dex/4 (no armor modeled). Item defense would fold in via the
        // char save; resolveMonsterAttack reads this through getDefense for the monster to-hit roll.
        u.set(.armorclass, 0);
        // Faithful life/mana from the CharStats.txt derivation (derive.zig): the sorc's real
        // maxLife/maxMana at this level + spent vitality/energy. A vit-heavy clvl-85 cold sorc.
        const d = build.derived();
        u.set(.maxhp, d.max_life);
        u.set(.maxmana, d.max_mana);
        u.set(.mana, d.max_mana); // start at full mana (no mana regen model yet — see castSkill/tryTeleport)
        u.setLife(d.max_life);
        u.weapon = .{ .min_damage = 1, .max_damage = 3 };
        // Real character: override the synthetic derived stats with the actual .d2s attributes
        // (level + str/dex/vit/energy + the geared max life/mana D2 persists post-gear). Resistances/
        // defense/+skills still need the save-format gear decoder; life is faithful from here.
        const rc = if (self.char_store) |store| store.realChar(self.gpa) else sim.RealChar{};
        if (rc.has_attrs) {
            u.set(.level, @intCast(rc.level));
            u.set(.strength, @intCast(rc.strength));
            u.set(.dexterity, @intCast(rc.dexterity));
            u.set(.vitality, @intCast(rc.vitality));
            u.set(.energy, @intCast(rc.energy));
            if (rc.maxhp > 0) {
                u.set(.maxhp, @intCast(rc.maxhp));
                u.setLife(@intCast(rc.maxhp));
            }
            if (rc.maxmana > 0) {
                u.set(.maxmana, @intCast(rc.maxmana));
                u.set(.mana, @intCast(rc.maxmana));
            }
        }

        // Real character: fold the DECODED gear+charm stats onto the player unit. The .d2s stores
        // resists/defense/+skills per-item (not in the attribute block), so this is the payoff of
        // the save-item decoder — faithful NET resist after the per-difficulty penalty (from
        // sim.resistPenalty / DifficultyLevels.txt: Normal 0 / NM -40 / Hell -100) and the Anya reward
        // (+10/+20/+30). The sim's combat elemental path only reads the unit's stored resist, so
        // the HOST computes NET here (the sim does NOT apply the difficulty penalty).
        if (rc.has_gear) {
            const diff: usize = @intFromEnum(self.difficulty);
            const pen = sim.resistPenalty(@enumFromInt(diff)); // DifficultyLevels.txt ResistPenalty
            const anya = ANYA_RESIST[diff];
            const netRes = struct {
                fn f(gear: i32, an: i32, p: i32) i32 {
                    return std.math.clamp(gear + an + p, -100, 75); // D2 caps resist at 75
                }
            }.f;
            u.set(.fireresist, netRes(rc.fire, anya, pen));
            u.set(.coldresist, netRes(rc.cold, anya, pen));
            u.set(.lightresist, netRes(rc.light, anya, pen));
            u.set(.poisonresist, netRes(rc.poison, anya, pen));
            // Defense = summed item base armor (stat 31, equipped). Enhanced-def% not folded yet.
            u.set(.armorclass, rc.defense);
            // +skills: bump the cold tree by allSkills(127)+addClassSkills(83) so Ice Bolt +
            // synergies + Cold Mastery reflect the geared char. Mutating `build` before it is
            // stored on the Client means c.build.iceBoltCast() casts at the geared level.
            const bump = rc.allskills + rc.classskills;
            build.ice_bolt += bump;
            build.frost_nova += bump;
            build.ice_blast += bump;
            build.glacial_spike += bump;
            build.blizzard += bump;
            build.frozen_orb += bump;
            build.cold_mastery += bump;
        }

        var quests = sim.QuestState{};
        if (account.len > 0) {
            if (self.char_store) |store| {
                if (store.load(self.gpa, account, charname)) |csv| {
                    sim.character.applyToUnit(&u, csv);
                    quests = csv.quests;
                }
            }
        }
        u.x = start.entry_x;
        u.y = start.entry_y;
        try start.units.put(self.gpa, guid, u);
        errdefer _ = start.units.remove(guid);

        const c = try self.gpa.create(Client);
        errdefer self.gpa.destroy(c);
        c.* = .{
            .conn = conn,
            .player_guid = guid,
            .level_id = self.level_id,
            .x = start.entry_x,
            .y = start.entry_y,
            .quests = quests,
            .build = build,
            // Arm the left-click with Ice Bolt so the bot's 0x06 attack casts the cold bolt, and
            // the right-click with Teleport so the bot's 0x0C right-skill-on-location casts the
            // reposition. (SelectSkill 0x3C overrides either once the client sends one.)
            .left_skill = SKILL_ICE_BOLT,
            .right_skill = SKILL_TELEPORT,
            .outbuf = try self.gpa.alloc(u8, OUT_BUF),
        };
        errdefer self.gpa.free(c.outbuf);
        const an = @min(account.len, c.account_buf.len);
        @memcpy(c.account_buf[0..an], account[0..an]);
        c.account_len = @intCast(an);
        const cn = @min(charname.len, c.charname_buf.len);
        @memcpy(c.charname_buf[0..cn], charname[0..cn]);
        c.charname_len = @intCast(cn);

        try self.clients.append(self.gpa, c);
        return c;
    }

    pub fn removeClient(self: *GameInstance, c: *Client) void {
        self.saveClient(c);
        for (self.clients.items, 0..) |it, i| {
            if (it == c) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
        if (self.levels.get(c.level_id)) |ls| {
            if (ls.units.getPtr(c.player_guid)) |u| u.setLife(0);
            _ = ls.targets.remove(c.player_guid);
        }
        c.deinit(self.gpa);
    }

    /// Persist a client's character (level/stats + quest bitfield) via the realm save path.
    pub fn saveClient(self: *GameInstance, c: *Client) void {
        if (c.account_len == 0) return;
        const store = self.char_store orelse return;
        const ls = self.levels.get(c.level_id) orelse return;
        const u = ls.units.getPtr(c.player_guid) orelse return;
        store.saveChar(self.gpa, c.account(), c.charname(), sim.character.fromUnit(u, c.quests));
    }

    // --- load handshake / join burst ----------------------------------------

    pub fn encodeGameFlags(self: *const GameInstance, out: []u8) []const u8 {
        var pw = sc.PacketWriter.init(out);
        pw.add(sc.GameFlags{
            .difficulty = @intFromEnum(self.difficulty),
            .expansion = true,
        });
        return pw.bytes();
    }

    /// Build the world-entry packets a client receives after ENTERGAME (0x6B): LoadAct
    /// (carries the map seed + its current level) and its own CreatePlayer.
    pub fn buildJoinPackets(self: *GameInstance, c: *Client, out: []u8) []const u8 {
        var pw = sc.PacketWriter.init(out);
        pw.add(sc.LoadAct{
            .act = self.act,
            .map_seed = self.seed,
            .area = c.level_id,
            .automap = 0xFFFFFFFF,
        });
        // Use the loaded character's real class + name (from its .d2s), not a placeholder.
        const class_id: u8 = if (self.levels.get(c.level_id)) |ls|
            if (ls.units.getPtr(c.player_guid)) |pu| @intCast(@min(@max(0, pu.class_id), 6)) else 1
        else
            1;
        var cp = sc.CreatePlayer{
            .guid = c.player_guid,
            .class_id = class_id,
            .x = clampU16(c.x),
            .y = clampU16(c.y),
        };
        cp.setName(if (c.charname_len > 0) c.charname() else "Player");
        pw.add(cp);
        c.known.put(self.gpa, c.player_guid, {}) catch {};
        return pw.bytes();
    }

    /// Build the 0x03 LoadAct packet for this game's starting level (used by tests).
    pub fn encodeLoadAct(self: *const GameInstance, out: []u8) []u8 {
        const pkt = sc.LoadAct{
            .act = self.act,
            .map_seed = self.seed,
            .area = self.level_id,
            .automap = 0xFFFFFFFF,
        };
        return pkt.encode(out);
    }

    // --- server frame (D2Game::Game::Server::ServerGameLoop @0x52d870) -------
    //
    // One `tick()` is one iteration of the real 25-fps per-game server loop. Step
    // order and the periodic cadence below mirror the decompiled ServerGameLoop
    // exactly; every step cites its 1.14d function. Subsystems we already model are
    // wired to their d2-sim kernel; the rest are honest stubs (the engine runs them,
    // we don't yet). A game hosts several levels at once — the engine's unit lists are
    // game-wide across all active acts/rooms, so the unit-update and cleanup steps loop
    // our per-level worlds while the frame ordering + cadence stay at the game level.
    //
    // Cross-referenced against Ghidra ServerGameLoop @0x52d870 (all 10 callee addresses verified):
    // step order + cadence (0x14/0xc/0xb, FreeUnusedItems self-gates 1500f) match 1:1. The engine's
    // debug dwUpdateTick modes 1-4 (crash/alloc test hooks: DAT_00000000=0, AllocClientMemory, …) are
    // intentionally NOT modelled — they exist only to fault the process under test harnesses.

    /// ServerGameLoop @0x52d870. `writeFn` (conn token, bytes)->written is the client-update sink —
    /// a socket write for the networked host, a buffer append for a single-player/clientless driver.
    pub fn tick(self: *GameInstance, writeFn: *const fn (i32, []const u8) isize) void {
        self.tick_count += 1; // pGame->dwGameFrame++

        self.updateActEnvironments(); //    UpdateActEnvironments    @0x52d7b0
        self.updatePerformanceMetrics(); // UpdatePerformanceMetrics @0x52d720

        // Each engine step is ONE game-wide pass over pGame's unit lists (which span all hosted
        // acts/levels). We loop our per-level worlds once PER step — never interleaved — so the
        // whole-game ordering matches the decompile: all InitNewRooms, THEN all EVENT_DispatchAllTimers.
        var lit = self.levels.valueIterator();
        while (lit.next()) |lp| self.initNewRooms(lp.*); //        InitNewRooms            @0x52d160
        lit = self.levels.valueIterator();
        while (lit.next()) |lp| self.dispatchAllTimers(lp.*); //   EVENT_DispatchAllTimers @0x5414d0 (AITHINK + timers)
        lit = self.levels.valueIterator();
        while (lit.next()) |lp| self.driveBaalWaves(lp.*); //      Baal Throne minion-wave sequencer (AI_Function1_BaalThrone)

        // The engine tick-downs poison/curse/aura/buff via per-unit STATE-expiry events fired INSIDE
        // EVENT_DispatchAllTimers above; we drive them here as an explicit continuation of that phase —
        // still BEFORE UpdateClients, so the resulting hp/state changes broadcast the same frame.
        self.tickGroundEffects(); // pulse Fire Wall / Blaze / Blizzard damage to foes standing in them
        self.tickAuras(); // refresh each paladin's active ally aura on itself (before the buff tick-down)
        self.tickBuffs(); // count down each player's timed buffs; expire (remove stats) at 0
        self.tickPoison(); // deal each active poison DoT's per-frame damage; drop it when it runs out
        self.tickCurses(); // count down each enemy's curse; lift the debuff on expiry

        self.updateClients(writeFn); //     UpdateClients            @0x52d440

        lit = self.levels.valueIterator();
        while (lit.next()) |lp| self.processUnitUpdateFlags(lp.*); // ProcessUnitUpdateFlags @0x53b000
        lit = self.levels.valueIterator();
        while (lit.next()) |lp| self.freePendingDrlgDeletes(lp.*); // FreePendingDrlgDeletes @0x53a820

        if (self.tick_count % 20 == 0) self.processQuestTimers(); // QUEST_ProcessQuestTimers  (0x14)
        if (self.tick_count % 12 == 0) self.cleanupIdleRooms(); //  CleanupIdleRooms  @0x52d240 (0xc)
        if (self.tick_count % 11 == 0) self.freeDungeons(); //      FreeDungeons ×5   @0x61aa20 (0xb)
        self.freeUnusedItems(); //          FreeUnusedItems (self-gates ~1500f) @0x52d310
    }

    // --- ServerGameLoop steps we do not model yet (stubs) --------------------

    /// UpdateActEnvironments @0x52d7b0 — per-act weather / day-night / global light
    /// advance. TODO: no environmental state modelled yet.
    fn updateActEnvironments(self: *GameInstance) void {
        // DRLGENV_UpdateCycleIndex @0x61c040 advances the per-act environment cycle each tick; on a
        // cycle transition the engine recalculates equipped-item states (ITEMS_RecalcEquippedItemStates
        // @0x55dbc0 -> S->C 0x48) and sends the cosmetic 0x53 Darkness. For the standalone the recalc is
        // a DETERMINISTIC net-zero re-application (no time-conditional stats and no requirement-disable
        // model yet), and the light/darkness is client-cosmetic — so we advance the cycle and re-apply
        // equipped mods on the cycle cadence to keep the structure faithful and safe. The exact day/night
        // period + the 0x48/0x53 packets are documented follow-ups.
        self.env_ticks += 1;
        if (self.env_ticks % ENV_CYCLE_FRAMES != 0) return;
        for (self.clients.items) |c| self.recalcEquippedItems(c);
    }

    /// Frames per environment-cycle transition — ~1 minute at the 25fps tick. A documented cadence for
    /// the periodic equipped-item recalc (the engine's exact day/night period is a follow-up).
    const ENV_CYCLE_FRAMES: u64 = 1500;

    /// ITEMS_RecalcEquippedItemStates @0x55dbc0 (standalone form): re-apply each equipped item's mods to
    /// the player. Deterministic (same item seed) so remove+re-add nets zero today; the structure is in
    /// place for when time-conditional stats / requirement-disabling arrive.
    fn recalcEquippedItems(self: *GameInstance, c: *Client) void {
        const ls = self.levels.get(c.level_id) orelse return;
        const player = ls.units.getPtr(c.player_guid) orelse return;
        var it = c.equipped.valueIterator();
        while (it.next()) |si| {
            self.applyItemMods(player, si, false); // clear
            self.applyItemMods(player, si, true); // re-apply
        }
    }

    /// UpdatePerformanceMetrics @0x52d720 — engine frame-time accounting. The host does
    /// its own metrics; nothing to mirror.
    fn updatePerformanceMetrics(self: *GameInstance) void {
        _ = self;
    }

    /// InitNewRooms @0x52d160 — activate rooms a player newly entered this frame (build
    /// their collision + spawn their contents on demand). TODO: we pre-generate and
    /// pre-populate whole levels at ensureLevel time, so there are no lazy rooms yet.
    fn initNewRooms(self: *GameInstance, ls: *LevelState) void {
        _ = .{ self, ls };
    }

    /// ProcessUnitUpdateFlags @0x53b000 — flush each unit's dirty/update flags after the
    /// frame's timer callbacks. Two jobs the engine routes through the unit update-list
    /// here: (1) broadcast monster health-bar changes (0xAB, queued by UnitQueuePacket0xAB
    /// then flushed by PacketUpdateForClient); (2) death resolution — a monster killed this
    /// frame rolls its drops and is removed (the engine frees the corpse later via the
    /// deferred-delete + FreeUnusedItems path). Runs AFTER UpdateClients, exactly as the
    /// engine — so the client sees the death (RemoveObject) this frame, freed next.
    fn processUnitUpdateFlags(self: *GameInstance, ls: *LevelState) void {
        self.broadcastHpChanges(ls);
        self.sweepDeaths(ls);
    }

    /// Emit 0xAB UnitHpPercent for any live monster whose hp% (128-scale) has moved more
    /// than 4 from the value last sent (seeded 0x80), to every client on this level that
    /// knows the unit — mirroring the engine's last_sent_hp_pct gate + per-viewer send.
    fn broadcastHpChanges(self: *GameInstance, ls: *LevelState) void {
        var it = ls.units.iterator();
        while (it.next()) |e| {
            const guid = e.key_ptr.*;
            const u = e.value_ptr;
            if (u.unit_type != .monster or !u.isAlive()) continue;
            const maxhp = u.get(.maxhp);
            if (maxhp <= 0) continue;
            const pct: u8 = @intCast(std.math.clamp(@divTrunc(u.life() * 128, maxhp), 0, 128));
            const last = ls.hp_pct_sent.get(guid) orelse 0x80;
            if (@abs(@as(i32, pct) - @as(i32, last)) <= 4) continue;
            ls.hp_pct_sent.put(self.gpa, guid, pct) catch {};
            var scratch: [sc.UnitHpPercent.SIZE]u8 = undefined;
            const wire = (sc.UnitHpPercent{
                .unit_type = @intFromEnum(sim.UnitType.monster),
                .guid = guid,
                .hp_pct = pct,
            }).encode(&scratch);
            for (self.clients.items) |c| {
                if (c.level_id == ls.level_id and c.known.contains(guid)) self.queueToClient(c, wire);
            }
        }
    }

    /// FreePendingDrlgDeletes @0x53a820 — release rooms/DRLG structures queued for
    /// deletion this frame. TODO: no deferred-delete queue yet (levels live for the game).
    fn freePendingDrlgDeletes(self: *GameInstance, ls: *LevelState) void {
        _ = .{ self, ls };
    }

    /// QUEST_ProcessQuestTimers — advance the quest state machines (every 20 frames). TODO:
    /// we persist the quest bitfield across sessions but do not tick objectives in-game.
    fn processQuestTimers(self: *GameInstance) void {
        _ = self;
    }

    /// CleanupIdleRooms @0x52d240 — deactivate rooms with no nearby players (every 12
    /// frames). TODO: rooms stay active for the level's lifetime.
    fn cleanupIdleRooms(self: *GameInstance) void {
        _ = self;
    }

    /// FreeDungeons @0x61aa20 (every ~11 frames) — free fully-idle dungeon levels. A level with no player
    /// present (engine nActiveCount==0) is torn down once it has stayed empty past the idle timeout
    /// (~10 FreeDungeons ticks); its layout regenerates deterministically from the seed on re-entry
    /// (kill/loot state is not persisted — matching the engine). Towns aren't special-cased: they simply
    /// keep a player and so never go idle. Room-granularity GC (CleanupIdleRooms) isn't modelled — the
    /// host is level-scoped, not room-scoped.
    fn freeDungeons(self: *GameInstance) void {
        var to_free: [64]u16 = undefined;
        var nf: usize = 0;
        var lit = self.levels.iterator();
        while (lit.next()) |e| {
            const ls = e.value_ptr.*;
            const occupied = for (self.clients.items) |c| {
                if (c.level_id == ls.level_id) break true;
            } else false;
            if (occupied) {
                ls.empty_since = 0;
                continue;
            }
            if (ls.empty_since == 0) {
                ls.empty_since = @max(1, self.tick_count); // mark the frame it went empty (1 so 0 stays "occupied")
                continue;
            }
            if (self.tick_count -% ls.empty_since >= LEVEL_IDLE_FRAMES and nf < to_free.len) {
                to_free[nf] = ls.level_id;
                nf += 1;
            }
        }
        for (to_free[0..nf]) |lid| {
            if (self.levels.fetchRemove(lid)) |kv| {
                kv.value.deinit(self.gpa);
                self.gpa.destroy(kv.value);
            }
        }
    }

    /// Idle frames an empty level survives before FreeDungeons reaps it: ~10 FreeDungeons ticks × 11
    /// frames (the engine's dwInactiveFrames=10 countdown on a blocked level @0x61aa20).
    const LEVEL_IDLE_FRAMES: u64 = 110;

    /// FreeUnusedItems @0x52d310 — ground-item + corpse expiry. Called every frame; self-
    /// gates to every 0x5DC (1500) frames = 60s at 25fps (D2Common FreeUnusedItems @0x558b90
    /// removes a ground item once its stored expire frame is reached, comparing the field
    /// the engine keeps in nLinkedPortalY; 0 == persist, the normal case). We sweep expired
    /// ground items across every level; clients drop them via diffClient's item-exit pass.
    /// Corpse expiry runs on a separate unit-event path in the engine — TODO here.
    fn freeUnusedItems(self: *GameInstance) void {
        if (self.tick_count % 0x5DC != 0) return;
        var lit = self.levels.valueIterator();
        while (lit.next()) |lp| {
            const ls = lp.*;
            var i: usize = 0;
            while (i < ls.ground_items.items.len) {
                const it = ls.ground_items.items[i];
                if (it.expire_frame != 0 and it.expire_frame <= self.tick_count) {
                    _ = ls.ground_items.swapRemove(i);
                } else i += 1;
            }
        }
    }

    // --- EVENT_DispatchAllTimers @0x5414d0 -----------------------------------

    /// Routes a fired timer to its per-unit callback. Models the engine's fpTimerFunction
    /// / per-type default callback: given a due timer, run the work for (unit_type,
    /// timer_type). Returns whether the owning unit is still valid — a false return tells
    /// the queue to drop the timer (the engine frees a dead unit's timers likewise).
    const FireCtx = struct {
        gi: *GameInstance,
        ls: *LevelState,
        pub fn fire(self: *FireCtx, t: *const events.Timer) bool {
            // Object timers key into ls.objects, not the unit map (OBJECTEVENT callbacks).
            if (@as(sim.UnitType, @enumFromInt(t.unit_type)) == .object)
                return self.gi.fireObjectTimer(self.ls, t);
            const u = self.ls.units.getPtr(t.unit_guid) orelse return false;
            if (!u.isAlive()) return false;
            switch (@as(sim.UnitType, @enumFromInt(t.unit_type))) {
                .monster => switch (t.timer_type) {
                    .aithink => self.gi.aiThinkMonster(self.ls, t.unit_guid), // MONSTEREVENT AITHINK
                    .statregen => self.gi.statRegen(self.ls, u), //             MONSTEREVENT STATREGEN
                    else => {}, // other monster timer types not modelled yet
                },
                .player => switch (t.timer_type) {
                    .statregen => self.gi.statRegen(self.ls, u), // PLAYEREVENT STATREGEN
                    else => {},
                },
                // Object timers (OBJECTEVENT_DefaultCallback @0x586ad0): eD2ObjectAnimMode
                // 0 Neutral/1 Operating/2 Opened/3-7 Special; trap 3-state (idle/armed/fired)
                // reschedule +25 active / +15 idle; door toggle; day/night +1000/+600. TODO —
                // no objects are spawned into the world yet (next increment surfaces them).
                // Item/missile timers likewise route here once modelled.
                else => {},
            }
            return true;
        }
    };

    /// EVENT_DispatchAllTimers @0x5414d0 — the per-unit-type update dispatch. Missiles and
    /// player path-steps are not yet per-unit timers, so they run inline first, in the
    /// engine's missile-then-player order; then the real timer ring fires every unit's due
    /// scheduled callbacks (monster AITHINK/STATREGEN armed at spawn) in the engine's type
    /// order. `ls.moved` (this frame's position deltas) is reset at the top of the updates.
    fn dispatchAllTimers(self: *GameInstance, ls: *LevelState) void {
        ls.moved.clearRetainingCapacity();
        self.stepMissiles(ls); //  EVENT_DispatchMissileTimers @0x541240 (inline; TODO per-missile timer)
        self.playerPathStep(ls); // EVENT_DispatchPlayerTimers  @0x540f60 (path portion; TODO per-player path timer)
        var ctx = FireCtx{ .gi = self, .ls = ls };
        ls.timers.dispatchAll(self.gpa, @intCast(self.tick_count), &ctx);
    }

    /// The path-step portion of EVENT_DispatchPlayerTimers @0x540f60: advance each player
    /// with a pending walk/run target one step toward it, retiring the target on arrival.
    fn playerPathStep(self: *GameInstance, ls: *LevelState) void {
        var reached: std.ArrayListUnmanaged(u32) = .empty;
        defer reached.deinit(self.gpa);
        var tit = ls.targets.iterator();
        while (tit.next()) |e| {
            const guid = e.key_ptr.*;
            const tgt = e.value_ptr.*;
            const u = ls.units.getPtr(guid) orelse continue;
            if (self.moveUnitToward(ls, u, guid, tgt.x, tgt.y, MOVE_STEP, true)) reached.append(self.gpa, guid) catch {};
        }
        for (reached.items) |guid| _ = ls.targets.remove(guid);
    }

    /// UNITEVENTCALLBACK_STATREGEN — periodic life regen for a unit. Faithful to
    /// RegenAndPsnDecreaser @0x5a6920: read the unit's UNITSTAT_hpregen (id 74) per-frame
    /// delta — kept <<8 by the engine — and add it to hitpoints (also <<8), clamped to
    /// maxhp. Our units track WHOLE hp, so the sub-1 remainder banks in `regen_acc` and a
    /// whole HP is added when it overflows 256; the average rate is exact. Skipped when the
    /// delta is <= 0 (0 = no regen; negative = poison, which the engine suppresses in town
    /// — both TODO). The STATREGEN timer reschedules every +1 frame, matching our immediate
    /// registration. STATE_preventheal and the 0xAB hp% broadcast (threshold 4/128) are TODO.
    fn statRegen(self: *GameInstance, ls: *LevelState, u: *sim.Unit) void {
        const delta = u.get(.hpregen); // <<8 per-frame life delta
        if (delta <= 0) return;
        const maxhp = u.get(.maxhp);
        if (u.life() >= maxhp) return;
        const acc = (ls.regen_acc.get(u.unit_id) orelse 0) + delta;
        const whole = acc >> 8;
        ls.regen_acc.put(self.gpa, u.unit_id, acc & 0xFF) catch {};
        if (whole > 0) u.setLife(@min(u.life() + whole, maxhp));
    }

    // --- UpdateClients @0x52d440 ---------------------------------------------

    /// Build + send each client the visibility deltas of its current level, then flush.
    /// The engine splits build (UpdateClients) from the TASK-path FlushAllClientPackets
    /// @0x52e440; the host writes straight to the socket, so build+flush are one pass.
    fn updateClients(self: *GameInstance, writeFn: *const fn (i32, []const u8) isize) void {
        for (self.clients.items) |c| {
            const ls = self.levels.get(c.level_id) orelse continue;
            var pw = sc.PacketWriter.init(c.outbuf);
            // Event packets queued by command handlers go out first (chronologically
            // earlier than this frame's diff) — FlushAllClientPackets @0x52e440 order.
            if (c.pending.items.len > 0) {
                const n = @min(c.pending.items.len, c.outbuf.len);
                @memcpy(c.outbuf[0..n], c.pending.items[0..n]);
                pw.len = n;
                c.pending.clearRetainingCapacity();
            }
            self.diffClient(c, ls, &pw);
            const bytes = pw.bytes();
            // Send the flush RAW — no length prefix. We declare AF00 (compression OFF) in the
            // handshake, so the whole S->C stream is a raw concatenation of opcode-framed packets
            // and the client splits it by the per-opcode size table (nExpectedSize). The length
            // header of SendPacketToClient @0x52b330 is COMPRESSED-path (AF01) only; emitting it on
            // an AF00 stream desyncs the client (its length byte gets read as an opcode).
            if (bytes.len > 0) _ = writeFn(c.conn, bytes);
        }
    }

    fn diffClient(self: *GameInstance, c: *Client, ls: *LevelState, pw: *sc.PacketWriter) void {
        // A just-warped client leads with a fresh LoadAct, then drops its old-level item/
        // missile/warp visibility (the client resets its world on LoadAct); its old units
        // fall out below as "gone" -> RemoveObject.
        if (c.pending_loadact) {
            pw.add(sc.LoadAct{
                .act = self.act,
                .map_seed = self.seed,
                .area = ls.level_id,
                .automap = 0xFFFFFFFF,
            });
            c.pending_loadact = false;
            c.known_items.clearRetainingCapacity();
            c.known_missiles.clearRetainingCapacity();
            c.known_warps.clearRetainingCapacity();
            c.known_objects.clearRetainingCapacity();
        }

        const px = if (ls.units.getPtr(c.player_guid)) |pu| pu.x else c.x;
        const py = if (ls.units.getPtr(c.player_guid)) |pu| pu.y else c.y;

        // Exits: known units gone/dead/out of range.
        var to_remove: std.ArrayListUnmanaged(u32) = .empty;
        defer to_remove.deinit(self.gpa);
        var kit = c.known.keyIterator();
        while (kit.next()) |kp| {
            const guid = kp.*;
            const u = ls.units.getPtr(guid);
            const gone = u == null or !u.?.isAlive() or !inRange(px, py, u.?.x, u.?.y);
            if (gone) {
                const utype: u8 = if (u) |uu| @intFromEnum(uu.unit_type) else @intFromEnum(sim.UnitType.monster);
                pw.add(sc.RemoveObject{ .unit_type = utype, .guid = guid });
                to_remove.append(self.gpa, guid) catch {};
            }
        }
        for (to_remove.items) |guid| _ = c.known.remove(guid);

        // Enters + moves.
        var uit = ls.units.iterator();
        while (uit.next()) |e| {
            const guid = e.key_ptr.*;
            const u = e.value_ptr;
            if (!u.isAlive()) continue;
            if (!inRange(px, py, u.x, u.y)) continue;
            const known = c.known.contains(guid);
            if (!known) {
                self.emitCreate(pw, guid, u);
                c.known.put(self.gpa, guid, {}) catch {};
            } else if (ls.moved.contains(guid)) {
                pw.add(sc.ReassignPlayer{
                    .unit_type = @intFromEnum(u.unit_type),
                    .guid = guid,
                    .x = clampU16(u.x),
                    .y = clampU16(u.y),
                    .move_flag = 1,
                });
            }
        }

        // Outgoing warps in range the client hasn't seen -> AssignLevelWarp.
        for (ls.warps.items) |*w| {
            if (!inRange(px, py, w.x, w.y)) continue;
            if (c.known_warps.contains(w.guid)) continue;
            pw.add(sc.AssignLevelWarp{
                .unit_type = @intFromEnum(sim.UnitType.object),
                .guid = w.guid,
                .class_id = w.class_id,
                .x = clampU16(w.x),
                .y = clampU16(w.y),
            });
            c.known_warps.put(self.gpa, w.guid, {}) catch {};
        }

        // Seeded objects in range the client hasn't seen -> CreateObject (static; no
        // per-object exit yet — like warps, objects persist for the level's lifetime).
        for (ls.objects.items) |*o| {
            if (!inRange(px, py, o.x, o.y)) continue;
            if (c.known_objects.contains(o.guid)) continue;
            pw.add(sc.CreateObject{
                .unit_type = @intFromEnum(sim.UnitType.object),
                .guid = o.guid,
                .class_id = @truncate(@as(u32, @bitCast(o.class_id))),
                .x = clampU16(o.x),
                .y = clampU16(o.y),
            });
            c.known_objects.put(self.gpa, o.guid, {}) catch {};
        }

        // Ground-item exits: a known item that no longer exists (expired via
        // FreeUnusedItems, or picked up) or left range -> RemoveObject. Without this the
        // client would keep a ghost item on the ground forever (items were add-only).
        var it_remove: std.ArrayListUnmanaged(u32) = .empty;
        defer it_remove.deinit(self.gpa);
        var ikit = c.known_items.keyIterator();
        while (ikit.next()) |kp| {
            const guid = kp.*;
            const present = for (ls.ground_items.items) |*gi| {
                if (gi.guid == guid) break inRange(px, py, gi.x, gi.y);
            } else false;
            if (!present) {
                pw.add(sc.RemoveObject{ .unit_type = @intFromEnum(sim.UnitType.item), .guid = guid });
                it_remove.append(self.gpa, guid) catch {};
            }
        }
        for (it_remove.items) |guid| _ = c.known_items.remove(guid);

        // Ground items in range not yet seen -> ItemAction (add). A ROLLED item (from a monster/chest
        // drop) is serialized as its full on-ground item bit-stream (items.wire.writeItem) so the client
        // renders it with its real quality + affixes; gold and code-only spawns keep the light stub body.
        for (ls.ground_items.items) |*gi| {
            if (!inRange(px, py, gi.x, gi.y)) continue;
            if (c.known_items.contains(gi.guid)) continue;
            var body: [128]u8 = [_]u8{0} ** 128;
            var n: usize = 8;
            if (!gi.is_gold and gi.drop.quality != .invalid) {
                const si = StoredItem{ .guid = gi.guid, .code = gi.code, .drop = gi.drop, .item_seed = gi.drop.item_seed, .x = 0, .y = 0, .w = 1, .h = 1 };
                n = self.serializeItem(&body, &si, 3, clampU16(gi.x), clampU16(gi.y)); // dest 3 = on ground
            } else {
                std.mem.writeInt(u16, body[0..2], clampU16(gi.x), .little);
                std.mem.writeInt(u16, body[2..4], clampU16(gi.y), .little);
                @memcpy(body[4..8], &gi.code);
            }
            pw.add(sc.ItemAction{ .action = 0, .guid = gi.guid, .body = body[0..n] });
            c.known_items.put(self.gpa, gi.guid, {}) catch {};
        }

        // Missiles: create/move/remove via the generic object packets.
        var mi_remove: std.ArrayListUnmanaged(u32) = .empty;
        defer mi_remove.deinit(self.gpa);
        var mkit = c.known_missiles.keyIterator();
        while (mkit.next()) |kp| {
            const guid = kp.*;
            if (sim.missile.find(ls.missiles.items, guid)) |mm| {
                if (inRange(px, py, mm.x, mm.y)) continue;
            }
            pw.add(sc.RemoveObject{ .unit_type = @intFromEnum(sim.UnitType.missile), .guid = guid });
            mi_remove.append(self.gpa, guid) catch {};
        }
        for (mi_remove.items) |guid| _ = c.known_missiles.remove(guid);

        for (ls.missiles.items) |*mm| {
            if (!inRange(px, py, mm.x, mm.y)) continue;
            if (!c.known_missiles.contains(mm.guid)) {
                pw.add(sc.CreateObject{
                    .unit_type = @intFromEnum(sim.UnitType.missile),
                    .guid = mm.guid,
                    .class_id = mm.id,
                    .x = clampU16(mm.x),
                    .y = clampU16(mm.y),
                });
                c.known_missiles.put(self.gpa, mm.guid, {}) catch {};
            } else {
                pw.add(sc.ReassignPlayer{
                    .unit_type = @intFromEnum(sim.UnitType.missile),
                    .guid = mm.guid,
                    .x = clampU16(mm.x),
                    .y = clampU16(mm.y),
                    .move_flag = 1,
                });
            }
        }

        // Own player hp change -> Life packet.
        if (ls.units.getPtr(c.player_guid)) |pu| {
            if (pu.life() != c.last_hp) {
                c.last_hp = pu.life();
                pw.add(sc.Life{
                    .opcode = sc.Life.OP_LIFE,
                    .hp = @intCast(@max(0, pu.life())),
                    .mp = @intCast(@max(0, pu.get(.mana))),
                    .stamina = 0,
                    .x = clampU16(pu.x),
                    .y = clampU16(pu.y),
                });
            }
        }
    }

    fn emitCreate(self: *GameInstance, pw: *sc.PacketWriter, guid: u32, u: *const sim.Unit) void {
        _ = self;
        switch (u.unit_type) {
            .player => {
                var cp = sc.CreatePlayer{
                    .guid = guid,
                    .class_id = @intCast(@min(u.class_id, 6)),
                    .x = clampU16(u.x),
                    .y = clampU16(u.y),
                };
                cp.setName("Player");
                pw.add(cp);
            },
            .monster => {
                pw.add(sc.AssignMonster{
                    .guid = guid,
                    .monster_class = @intCast(@as(u16, @truncate(@as(u32, @bitCast(u.class_id))))),
                    .x = clampU16(u.x),
                    .y = clampU16(u.y),
                    .hp_pct = 128,
                });
            },
            else => {
                pw.add(sc.CreateObject{
                    .unit_type = @intFromEnum(u.unit_type),
                    .guid = guid,
                    .class_id = @intCast(@as(u16, @truncate(@as(u32, @bitCast(u.class_id))))),
                    .x = clampU16(u.x),
                    .y = clampU16(u.y),
                });
            },
        }
    }

    // --- inbound C->S -------------------------------------------------------

    /// Dispatch one fully-framed C->S command for `c` against its current level. Returns
    /// bytes consumed, or 0 if the buffer doesn't hold a complete packet yet.
    pub fn handleCommand(self: *GameInstance, c: *Client, buf: []const u8) usize {
        if (buf.len == 0) return 0;
        const op: cs.Op = @enumFromInt(buf[0]);
        const n = csPacketSize(buf) orelse return 0;
        if (buf.len < n) return 0;

        const ls = self.levels.get(c.level_id) orelse return n;

        switch (op) {
            .walk_to_location, .run_to_location => {
                // Walk (0x01) and run (0x03) share the CoordCmd payload; decode the coords
                // directly so both opcodes are accepted (cs.WalkToLocation.decode is
                // opcode-gated on 0x01 and would reject a 0x03 run).
                const x = std.mem.readInt(u16, buf[1..3], .little);
                const y = std.mem.readInt(u16, buf[3..5], .little);
                ls.targets.put(self.gpa, c.player_guid, .{ .x = x, .y = y }) catch {};
            },
            .walk_to_entity, .run_to_entity => {
                // Walk (0x02) and run (0x04) share the EntityCmd payload; decode the guid
                // directly (the opcode-gated decoders would reject the other opcode).
                const guid = std.mem.readInt(u32, buf[5..9], .little);
                if (ls.units.getPtr(guid)) |t| {
                    ls.targets.put(self.gpa, c.player_guid, .{ .x = t.x, .y = t.y }) catch {};
                }
            },
            .select_skill => {
                const cmd = cs.SelectSkill.decode(buf) catch return n;
                if (cmd.left) c.left_skill = cmd.skill_id else c.right_skill = cmd.skill_id;
            },
            .left_skill_on_entity, .right_skill_on_entity => {
                const cmd = cs.LeftSkillOnEntity.decode(buf) catch return n;
                const skill_id = if (op == .left_skill_on_entity) c.left_skill else c.right_skill;
                self.castSkill(c, ls, skill_id, .{ .guid = cmd.guid });
            },
            .left_skill_on_location, .right_skill_on_location => {
                // Left (0x05) and right (0x0C) share the CoordCmd payload; decode the coords
                // directly (the opcode-gated LeftSkillOnLocation.decode would reject 0x0C).
                const x = std.mem.readInt(u16, buf[1..3], .little);
                const y = std.mem.readInt(u16, buf[3..5], .little);
                const skill_id = if (op == .left_skill_on_location) c.left_skill else c.right_skill;
                self.castSkill(c, ls, skill_id, .{ .x = x, .y = y });
            },
            .interact_with_entity => {
                // A warp interaction transitions the player to the warp's destination
                // level; an object interaction operates it (SERVER_InteractOrPick's
                // OBJECT branch -> InteractWithObject @0x584420 OperateFn dispatch).
                const cmd = cs.InteractWithEntity.decode(buf) catch return n;
                for (ls.warps.items) |w| {
                    if (w.guid == cmd.guid) {
                        self.warpClient(c, w.dest_level);
                        return n;
                    }
                }
                if (ls.npcs.contains(cmd.guid)) {
                    self.openNpcInteraction(c, cmd.guid);
                    return n;
                }
                for (ls.objects.items) |*o| {
                    if (o.guid == cmd.guid) {
                        self.operateObject(c, ls, o);
                        break;
                    }
                }
            },
            .pick_up_item => {
                const cmd = cs.PickUpItem.decode(buf) catch return n;
                self.pickUpItem(c, ls, cmd);
            },
            .equip_item => {
                // ItemToBody @0x54ad90: move the inventory item into its body slot + apply its mods.
                const cmd = cs.EquipItem.decode(buf) catch return n;
                _ = self.equipItem(c, ls, cmd.guid, cmd.body_loc);
            },
            .unequip_item => {
                // BodyToInventory @0x54aec0: move the worn item back to the grid + remove its mods.
                const cmd = cs.UnequipItem.decode(buf) catch return n;
                _ = self.unequipItem(c, ls, @intCast(cmd.body_loc & 0xFF));
            },
            .chat_message => {
                const cmd = cs.ChatMessage.decode(buf) catch return n;
                std.debug.print("[chat] {s}: {s}\n", .{ "player", cmd.msg });
            },
            else => {},
        }
        return n;
    }

    /// Transition `c`'s player to `dest_level`: generate the target if needed, move the
    /// player unit into it at its entry point, and flag the client for a fresh LoadAct so
    /// the next diff re-populates its surroundings (and drops the old level's visibility).
    pub fn warpClient(self: *GameInstance, c: *Client, dest_level: u16) void {
        const src = self.levels.get(c.level_id) orelse return;
        const dst = self.ensureLevel(dest_level) catch return;
        if (dst == src) return;

        const removed = src.units.fetchRemove(c.player_guid) orelse return;
        _ = src.targets.remove(c.player_guid);
        _ = src.moved.remove(c.player_guid);

        var u = removed.value;
        u.x = dst.entry_x;
        u.y = dst.entry_y;
        if (!u.isAlive()) u.setLife(u.get(.maxhp));
        dst.units.put(self.gpa, c.player_guid, u) catch {
            // Put it back on failure so the player isn't lost.
            src.units.put(self.gpa, c.player_guid, u) catch {};
            return;
        };

        c.level_id = dest_level;
        c.x = dst.entry_x;
        c.y = dst.entry_y;
        c.last_hp = -1; // force a fresh Life packet
        c.pending_loadact = true;
        _ = c.known.remove(c.player_guid); // re-emit CreatePlayer after LoadAct
    }

    /// Pickup adjacency in subtiles. SERVER_InteractOrPick @0x548b00's UNIT_ITEM branch
    /// only picks up when GetDistanceBetweenUnits < 5 AND no wall/door between; the outer
    /// <0x33 gate just means "walk toward it first" (that path-then-pick chain is TODO —
    /// we apply immediately when already within 5). Our distance is Euclidean over
    /// subtiles, an approximation of the engine's metric.
    const PICKUP_RANGE: i32 = 5;

    /// C->S 0x16 (SCMD_0x16_InteractWithEntityEx @0x54aad0 -> SERVER_InteractOrPick):
    /// an ITEM target picks the ground item up (bSetting 0 = to-inventory, else cursor).
    /// Gold folds into the gold stat, clamped to the inventory limit GetInventoryGoldLimit
    /// @0x622e70 = level * 10000; the client is notified with GoldPickup 0x19 for amounts
    /// < 255, else SetDWordAttr 0x1F carrying stat 0x0E (gold) and the NEW total — the exact
    /// size switch of the 0x19 sender @0x53e9b0. Items: confirm with ItemAction action=1
    /// (picked); no server inventory model yet, so a picked item ceases to exist (TODO:
    /// inventory + drop-back).
    fn pickUpItem(self: *GameInstance, c: *Client, ls: *LevelState, cmd: cs.PickUpItem) void {
        const player = ls.units.getPtr(c.player_guid) orelse return;
        const idx = for (ls.ground_items.items, 0..) |*gi, i| {
            if (gi.guid == cmd.guid) break i;
        } else return;
        const gi = ls.ground_items.items[idx];

        // Adjacency: engine requires distance < 5 (reject at >= 5).
        const dx = player.x - gi.x;
        const dy = player.y - gi.y;
        if (dx * dx + dy * dy >= PICKUP_RANGE * PICKUP_RANGE) return;

        var scratch: [16]u8 = undefined;
        if (gi.is_gold) {
            const qty = @max(1, gi.quantity);
            const cap = 10_000 * @max(1, player.get(.level)); // GetInventoryGoldLimit @0x622e70
            const total = @min(player.get(.gold) + qty, cap);
            player.set(.gold, total);
            if (qty < 255) {
                self.queueToClient(c, (sc.GoldPickup{ .amount = @intCast(qty) }).encode(&scratch));
            } else {
                self.queueToClient(c, (sc.SetDWordAttr{
                    .attr = @intCast(@intFromEnum(sim.Stat.gold)),
                    .value = @intCast(@max(0, total)),
                }).encode(&scratch));
            }
            // The pile vanishing reaches every client (incl. the picker) via the ground-
            // item exit pass -> RemoveObject.
        } else {
            // Store it in the server-side inventory. Resolve the grid footprint from the item tables
            // (default 1x1 when unknown); a FULL inventory rejects the pickup, leaving it on the ground.
            const code_slice = std.mem.sliceTo(&gi.code, 0);
            const dims: [2]u8 = if (self.item_tables) |*t| (t.itemDims(code_slice) orelse .{ 1, 1 }) else .{ 1, 1 };
            const slot = c.invFindSlot(dims[0], dims[1]) orelse return; // no room -> item stays on the ground
            c.inventory.append(self.gpa, .{
                .guid = gi.guid,
                .code = gi.code,
                .quantity = @max(1, gi.quantity),
                .x = slot[0],
                .y = slot[1],
                .w = dims[0],
                .h = dims[1],
                .drop = gi.drop, // carry the rolled identity so the item is equippable with its stats
                .item_seed = gi.drop.item_seed,
            }) catch return;

            var body: [8]u8 = undefined;
            std.mem.writeInt(u16, body[0..2], clampU16(gi.x), .little);
            std.mem.writeInt(u16, body[2..4], clampU16(gi.y), .little);
            @memcpy(body[4..8], &gi.code);
            var abuf: [24]u8 = undefined;
            self.queueToClient(c, (sc.ItemAction{ .action = 1, .guid = gi.guid, .body = body[0..8] }).encode(&abuf));
            // The ItemAction moves it off the ground client-side; drop it from the picker's known set so
            // the exit pass doesn't also RemoveObject.
            _ = c.known_items.remove(gi.guid);
        }
        _ = ls.ground_items.swapRemove(idx);
    }

    /// Queue an event packet on a client's pending buffer (the engine's per-client packet
    /// buffer), flushed ahead of the visibility diff next UpdateClients.
    fn queueToClient(self: *GameInstance, c: *Client, bytes: []const u8) void {
        c.pending.appendSlice(self.gpa, bytes) catch {};
    }

    /// What each kind of thing collides with, straight out of the engine's mask table. Every
    /// collision question the host asks names one of these instead of asking "is this cell walkable",
    /// which was never a real question: a bolt flies over the object a player has to walk around,
    /// and a monster is stopped by pets a player passes through.
    const PLAYER_MASK: u16 = pf.Colmask.player_path;
    const MONSTER_MASK: u16 = pf.Colmask.monster_path;
    const MISSILE_MASK: u16 = pf.Colmask.missile_flight;

    /// Interact range for objects — SERVER_InteractOrPick @0x548b00 gates the OBJECT
    /// branch at distance < 0x33 subtiles (then LOS via IsObjectInInteractRange — TODO).
    const OBJECT_INTERACT_RANGE: i32 = 0x33;

    /// Door re-operate debounce in game frames — the engine gates OBJOP_ToggleDoor on GetTickCount +
    /// 500ms; at the 25fps server tick that is 12.5 frames, rounded to 13.
    const DOOR_DEBOUNCE_FRAMES: u64 = 13;

    /// Operate a world object — InteractWithObject @0x584420: dispatch on the object's
    /// Objects.txt OperateFn. Modelled families: lootables (1 casket / 3 urn / 4 chest)
    /// open once and roll their drop; doors (8) toggle open/close; shrines (2) grant their
    /// rolled Shrines.txt effect (Refill tops life+mana) and schedule a reset event
    /// nResetTimeInMins later; wells (22) flip to Operating (their refill is still TODO).
    /// Every mode change is broadcast to the level via ObjectState 0x0E; the engine
    /// routes that through UNITFLAG_DOUPDATE -> PacketUpdateForClient @0x581ad0.
    fn operateObject(self: *GameInstance, c: *Client, ls: *LevelState, o: *WorldObject) void {
        const player = ls.units.getPtr(c.player_guid) orelse return;
        const dx = player.x - o.x;
        const dy = player.y - o.y;
        if (dx * dx + dy * dy > OBJECT_INTERACT_RANGE * OBJECT_INTERACT_RANGE) return;
        // SERVER_InteractOrPick @0x548b00 also requires line of sight (IsObjectInInteractRange): a
        // wall between the player and the object rejects the interact. Our path grid tracks walkability
        // (walls block sight too), so we ray-cast walkability between the two — a faithful approximation.
        if (!ls.hasLineOfSight(player.x, player.y, o.x, o.y)) return;

        // Resolve the interaction to Effects (sim.object.operate) and apply each. The decision logic
        // (which OperateFn does what) lives in the pure sim resolver; the host just mutates state.
        var buf: [4]sim.effect.Effect = undefined;
        const ref = sim.object.ObjectRef{
            .guid = o.guid,
            .x = o.x,
            .y = o.y,
            .operate_fn = o.operate_fn,
            .anim_mode = o.anim_mode,
            .shrine_effect = o.shrine_effect,
            .shrine_reset_min = o.shrine_reset_min,
        };
        for (sim.object.operate(ref, &buf)) |e| self.applyEffect(c, ls, e);
    }

    fn objectByGuid(ls: *LevelState, guid: u32) ?*WorldObject {
        for (ls.objects.items) |*o| {
            if (o.guid == guid) return o;
        }
        return null;
    }

    /// Apply one resolved Effect against live world state — the single mutation point shared by the
    /// object and (in progress) skill resolvers.
    fn applyEffect(self: *GameInstance, c: *Client, ls: *LevelState, e: sim.effect.Effect) void {
        switch (e) {
            .set_anim_mode => |a| {
                if (objectByGuid(ls, a.guid)) |o| {
                    o.anim_mode = a.mode;
                    self.broadcastObjectState(ls, o);
                }
            },
            .roll_drops => |d| self.rollChestDrops(ls, d.x, d.y),
            .grant_shrine => |eff| {
                if (ls.units.getPtr(c.player_guid)) |p| {
                    const g = sim.shrines.grantFor(eff, p.get(.maxhp), p.get(.maxmana));
                    if (g.life) |v| p.setLife(v);
                    if (g.mana) |v| p.set(.mana, v);
                }
            },
            .schedule_reset => |r| {
                const frames = sim.shrines.resetDelayFrames(r.minutes);
                if (frames > 0) ls.timers.setEvent(self.gpa, @intCast(self.tick_count), r.guid, @intFromEnum(sim.UnitType.object), .activestate, frames, 0, 0) catch {};
            },
            .refill_life_mana => {
                if (ls.units.getPtr(c.player_guid)) |p| {
                    p.setLife(p.get(.maxhp));
                    p.set(.mana, p.get(.maxmana));
                }
            },
            .toggle_door => |d| {
                if (objectByGuid(ls, d.guid)) |o| {
                    // 500ms debounce so a client spamming interact can't flutter the door.
                    if (o.last_op_frame != 0 and self.tick_count < o.last_op_frame + DOOR_DEBOUNCE_FRAMES) return;
                    o.last_op_frame = self.tick_count;
                    o.anim_mode = if (o.anim_mode == 0) 5 else 0;
                    self.broadcastObjectState(ls, o);
                }
            },
            .activate_waypoint => |w| {
                if (objectByGuid(ls, w.guid)) |o| {
                    o.anim_mode = 1;
                    self.broadcastObjectState(ls, o);
                }
            },
            .warp_level => |w| self.warpClient(c, w.level_id),
            .open_stash => {}, // personal stash UI is client-side; nothing to mutate server-side yet
            .curse_area => |ca| {
                if (self.skills == null or self.buff_ctx == null) return;
                const sk = &self.skills.?;
                const isc = &self.buff_ctx.?.isc;
                const r2: i64 = @as(i64, ca.radius) * ca.radius;
                var it = ls.units.valueIterator();
                while (it.next()) |u| {
                    if (!sim.select.isHostileMonster(u)) continue;
                    const dx: i64 = u.x - ca.x;
                    const dy: i64 = u.y - ca.y;
                    if (dx * dx + dy * dy > r2) continue;
                    const gop = ls.curses.getOrPut(self.gpa, u.unit_id) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = .{};
                    gop.value_ptr.clearAll(u); // one curse per unit
                    gop.value_ptr.apply(u, sk, isc, ca.skill_id, ca.level, ca.duration);
                }
            },
            .cc_area => |cc| {
                const end = self.tick_count + cc.frames;
                const map: *std.AutoHashMapUnmanaged(u32, u64) = switch (cc.kind) {
                    .stun => &ls.frozen,
                    .fear => &ls.feared,
                    .chill => &ls.chilled,
                };
                if (cc.radius > 0) {
                    const r2: i64 = @as(i64, cc.radius) * cc.radius;
                    var it = ls.units.iterator();
                    while (it.next()) |ent| {
                        if (!sim.select.isHostileMonster(ent.value_ptr)) continue;
                        const dx: i64 = ent.value_ptr.x - cc.x;
                        const dy: i64 = ent.value_ptr.y - cc.y;
                        if (dx * dx + dy * dy <= r2) map.put(self.gpa, ent.key_ptr.*, end) catch {};
                    }
                } else if (cc.target_guid != 0 and ls.units.contains(cc.target_guid)) {
                    map.put(self.gpa, cc.target_guid, end) catch {};
                }
            },
            .set_aura => |a| c.active_aura = a.skill_id,
            .reposition => |rp| {
                if (ls.units.getPtr(c.player_guid)) |caster| self.repositionPlayer(ls, c, caster, rp.x, rp.y);
            },
            .teleport => |tp| {
                const caster = ls.units.getPtr(c.player_guid) orelse return;
                var tx: i32 = tp.x;
                var ty: i32 = tp.y;
                if (tp.guid != 0) {
                    if (ls.units.getPtr(tp.guid)) |tu| {
                        tx = tu.x;
                        ty = tu.y;
                    }
                }
                if (self.tryTeleport(ls, caster, c.player_guid, tx, ty) == .moved) {
                    c.x = caster.x;
                    c.y = caster.y;
                    var scratch: [16]u8 = undefined;
                    self.queueToClient(c, (sc.ReassignPlayer{
                        .unit_type = @intFromEnum(caster.unit_type),
                        .guid = c.player_guid,
                        .x = clampU16(caster.x),
                        .y = clampU16(caster.y),
                        .move_flag = 1,
                    }).encode(&scratch));
                }
            },
            .buff_self => |b| {
                if (self.buff_ctx) |*bx| {
                    const caster = ls.units.getPtr(c.player_guid) orelse return;
                    const bk = c.build.book(&self.skills.?);
                    bx.cast(&c.buffs, caster, &self.skills.?, bk, b.skill_id, bk.get(b.skill_id));
                }
            },
            .shapeshift => |sh| {
                if (self.buff_ctx) |*bx| {
                    const caster = ls.units.getPtr(c.player_guid) orelse return;
                    if (c.form_skill == sh.skill_id) {
                        c.buffs.remove(caster, sh.skill_id);
                        c.form_skill = 0;
                    } else {
                        if (c.form_skill != 0) c.buffs.remove(caster, c.form_skill);
                        const bk = c.build.book(&self.skills.?);
                        c.buffs.apply(caster, &self.skills.?, &bx.isc, sh.skill_id, bk.get(sh.skill_id), std.math.maxInt(i32));
                        c.form_skill = sh.skill_id;
                    }
                }
            },
            .poison_dot => |pd| {
                if (self.skills == null) return;
                const tu = ls.units.getPtr(pd.target_guid) orelse return;
                const sk = &self.skills.?;
                const hit = sim.skill.castDirectElemental(sk, c.build.book(sk), pd.skill_id, pd.level, tu, &self.combat_seed);
                const sd = sk.byId(pd.skill_id) orelse return;
                ls.poison_dots.put(self.gpa, pd.target_guid, sim.skill.poisonOverTime(hit, sd.e_len)) catch {};
            },
            .charge_up_strike => |cu| {
                if (self.skills == null) return;
                const sk = &self.skills.?;
                const sdd = sk.byId(cu.skill_id) orelse return;
                const caster = ls.units.getPtr(c.player_guid) orelse return;
                if (cu.target_guid == 0) return;
                if (ls.units.getPtr(cu.target_guid)) |tu| {
                    if (sim.select.isHostileMonster(tu)) {
                        const book = c.build.book(sk);
                        const cc: i32 = @max(1, @as(i32, c.charge_count));
                        const prgdam = if (sk.rowById(cu.skill_id)) |row| (sk.table.getInt(i32, row, "prgdam") orelse 0) else 0;
                        const ed: i32 = if (prgdam == 1) sk.evalCalc(book, 0, cu.skill_id, cu.level, "calc1") * cc else 0;
                        const r = sim.combat.resolveAttack(caster, tu, &self.combat_seed, .{ .ed_percent = ed, .defender_block_factor = 0 });
                        if (r.hit) {
                            var phys = r.damage;
                            if (prgdam == 4 and sdd.dmg.etype != .none) {
                                var pct = sk.evalCalc(book, 0, cu.skill_id, cu.level, "calc1");
                                if (pct > 100) pct = 100;
                                if (pct > 0) {
                                    const converted = @divTrunc(phys * pct, 100);
                                    phys -= converted;
                                    sim.combat.applyToLife(tu, sim.combat.applyDamageComponent(converted, sdd.dmg.etype, tu).applied);
                                }
                                if (sdd.dmg.etype == .cold and cc >= 3) {
                                    const p4 = sk.param(cu.skill_id, 4);
                                    if (p4 > 0) ls.frozen.put(self.gpa, tu.unit_id, self.tick_count + @as(u64, @intCast(@max(1, @divTrunc(sdd.e_len, p4))))) catch {};
                                }
                            }
                            if (prgdam == 2) {
                                const cdiff: sim.Difficulty = @enumFromInt(@intFromEnum(self.difficulty));
                                const scale: i32 = if (cc >= 3) 2 else 1;
                                const stolen = sim.combat.leech(phys, sk.param(cu.skill_id, 1) * scale, sim.difficulty.lifeStealDivisor(cdiff));
                                if (stolen > 0) {
                                    caster.setLife(@min(caster.get(.maxhp), caster.life() + stolen));
                                    if (cc >= 2) caster.set(.mana, @min(caster.get(.maxmana), caster.get(.mana) + stolen));
                                }
                            }
                            sim.combat.applyToLife(tu, phys);
                        }
                        if (c.charge_skill == cu.skill_id) {
                            c.charge_count = @min(3, c.charge_count + 1);
                        } else {
                            c.charge_skill = cu.skill_id;
                            c.charge_count = 1;
                        }
                    }
                }
            },
            .warp_town => self.warpClient(c, townLevelForAct(self.act)),
            .spawn_missiles => |sm| {
                const md = if (self.missile_data) |*m| m else return;
                const sk = if (self.skills) |*s| s else return;
                const book = c.build.book(sk);
                var syn: [sim.spell.MAX_SYNERGIES]sim.spell.Synergy = undefined;
                const cst = sim.skill.castElemental(sk, book, sm.skill_id, sm.level, &syn);
                switch (sm.kind) {
                    .spiral => {
                        var hammers: [128]sim.Missile = undefined;
                        const n = sim.skill.castBlessedHammer(sk, md, c.player_guid, sm.skill_id, sm.x, sm.y, sm.level, cst, &hammers);
                        for (hammers[0..n]) |m| {
                            var mm = m;
                            mm.guid = self.allocGuid();
                            ls.missiles.append(self.gpa, mm) catch {};
                        }
                    },
                    .spread => {
                        var fan: [24]sim.Missile = undefined;
                        const n = sim.skill.castSpreadMissiles(sk, md, c.player_guid, sm.skill_id, sm.x, sm.y, sm.tx, sm.ty, @min(sm.count, fan.len), MISSILE_FAN_SPACING, cst, &fan);
                        for (fan[0..n]) |m| {
                            var mm = m;
                            mm.guid = self.allocGuid();
                            if (sm.homing) mm.homing = true;
                            ls.missiles.append(self.gpa, mm) catch {};
                        }
                    },
                }
            },
            .corpse_skill => |csk| {
                const sk = if (self.skills) |*s| s else return;
                const corpse_guid = self.findCorpse(ls, csk.x, csk.y, 16) orelse return;
                const corpse = ls.units.getPtr(corpse_guid).?;
                const cx = corpse.x;
                const cy = corpse.y;
                const cmaxhp = corpse.get(.maxhp);
                const clvl = corpse.get(.level);
                const cclass = corpse.class_id;
                const caster_level = if (ls.units.getPtr(c.player_guid)) |u| @max(1, u.get(.level)) else 1;
                const book = c.build.book(sk);
                switch (csk.kind) {
                    .explode => {
                        const hit = sim.skill.corpseExplosion(sk, book, csk.level, cmaxhp, caster_level, clvl, &self.combat_seed);
                        const radius = sk.evalCalc(book, 0, csk.skill_id, csk.level, "aurarangecalc");
                        const r2: i64 = @as(i64, radius) * radius;
                        const half = @divTrunc(hit.rolled, 2);
                        var uit = ls.units.valueIterator();
                        while (uit.next()) |u| {
                            if (!sim.select.isHostileMonster(u)) continue;
                            const dx: i64 = u.x - cx;
                            const dy: i64 = u.y - cy;
                            if (dx * dx + dy * dy > r2) continue;
                            const fire = sim.combat.applyDamageComponent(half, .fire, u).applied;
                            const phys = sim.combat.applyDamageComponent(hit.rolled - half, .none, u).applied;
                            sim.combat.applyToLife(u, fire + phys);
                        }
                    },
                    .poison_ring => {
                        if (self.missile_data) |*md| {
                            var syn: [sim.spell.MAX_SYNERGIES]sim.spell.Synergy = undefined;
                            const cst = sim.skill.castElemental(sk, book, csk.skill_id, csk.level, &syn);
                            var ring: [8]sim.Missile = undefined;
                            const n = sim.skill.castRadialMissiles(sk, md, c.player_guid, csk.skill_id, cx, cy, 8, cst, &ring);
                            for (ring[0..n]) |m| {
                                var mm = m;
                                mm.guid = self.allocGuid();
                                ls.missiles.append(self.gpa, mm) catch {};
                            }
                        }
                    },
                    .revive => {
                        var i: usize = 0;
                        while (i < c.revives.items.len) {
                            const alive = if (ls.units.getPtr(c.revives.items[i])) |ru| ru.isAlive() else false;
                            if (alive) i += 1 else _ = c.revives.orderedRemove(i);
                        }
                        const cap = sk.summonInfo(csk.skill_id, csk.level).count;
                        while (cap > 0 and c.revives.items.len >= @as(usize, @intCast(cap))) {
                            const old = c.revives.orderedRemove(0);
                            _ = ls.units.remove(old);
                            _ = ls.ai.remove(old);
                        }
                        if (self.spawnPet(ls, ls.level_id, @intCast(cclass), cx, cy, c.player_guid) catch null) |g| {
                            c.revives.append(self.gpa, g) catch {};
                        }
                    },
                }
                _ = ls.units.remove(corpse_guid);
                _ = ls.corpses.remove(corpse_guid);
            },
            .weapon_area => |wa| {
                const caster = ls.units.getPtr(c.player_guid) orelse return;
                const reach2: i64 = if (wa.sweep) @as(i64, AI_CONFIG.melee_range) * AI_CONFIG.melee_range else @as(i64, wa.radius) * wa.radius;
                var it = ls.units.valueIterator();
                while (it.next()) |u| {
                    if (!sim.select.isHostileMonster(u)) continue;
                    const inside = if (wa.sweep)
                        segDist2(wa.from_x, wa.from_y, wa.x, wa.y, u.x, u.y) <= reach2
                    else blk: {
                        const dx: i64 = u.x - wa.x;
                        const dy: i64 = u.y - wa.y;
                        break :blk dx * dx + dy * dy <= reach2;
                    };
                    if (!inside) continue;
                    const r = sim.combat.resolveAttack(caster, u, &self.combat_seed, .{ .ed_percent = wa.ed_percent, .defender_block_factor = 0 });
                    if (r.hit) sim.combat.applyToLife(u, r.damage);
                }
            },
            .weapon_strike => |ws| {
                if (ws.target_guid == 0 or self.skills == null) return;
                const caster = ls.units.getPtr(c.player_guid) orelse return;
                const tu = ls.units.getPtr(ws.target_guid) orelse return;
                if (ws.reposition) self.repositionPlayer(ls, c, caster, tu.x, tu.y);
                if (!sim.select.isHostileMonster(tu)) return;
                const sk = &self.skills.?;
                const book = c.build.book(sk);
                if (ws.use_melee_skill) {
                    const res = sim.skill.resolveMeleeSkill(sk, book, caster, tu, ws.skill_id, book.get(ws.skill_id), &self.combat_seed);
                    if (res.total_damage > 0) sim.combat.applyToLife(tu, res.total_damage);
                } else {
                    var h: i32 = 0;
                    while (h < @max(1, ws.hits) and tu.isAlive()) : (h += 1) {
                        const r = sim.combat.resolveAttack(caster, tu, &self.combat_seed, .{ .ed_percent = ws.ed_percent, .defender_block_factor = 0 });
                        if (r.hit) sim.combat.applyToLife(tu, r.damage);
                    }
                }
            },
            .elemental_area => |ea| {
                if (self.skills == null) return;
                const sk = &self.skills.?;
                const book = c.build.book(sk);
                var tgts: std.ArrayListUnmanaged(*sim.Unit) = .empty;
                defer tgts.deinit(self.gpa);
                var it = ls.units.valueIterator();
                while (it.next()) |u| {
                    if (sim.select.isHostileMonster(u)) tgts.append(self.gpa, u) catch {};
                }
                if (ea.static) {
                    const cdiff: sim.Difficulty = @enumFromInt(@intFromEnum(self.difficulty));
                    _ = sim.skill.castStaticFieldArea(sk, book, ea.level, ea.x, ea.y, ea.radius, cdiff, tgts.items);
                } else {
                    _ = sim.skill.castDirectAreaElemental(sk, book, ea.skill_id, ea.level, ea.x, ea.y, ea.radius, tgts.items, &self.combat_seed);
                }
            },
            .ground_effect => |g| {
                ls.ground_effects.append(self.gpa, .{
                    .skill_id = g.skill_id,
                    .level = g.level,
                    .x = g.x,
                    .y = g.y,
                    .radius = GROUND_EFFECT_RADIUS,
                    .end_frame = self.tick_count + @as(u64, @intCast(@max(0, g.duration))),
                }) catch {};
            },
            .summon => |s| {
                const pet_class = sim.skill.monClassByName(self.gpa, s.monster) orelse return;
                switch (s.kind) {
                    .golem => {
                        if (c.golem_guid != 0) {
                            _ = ls.units.remove(c.golem_guid);
                            _ = ls.ai.remove(c.golem_guid);
                        }
                        c.golem_guid = self.spawnPet(ls, ls.level_id, @intCast(pet_class), s.x, s.y, c.player_guid) catch 0;
                    },
                    .pet, .trap, .hydra_head => {
                        if (s.kind == .pet or s.kind == .trap) enforcePetCap(ls, c.player_guid, pet_class, s.count);
                        if (self.spawnPet(ls, ls.level_id, @intCast(pet_class), s.x, s.y, c.player_guid) catch null) |g| {
                            if (s.kind == .trap or s.kind == .hydra_head) ls.stationary.put(self.gpa, g, {}) catch {};
                        }
                    },
                }
            },
        }
    }

    /// Open a town NPC's interaction menu — SERVER_InteractOrPick @0x548b00 UNIT_MONSTER
    /// branch -> NPC_BeginInteraction @0x572c10. The client opens the talk/trade dialog on
    /// receipt of S->C 0x27 NpcInfo (guid + unit type), then 0x28 PlayerQuestInfo carries the
    /// quest state. The gossip/dialogue entry list (0x27 aMessages) + the merc list (0x4E) + the
    /// follow-up menu-selection commands (0x2F/0x30/0x38 C->S) are later slices.
    fn openNpcInteraction(self: *GameInstance, c: *Client, npc_guid: u32) void {
        // NPC_BeginInteraction @0x572c10 sequence: 0x27 NpcInfo OPENS the dialog on the client, then
        // 0x28 PlayerQuestInfo carries the quest state. (The 0x4E merc list + 0x29 quest-log prep and
        // the gossip/dialogue entries are follow-ups.)
        var b0: [sc.NpcInfo.SIZE]u8 = undefined;
        self.queueToClient(c, (sc.NpcInfo{ .npc_guid = npc_guid }).encode(&b0));
        var b1: [sc.NpcInteract.SIZE]u8 = undefined;
        self.queueToClient(c, (sc.NpcInteract{ .npc_guid = npc_guid }).encode(&b1));
    }

    /// OBJECTEVENT callback — a due object timer. The shrine RESET event (type 5) re-enables a
    /// spent shrine: back to Neutral (anim mode 0), re-broadcast so clients can operate it
    /// again. Returns whether the object still exists (a removed object drops its timers).
    fn fireObjectTimer(self: *GameInstance, ls: *LevelState, t: *const events.Timer) bool {
        for (ls.objects.items) |*o| {
            if (o.guid != t.unit_guid) continue;
            switch (t.timer_type) {
                .activestate => { // RESET: re-enable the shrine
                    o.anim_mode = 0;
                    self.broadcastObjectState(ls, o);
                },
                else => {},
            }
            return true;
        }
        return false;
    }

    /// Broadcast an object's new state to every client in its level (ObjectState 0x0E).
    fn broadcastObjectState(self: *GameInstance, ls: *LevelState, o: *const WorldObject) void {
        var scratch: [sc.ObjectState.SIZE]u8 = undefined;
        const wire = (sc.ObjectState{ .guid = o.guid, .active = 1, .anim_mode = o.anim_mode }).encode(&scratch);
        for (self.clients.items) |cl| {
            if (cl.level_id == ls.level_id) self.queueToClient(cl, wire);
        }
    }

    /// Chest drop roll — RollChestDrops @0x585b90: the TC is act + difficulty + a 3-tier
    /// area-mlvl bucket over the act's [first,last] level mlvls (tier 0 below min+span/3,
    /// tier 2 from min+2*(span/3)), resolved to the "Act N [(N)|(H) ]Chest A/B/C" rows of
    /// TreasureClassEx via RollTreasureClass(difficulty, act, tier). Up to 6 drops (the
    /// engine's aResults size); ours land as ground items at the chest.
    fn rollChestDrops(self: *GameInstance, ls: *LevelState, x: i32, y: i32) void {
        self.ensureItemTables() catch return;
        if (self.world == null) return;
        const world = &self.world.?;

        // RollChestDrops @0x585b90 tier math, exact: third = (|max-min| + 1) / 3;
        // tier = 0 if monlvl < min+third, else 1 + (min + 2*third <= monlvl).
        const mlvl = world.monLvl(ls.level_id, self.difficulty);
        const act_no = world.actOf(ls.level_id);
        const b = world.actMonLvlBounds(act_no, self.difficulty);
        const third = @divTrunc(@as(i64, @intCast(@abs(b[1] - b[0]))) + 1, 3);
        var tier: u8 = 0;
        if (mlvl >= b[0] + third) tier = @intCast(1 + @intFromBool(b[0] + 2 * third <= mlvl));

        const diff_tag: []const u8 = switch (self.difficulty) {
            .normal => "",
            .nightmare => "(N) ",
            .hell => "(H) ",
        };
        var tc_buf: [32]u8 = undefined;
        const tc = std.fmt.bufPrint(&tc_buf, "Act {d} {s}Chest {c}", .{
            @as(i32, act_no + 1), diff_tag, @as(u8, 'A' + tier),
        }) catch return;

        if (items.rollDrop(self.gpa, &self.drop_seed, &self.game_seed, &self.item_tables.?, &self.tc_set.?, tc, @intCast(@max(1, mlvl)), .{})) |drops| {
            defer self.gpa.free(drops);
            var placed: usize = 0;
            for (drops) |d| {
                if (placed >= 6) break; // engine result-slot cap
                switch (d.kind) {
                    .gold => self.spawnGold(ls, x, y, d.quantity),
                    .item, .quiver => self.spawnItemDrop(ls, x, y, d),
                    else => continue,
                }
                placed += 1;
            }
        } else |_| {}
    }

    const CastTarget = struct { x: u16 = 0, y: u16 = 0, guid: u32 = 0 };

    fn castSkill(self: *GameInstance, c: *Client, ls: *LevelState, skill_id: u16, target: CastTarget) void {
        const caster = ls.units.getPtr(c.player_guid) orelse return;
        self.ensureSkillTables() catch return;

        // Teleport (DOFUNC_TELEPORT): a pure host-side reposition. Resolve the destination:
        // entity-targeted casts jump to (near) the target unit, location casts to (x,y). The move
        // is applied by tryTeleport, which enforces dest-passable + range + mana; it ignores any
        // intervening walls/monsters (that is the real skill's whole point).
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.doFunc() == .teleport) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        // Timed buff (Frozen Armor / Enchant / Battle Orders / ...): grant it to the caster with a
        // table-driven duration (auralencalc), refreshing rather than stacking. It modifies the
        // player's StatList (ticked down + removed on expiry in the per-frame loop). No missile.
        if (self.skills != null and sim.buff.isTimedBuff(&self.skills.?, skill_id)) {
            self.applyEffect(c, ls, .{ .buff_self = .{ .skill_id = skill_id } });
            // Buff+attack skills carry a state AND strike on cast, so they fall through to the melee/
            // charge-up branch: Frenzy (9), Maul (120), martial-arts charge-ups (34/35). Others stop.
            const also_attacks = if (self.skills.?.byId(skill_id)) |bsd|
                (bsd.doFunc() == .frenzy_melee_hit or bsd.doFunc() == .feral_rage or bsd.doFunc() == .charge_up_stack_melee or bsd.doFunc() == .elemental_charge_release)
            else
                false;
            if (!also_attacks) return;
        }

        // Paladin aura (Might / Concentration / Fanaticism / Defiance / ...): a continuous, single-slot
        // effect. Casting one just makes it the active aura (replacing any previous); tickAuras applies
        // its stats to units in range each frame. No missile, no instant apply.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.is_aura) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        // Utility scrolls (srvdofunc 113): Town Portal warps the caster to the act's town (a minimal
        // resolution of "open a portal to town" — the clickable portal object is a client/world feature);
        // Identify is a pure inventory reveal with no server-side combat/world state, recognized + consumed.
        if (self.skills.?.byId(skill_id)) |sdd113| {
            if (sdd113.doFunc() == .use_scroll_or_book) {
                if (self.skills.?.rowById(skill_id)) |row| {
                    if (std.mem.indexOf(u8, self.skills.?.table.get(row, "skill"), "Townportal") != null) {
                        self.applyEffect(c, ls, .warp_town);
                    }
                }
                return;
            }
        }

        // Shapeshift toggle (srvdofunc 116: Wearwolf / Wearbear / Delirium). Casting the active form
        // reverts to human; casting another form swaps. The form grants its aurastat bonuses (wolf:
        // stamina% + attack rating; bear: damage% + defense) as a near-permanent buff, removed on revert.
        // The model / combat-mode change is client-side.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.doFunc() == .werewolf) {
                    self.applyEffect(c, ls, .{ .shapeshift = .{ .skill_id = skill_id } });
                    return;
                }
            }
        }

        // Summon (Raise Skeleton / Skeletal Mage / the golems / Valkyrie / Druid pets): spawn the pet
        // from the skill's summon column with real MonLvl-scaled stats, owned by the caster, enforcing
        // the skill's pet cap (summonInfo count — the oldest rolls off at the cap). Its AI then hunts
        // hostile monsters (and it is owner-safe from the caster's own attacks). No missile, no target.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.is_summon) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        // Necromancer curse (srvdofunc 30: Amplify Damage / Weaken / Decrepify / Lower Resist / Life
        // Tap / ...): apply the curse's aurastat debuff to every hostile monster within the curse
        // radius (aurarangecalc) of the cast point, for auralencalc frames. One curse per unit — a new
        // curse replaces the old (clearAll). tickCurses lifts it on expiry. No missile.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.doFunc() == .cast_curse_aoe or sdd.doFunc() == .inner_sight) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    const book = c.build.book(sk);
                    for (sim.skill.resolve(sk, book, skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        // Corpse-consuming skills (Corpse Explosion srvdofunc 55, Poison Explosion 63): pick the
        // nearest corpse to the cast point, then explode it. CE deals corpseExplosion damage (half
        // fire / half physical, a % of the corpse's max life, scaled down if the caster out-levels it)
        // to hostile monsters within aurarangecalc; Poison Explosion spawns the faithful 8-missile
        // poison ring from the corpse (each missile DoTs on hit). Either way the corpse is consumed.
        // Corpse skills (Corpse Explosion 55, Poison Explosion 63, Revive 58): resolve() emits a
        // corpse_skill intent and applyEffect consumes the nearest corpse + runs the mechanic.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                switch (sdd.doFunc()) {
                    .corpse_explosion, .poison_explosion, .revive_corpse_check => {
                        var ebuf: [4]sim.effect.Effect = undefined;
                        for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                        return;
                    },
                    else => {},
                }
            }
        }

        // Persistent ground effects (Fire Wall srvdofunc 24, Blaze 23, Blizzard 28-no-radius): drop a
        // lingering AoE at the target that pulses the skill's staged elemental damage to hostile monsters
        // in range EVERY frame (recon: the effect missile has NextDelay 0 -> re-hits each frame) for the
        // effect's duration (damage-missile Range: firewall/blaze 90f, blizzardcenter 100f).
        // castDirectAreaElemental replicates the engine's per-frame damage from the skill's E*/HitShift.
        // Persistent ground effects (Fire Wall 24 / Blaze 23 / Blizzard 28 / Volcano 123 / Armageddon
        // 124): resolve() decides which of these coarse candidates is actually a ground effect (Energy
        // Shield 23 and Meteor 28 fall through with no effect).
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                switch (sdd.doFunc()) {
                    .blaze_energy_shield, .fire_wall, .meteor_blizzard, .volcano, .armageddon => {
                        var ebuf: [4]sim.effect.Effect = undefined;
                        const effs = sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf);
                        if (effs.len > 0) {
                            for (effs) |e| self.applyEffect(c, ls, e);
                            return;
                        }
                    },
                    else => {},
                }
            }
        }

        // Fear casters (Grim Ward srvdofunc 75, Howl srvdofunc 22-with-no-element): every hostile monster
        // within range flees the player (fear-AI) for the duration. Grim Ward's radius/duration come from
        // aurarangecalc/auralencalc; Howl carries them in params (documented fallback). Centred on caster.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.doFunc() == .grim_ward or (sdd.doFunc() == .nova_frost_nova and sdd.dmg.etype == .none)) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        // Blessed Hammer (srvdofunc 73): a magic hammer spiralling out from the paladin — modeled as a
        // magic AoE around the caster dealing the skill's staged magic damage (EType=mag, EMin=12) to
        // hostile monsters within reach. The exact spiral path is bespoke geometry; the magic damage +
        // reach resolve here (reach = the documented GROUND_EFFECT_RADIUS).
        // Blessed Hammer: resolve() emits a spawn_missiles(.spiral) intent.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.doFunc() == .blessed_hammer and self.missile_data != null) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        // Meteor (srvdofunc 28 with a radius): the fire impact deals the skill's staged fire damage to
        // every hostile monster within aurarangecalc of the target point (recon Skills_SrvDoFunc_028
        // spawns the meteor missile at the target; we resolve its impact AoE directly). The fall delay +
        // lingering fire pool are refinements; Blizzard (srvdofunc 28, no aurarangecalc) is a duration
        // effect that needs the missile-timer subsystem.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                // Meteor's ground burst (28 + aurarangecalc) and Fist of the Heavens (80 = the holy
                // lightning nova, EType ltng, radius 20) both deal the skill's element to every hostile in
                // the burst radius around the cast point. FoH's descending holy bolt (magic) is a refinement.
                if (sdd.doFunc() == .meteor_blizzard or sdd.doFunc() == .fist_of_the_heavens) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    const effs = sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf);
                    if (effs.len > 0) {
                        for (effs) |e| self.applyEffect(c, ls, e);
                        return;
                    }
                }
            }
        }

        // Multiple Shot / Teeth (srvdofunc 8): fire calc1 projectiles fanned toward the target (recon
        // StrafeMissileSpread). Count = calc1 (min(24, 2+level)); Teeth carries magic damage, Multiple
        // Shot's arrows carry the srvmissilea flat damage. Exact fan spacing is engine geometry (approx).
        // Multiple Shot / Charged Bolt / Guided Arrow: resolve() emits a spawn_missiles(.spread) intent.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if ((sdd.doFunc() == .multi_shot or sdd.doFunc() == .charged_bolt or sdd.doFunc() == .guided_arrow_launch) and self.missile_data != null) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        // Martial-arts charge-ups (srvdofunc 35: Fists of Fire / Claws of Thunder / Blades of Ice): a
        // melee weapon strike that ALSO discharges its element on the struck target (recon
        // ChargeUpStackMelee: to-hit + weapon damage, then AddChargeUpStack; the charge's element
        // releases on the hit via ApplyChargeUpDamage). The full accumulate-then-finisher-release timing
        // + the release novas are a refinement; the melee + elemental hit resolves here, and the charge
        // count is tracked on the Client.
        // Martial-arts charge-ups (34 Tiger/Cobra/Phoenix, 35 Fists of Fire/Claws of Thunder/Blades of
        // Ice): resolve() emits a charge_up_strike and applyEffect does the hit + prgdam charge effect.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.doFunc() == .elemental_charge_release or sdd.doFunc() == .charge_up_stack_melee) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        // Melee weapon-strike skills (Bash-family, throws, Jab/Charged Strike/... group, dual-wield
        // Frenzy/Double Swing, Charge/Dragon Flight, multi-hit Fend/Zeal, Sacrifice/Smite): resolve()
        // picks the ed%/hits/reposition/multi-hit and applyEffect lands the weapon attack. The 34/35
        // charge-ups above are handled separately (they accrue charges before striking).
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                switch (sdd.doFunc()) {
                    .generic_melee_hit, .multi_hit_attack, .sacrifice, .smite, .charge, .dragon_flight, .frenzy_melee_hit, .double_swing, .throw_weapon_left_hand, .throw_weapon_right_hand, .jab, .charged_strike, .lightning_strike, .dragon_talon, .dragon_claw, .dragon_tail_fire_explosion, .double_throw, .melee_attack_with_missile_wrapper, .feral_rage, .rabies, .hunger => {
                        var ebuf: [4]sim.effect.Effect = undefined;
                        for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                        return;
                    },
                    else => {},
                }
            }
        }

        // Whirlwind (srvdofunc 76): sweep from the caster to the target point, hitting every hostile
        // monster within melee reach of that path with a weapon attack boosted by calc1% enhanced
        // damage (recon SKILLBAR_WhirlwindHitCycle: weapon SrcDam x (1 + calc1% ED), one to-hit roll per
        // victim). The barb ends at the whirl endpoint. Reuses the AI melee reach (no separate hit
        // radius exists in the table — Whirlwind hits what it passes at melee range).
        // Whirlwind / Leap / Leap Attack: resolve() emits the sweep/area-strike + reposition.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                switch (sdd.doFunc()) {
                    .whirlwind, .leap, .leap_attack => {
                        var ebuf: [4]sim.effect.Effect = undefined;
                        for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                        return;
                    },
                    else => {},
                }
            }
        }

        // Static Field: an AREA cast whose radius is table-driven (aurarangecalc = 5+level). Every
        // alive monster within the ring around the caster loses calc1% of its CURRENT life as
        // lightning, floored per difficulty (Normal 0 / NM 33% / Hell 50%). Pure life mutation like
        // melee — the per-frame diff streams the new life to clients. No missile, no single target.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                if (sdd.doFunc() == .static) {
                    var ebuf: [4]sim.effect.Effect = undefined;
                    for (sim.skill.resolve(sk, c.build.book(sk), skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                    return;
                }
            }
        }

        const tgt_unit: ?*sim.Unit = if (target.guid != 0) ls.units.getPtr(target.guid) else null;
        const st = sim.skill.Target{ .x = target.x, .y = target.y, .unit = tgt_unit };

        // Poison Dagger (srvdofunc 32): a single-target poison stab. Resolve the poison hit vs the
        // target's poison resist and register it as a damage-over-time spread across the skill's ELen
        // (refresh, not stack) — ticked off each frame by tickPoison. Faithful DoT, no instant lump.
        if (tgt_unit) |_| {
            if (self.skills.?.byId(skill_id)) |sdd| {
                if (sdd.doFunc() == .apply_direct_damage and sdd.dmg.etype == .poison) {
                    self.applyEffect(c, ls, .{ .poison_dot = .{ .target_guid = target.guid, .skill_id = skill_id, .level = c.build.book(&self.skills.?).get(skill_id) } });
                    return;
                }
            }
        }

        // Cold cast: route Ice Bolt through d2-sim's elemental cast path. `sim.skill.cast` spawns the
        // skill's srvmissile with the sorc's Ice Bolt Cast (skill+synergies+cold-mastery pierce, built
        // from the client's SorcColdBuild) snapshotted on `elem_cast`; the missile is caster_derived so
        // stepMissiles resolves its on-hit per victim via missile.applyElementalHitVs (the VICTIM's
        // coldresist minus the pierce). No inline skill/missile logic here — the host only allocs a
        // guid + appends. A bolt still cannot reach a mob behind a wall (LoS enforced in stepMissiles).
        // ANY elemental missile skill (Ice Bolt, Fire Bolt, Charged Bolt, Frozen Orb, ...) now
        // resolves through the generic table-driven castElemental — element + synergies + the matching
        // mastery, built from the char's SkillBook — not just Ice Bolt. Non-elemental / non-missile
        // skills fall back to execute (flat missile / melee) as before.
        // Nova / Frost Nova / Poison Nova (srvdofunc 22): a radial missile spray, NOT an area sweep —
        // spawn the faithful 64-missile ring of the skill's srvmissilea outward from the caster, each
        // carrying the skill's elemental cast (resolved per victim on hit). One guid per missile.
        if (self.skills.?.byId(skill_id)) |sdd| {
            if (sdd.doFunc() == .nova_frost_nova and sdd.dmg.etype != .none) { // elemental Nova ring; Howl (no element) falls through to the fear branch
                var syn: [sim.spell.MAX_SYNERGIES]sim.spell.Synergy = undefined;
                const book = c.build.book(&self.skills.?);
                const cst = sim.skill.castElemental(&self.skills.?, book, skill_id, book.get(skill_id), &syn);
                var ring: [64]sim.Missile = undefined;
                const n = sim.skill.castRadialMissiles(&self.skills.?, &self.missile_data.?, c.player_guid, skill_id, caster.x, caster.y, 64, cst, &ring);
                for (ring[0..n]) |m| {
                    var mm = m;
                    mm.guid = self.allocGuid();
                    ls.missiles.append(self.gpa, mm) catch {};
                }
                return;
            }
        }

        // Crowd-control / utility skills with no bespoke branch. CC (Cloak of Shadows 47, Mind Blast 51,
        // Attract 59, Confuse 61, Taunt 71, Conversion 79) briefly STUN the affected hostile(s) — a
        // faithful-enough disable (the exact blind / convert / taunt / random-target semantics are
        // refinements); the AoE ones stun every hostile in reach of the cast point. Pure utility
        // (Unsummon 4, Telekinesis 21, Find Potion 69, Find Item 72) is acknowledged as a no-op.
        if (self.skills) |*sk| {
            if (sk.byId(skill_id)) |sdd| {
                switch (sdd.doFunc()) {
                    .cloak_of_shadows, .mind_blast, .attract, .confuse, .taunt, .conversion => {
                        var ebuf: [4]sim.effect.Effect = undefined;
                        const book = c.build.book(sk);
                        for (sim.skill.resolve(sk, book, skill_id, caster.x, caster.y, target.x, target.y, target.guid, &ebuf)) |e| self.applyEffect(c, ls, e);
                        return;
                    },
                    .remove_pet_by_skill_param, .telekinesis, .find_potion, .find_item => return, // utility no-op
                    else => {},
                }
            }
        }

        // Generic damage fallback for any remaining skill with a hostile target and no bespoke branch:
        // a `.direct` (elemental, no missile) applies its element in a 1-tile burst on the target; a
        // physical `.other` lands a weapon strike. Ports the long tail of damage srvdofuncs (Inferno,
        // Shock Field, Blade Fury, …) — exact geometry / secondary effects are refinements.
        if (self.skills.?.byId(skill_id)) |sdd| {
            const k = sdd.kind();
            if ((k == .direct or k == .other) and target.guid != 0) {
                if (ls.units.getPtr(target.guid)) |tu| {
                    if (sim.select.isHostileMonster(tu)) {
                        const book = c.build.book(&self.skills.?);
                        const lvl = book.get(skill_id);
                        if (sdd.dmg.etype != .none) {
                            var one = [_]*sim.Unit{tu};
                            _ = sim.skill.castDirectAreaElemental(&self.skills.?, book, skill_id, lvl, tu.x, tu.y, 1, &one, &self.combat_seed);
                        } else {
                            const r = sim.combat.resolveAttack(caster, tu, &self.combat_seed, .{ .defender_block_factor = 0 });
                            if (r.hit) sim.combat.applyToLife(tu, r.damage);
                        }
                        return;
                    }
                }
            }
        }

        const sd = self.skills.?.byId(skill_id);
        const is_elem_missile = sd != null and sd.?.dmg.etype != .none and sd.?.srvmissile.len != 0;
        var elem_cst: sim.spell.Cast = undefined;
        var have_cst = false;
        const outcome = if (is_elem_missile) blk: {
            var syn: [sim.spell.MAX_SYNERGIES]sim.spell.Synergy = undefined;
            const book = c.build.book(&self.skills.?);
            elem_cst = sim.skill.castElemental(&self.skills.?, book, skill_id, book.get(skill_id), &syn).seal(); // seal while syn is alive
            have_cst = true;
            break :blk sim.skill.cast(&self.skills.?, &self.missile_data.?, caster, skill_id, st, elem_cst);
        } else sim.skill.execute(&self.skills.?, &self.missile_data.?, caster, skill_id, st, &self.combat_seed);

        // Lib applies the melee arm (pure life mutation) and RETURNS any missile to spawn; the
        // host owns guid allocation + the missile collection.
        if (sim.skill.applyOutcome(outcome, tgt_unit)) |m| {
            var mm = m;
            mm.guid = self.allocGuid();
            // Frozen Orb & other pSrvDoFunc-15 EMITTERS: register a per-frame sub-missile emitter on the
            // orb's guid — it spawns SubMissile1 in a ring direction that rotates by Param2 each shot.
            if (have_cst) {
                if (self.missile_data.?.byName(sd.?.srvmissile)) |md| {
                    if ((md.srv_do_func == 15 or md.srv_do_func == 10) and md.sub_missile1.len != 0) {
                        const bk = c.build.book(&self.skills.?);
                        const el = bk.get(skill_id);
                        // func 15 (Frozen Orb): interval = missile Param1, 1 rotating shot. func 10
                        // (Blizzard/Hydra): interval = skill calc[1], count = skill calc[0] random shots.
                        var es = EmitterState{
                            .func = md.srv_do_func,
                            .owner = caster.unit_id,
                            .cast = elem_cst,
                            .rotate = md.param2,
                            .interval = if (md.srv_do_func == 15) @max(1, md.param1) else @max(1, self.skills.?.evalCalc(bk, 0, skill_id, el, "calc2")),
                            .count = if (md.srv_do_func == 10) @max(1, self.skills.?.evalCalc(bk, 0, skill_id, el, "calc1")) else 1,
                        };
                        const nlen = @min(md.sub_missile1.len, es.sub.len);
                        @memcpy(es.sub[0..nlen], md.sub_missile1[0..nlen]);
                        es.sub_len = @intCast(nlen);
                        ls.emitters.put(self.gpa, mm.guid, es) catch {};
                    }
                }
            }
            ls.missiles.append(self.gpa, mm) catch {};
        }
    }

    /// The result of a teleport attempt (for tests + logging).
    pub const TeleportResult = enum { moved, blocked, out_of_range, no_mana };

    /// Apply a Teleport cast: reposition `caster` to (tx,ty) instantly IF the destination cell is
    /// passable, within TELEPORT_RANGE of the caster, and the caster has the mana. Walls/monsters
    /// between the caster and the destination are IGNORED (the real skill jumps over them) — only
    /// the DESTINATION must be a walkable subtile. On success the mana is deducted and the unit is
    /// flagged `moved` so the next diff streams a ReassignPlayer (the client sees the jump).
    /// Returns why the cast was rejected, or `.moved`.
    fn tryTeleport(self: *GameInstance, ls: *LevelState, caster: *sim.Unit, guid: u32, tx: i32, ty: i32) TeleportResult {
        // Range gate: Skills.txt Teleport range=none, so the cap is the client-side on-screen reach
        // (TELEPORT_RANGE). Chebyshev/straight-line distance in subtiles from the caster.
        const dx = tx - caster.x;
        const dy = ty - caster.y;
        if (dx * dx + dy * dy > TELEPORT_RANGE * TELEPORT_RANGE) return .out_of_range;

        // Resolve a passable LANDING near the requested cell. D2's teleport lands the unit on the
        // nearest walkable subtile to the clicked point (the client's landing validation + server
        // adjust); a click on a wall/corner snaps to the closest open cell rather than failing.
        // GetFreeCoordinates is exactly that search, and it reads the live map — so a cell another
        // unit is standing on is not a landing. Nothing free within the budget blocks the cast.
        if (ls.level == null) return .blocked;
        const landing = ls.freeNear(tx, ty, PLAYER_MASK, TELEPORT_LANDING_RADIUS) orelse return .blocked;

        // Mana gate: read the per-cast cost from the table-driven Skills.txt Teleport row.
        const cost = if (self.skills) |*sk| (sk.byId(SKILL_TELEPORT) orelse return .no_mana).manaCost() else return .no_mana;
        if (caster.get(.mana) < cost) return .no_mana;
        caster.set(.mana, caster.get(.mana) - cost);

        // Instant reposition — ignore intervening walls/monsters, snap straight to the landing.
        caster.x = landing.x;
        caster.y = landing.y;
        ls.moved.put(self.gpa, guid, {}) catch {};
        return .moved;
    }

    /// Radius over which a teleport landing snaps to the nearest walkable subtile (world subtiles).
    const TELEPORT_LANDING_RADIUS: i32 = 8;

    fn ensureSkillTables(self: *GameInstance) !void {
        if (self.skills != null) return;
        var sk = try sim.Skills.load(self.gpa);
        errdefer sk.deinit();
        const md = try sim.Missiles.load(self.gpa);
        self.skills = sk;
        self.missile_data = md;
        self.buff_ctx = try sim.buff.BuffContext.load(self.gpa);
    }

    /// Load the MonLvl-scaled combat table once (AC/AR/attack damage per class+monlvl+diff).
    fn ensureMonCombat(self: *GameInstance) !void {
        if (self.mon_combat != null) return;
        self.mon_combat = try sim.MonCombatTables.load(self.gpa);
    }

    // --- missiles -----------------------------------------------------------

    /// Host-side missile policy for d2-sim's missile.stepAll (which owns the advance/collision/
    /// retire lifecycle). The host owns unit storage AND the collision grid, so it answers three
    /// duck-typed hooks:
    ///   target(m)      — the first live monster within the missile's collision radius (owner-safe).
    ///   blockedAt(x,y) — wall LoS from the level's path grid; a units+walls bolt dies on a blocked
    ///                    subtile so it can never reach a monster behind a wall (no wall-cheese).
    ///   applyHit(m,v)  — caster-derived on-hit damage, delegated to d2-sim's
    ///                    missile.applyElementalHitVs: it resolves the cast snapshotted on the
    ///                    missile (elem_cast) against the victim's resist (its resist for the cast's
    ///                    element minus the cast's Cold-Mastery pierce). No formula in the host.
    const HitCtx = struct {
        gi: *GameInstance,
        ls: *LevelState,

        pub fn target(self: HitCtx, m: *const sim.Missile) ?*sim.Unit {
            // Faction-aware: a missile from a HOSTILE monster hits players + pets; a missile from a
            // player or its pet hits hostile monsters. Default to player-side when the owner is unknown.
            const owner = self.ls.units.getPtr(m.owner_id);
            const monster_side = if (owner) |o| sim.select.isHostileMonster(o) else false;
            var it = self.ls.units.valueIterator();
            while (it.next()) |u| {
                const valid = if (monster_side) sim.select.isMonsterEnemy(u) else sim.select.isHostileMonster(u);
                if (valid and m.canHit(u)) return u;
            }
            return null;
        }

        pub fn blockedAt(self: HitCtx, x: i32, y: i32) bool {
            return !self.ls.passable(x, y, MISSILE_MASK);
        }

        pub fn applyHit(self: HitCtx, m: *const sim.Missile, victim: *sim.Unit) void {
            // A POISON missile (Poison Nova's ring, poison bolts) does NOT deal its damage instantly:
            // it registers a damage-over-time spread across the skill's ELen, refreshing rather than
            // stacking, ticked off by tickPoison. Every other element applies instantly on hit.
            if (sim.missile.elementalHitVs(m, victim, &self.gi.combat_seed)) |h| {
                if (h.element == .poison and h.e_len > 1) {
                    if (h.applied > 0) {
                        self.ls.poison_dots.put(self.gi.gpa, victim.unit_id, .{
                            .total = h.applied,
                            .frames = h.e_len,
                            .per_frame = @divTrunc(h.applied, h.e_len),
                        }) catch {};
                    }
                } else if (h.applied > 0) {
                    sim.combat.applyToLife(victim, h.applied);
                }
            } else if (self.ls.units.getPtr(m.owner_id)) |owner| {
                // A PHYSICAL missile (Guided Arrow, Multiple Shot arrow, a physical monster bolt) carries
                // no elemental cast: resolve it as a weapon attack from the missile's owner against the
                // unit it struck (the arrow's impact IS the attack — the owner's AR + weapon damage).
                const r = sim.combat.resolveAttack(owner, victim, &self.gi.combat_seed, .{ .defender_block_factor = 0 });
                if (r.hit) sim.combat.applyToLife(victim, r.damage);
            }
        }
    };

    /// Retarget interval (frames) for a homing missile — Missiles_SrvDoFunc_007's Param1 (default 5).
    const HOMING_RETARGET_FRAMES: u64 = 5;

    /// Frozen Orb & other pSrvDoFunc-15 emitters: every `interval` frames, spawn the emitter's SubMissile1
    /// at the orb's position in a ring direction that rotates by `rotate` each shot (the spiral of bolts).
    /// Reaped when the orb missile is gone. Faithful to Missiles_SrvDoFunc_015.
    fn stepEmitters(self: *GameInstance, ls: *LevelState) void {
        if (self.missile_data == null) return;
        var expired: [64]u32 = undefined;
        var ne: usize = 0;
        var it = ls.emitters.iterator();
        while (it.next()) |e| {
            const orb_guid = e.key_ptr.*;
            const es = e.value_ptr;
            const orb = sim.missile.find(ls.missiles.items, orb_guid) orelse {
                if (ne < expired.len) {
                    expired[ne] = orb_guid;
                    ne += 1;
                }
                continue;
            };
            if (self.tick_count % @as(u64, @intCast(@max(1, es.interval))) != 0) continue;
            const smd = self.missile_data.?.byName(es.subName()) orelse continue;
            const ox = orb.x;
            const oy = orb.y;
            if (es.func == 10) {
                // Blizzard / Hydra: drop `count` sub-missiles at random positions within `radius`.
                const span: u32 = @intCast(es.radius * 2 + 1);
                var k: i32 = 0;
                while (k < es.count) : (k += 1) {
                    const rx = @as(i32, @intCast(self.combat_seed.pick(span))) - es.radius;
                    const ry = @as(i32, @intCast(self.combat_seed.pick(span))) - es.radius;
                    var bolt = sim.Missile.create(smd, es.owner, ox + rx, oy + ry, ox + rx + 1, oy + ry, smd.min_damage, smd.max_damage);
                    bolt.caster_derived = true;
                    bolt.elem_cast = es.cast;
                    bolt.guid = self.allocGuid();
                    ls.missiles.append(self.gpa, bolt) catch {};
                }
            } else {
                // Frozen Orb: one bolt in the rotating ring direction; advance the angle by `rotate`.
                const dir = sim.skill.ringDir(@intCast(@mod(es.angle, 64)));
                var bolt = sim.Missile.create(smd, es.owner, ox, oy, ox + dir[0], oy + dir[1], smd.min_damage, smd.max_damage);
                bolt.caster_derived = true;
                bolt.elem_cast = es.cast;
                bolt.guid = self.allocGuid();
                ls.missiles.append(self.gpa, bolt) catch {};
                es.angle = @mod(es.angle + es.rotate, 64);
            }
        }
        for (expired[0..ne]) |g| _ = ls.emitters.remove(g);
    }

    fn stepMissiles(self: *GameInstance, ls: *LevelState) void {
        self.stepEmitters(ls); // Frozen Orb: emit the rotating ice bolts before advancing everything
        // Homing missiles (Guided Arrow / Bone Spirit): every HOMING_RETARGET_FRAMES, re-aim toward the
        // nearest hostile monster while it is 4..24 subtiles away (recon Missiles_SrvDoFunc_007: refresh
        // target, recalc path when GetCollisionDistance-4 < 0x15), before the standard advance.
        if (self.tick_count % HOMING_RETARGET_FRAMES == 0) {
            for (ls.missiles.items) |*m| {
                if (!m.homing) continue;
                var it = ls.units.valueIterator();
                const tgt = sim.select.nearestMatching(&it, m.x, m.y, sim.select.isHostileMonster) orelse continue;
                const dx: i64 = tgt.x - m.x;
                const dy: i64 = tgt.y - m.y;
                const d2 = dx * dx + dy * dy;
                if (d2 >= 4 * 4 and d2 <= 24 * 24) m.reaim(tgt.x, tgt.y);
            }
        }
        const surviving = sim.missile.stepAll(ls.missiles.items, &self.combat_seed, HitCtx{ .gi = self, .ls = ls });
        ls.missiles.shrinkRetainingCapacity(surviving);
    }

    // --- monster AI + combat ------------------------------------------------

    /// UNITEVENTCALLBACK_AITHINK for one monster — the per-unit callback the timer ring
    /// fires (armed at spawn via MONSTER_StartAiAndRegenTimers @0x5738d0). Picks the
    /// nearest live player and runs one aggro/approach/melee decision. TODO: fleeing,
    /// ranged/caster behaviours, packs; the self-reschedule cadence (currently every
    /// frame via the immediate list) awaits the AI-think callback's own delay.
    /// Instantly move a player to the nearest passable cell of (tx,ty) and stream it like a teleport —
    /// the reposition shared by Whirlwind / Leap / Leap Attack (the skill already paid its cost, so no
    /// range/mana gate). No-op without a grid or a passable landing.
    fn repositionPlayer(self: *GameInstance, ls: *LevelState, c: *Client, caster: *sim.Unit, tx: i32, ty: i32) void {
        const land = ls.freeNear(tx, ty, PLAYER_MASK, TELEPORT_LANDING_RADIUS) orelse return;
        caster.x = land.x;
        caster.y = land.y;
        c.x = land.x;
        c.y = land.y;
        ls.moved.put(self.gpa, c.player_guid, {}) catch {};
        var scratch: [16]u8 = undefined;
        self.queueToClient(c, (sc.ReassignPlayer{
            .unit_type = @intFromEnum(caster.unit_type),
            .guid = c.player_guid,
            .x = clampU16(caster.x),
            .y = clampU16(caster.y),
            .move_flag = 1,
        }).encode(&scratch));
    }

    /// Build a fully-statted monster unit (MonLvl-scaled HP + combat + resists + regen) for `class_id`
    /// at (x,y) in `level_id` — the shared init behind BOTH world-population spawns and summoned pets.
    /// Does not insert it or arm timers; the caller owns storage + AI arming (and sets owner_id for a
    /// pet). `unique` picks the boss HP fallback.
    fn buildMonsterUnit(self: *GameInstance, guid: u32, class_id: i32, x: i32, y: i32, level_id: u16, unique: bool) sim.Unit {
        var u = sim.Unit.init(.monster);
        u.unit_id = guid;
        u.class_id = @intCast(@max(0, class_id));
        u.x = x;
        u.y = y;
        u.set(.dexterity, 20);
        const world = &self.world.?;
        // MonLvl-scaled HP (MONSTER_CalculateLevelScaledStats 0x6538a0): faithful HP for this
        // difficulty at the AREA monster level; fall back to the class' default when the area has none.
        const mon_level: i32 = @intCast(world.monLvl(level_id, self.difficulty));
        const scaled: ?[2]i32 = if (mon_level > 0) world.monScaledHp(class_id, mon_level) else world.monBaseScaledHp(class_id);
        const maxhp: i32 = if (scaled) |s| s[1] else if (unique) 200 else 60;
        u.set(.maxhp, maxhp);
        u.setLife(u.get(.maxhp));
        // MonLvl-scaled COMBAT stats (same 0x6538a0 path): real AC / attack rating / A1 physical
        // damage for THIS monster at the area monster level; placeholder only when the lookup misses.
        const cdiff: sim.Difficulty = @enumFromInt(@intFromEnum(self.difficulty));
        u.set(.level, @max(1, mon_level));
        var got_combat = false;
        if (self.mon_combat) |*mc| {
            if (mc.scaled(class_id, mon_level, cdiff)) |combat_stats| {
                sim.combat.initMonsterStats(&u, combat_stats);
                got_combat = true;
            }
        }
        if (!got_combat) {
            u.set(.armorclass, 10);
            u.set(.tohit, 100);
            u.set(.mindamage, 1);
            u.set(.maxdamage, 3);
        }
        // The 6 MonStats elemental/physical resists (ResistProfile.fromUnit reads them for the
        // elemental damage path). 100 = immune, negatives amplify.
        if (world.monResist(class_id)) |r| {
            u.set(.damageresist, r.phys);
            u.set(.magicresist, r.magic);
            u.set(.fireresist, r.fire);
            u.set(.lightresist, r.light);
            u.set(.coldresist, r.cold);
            u.set(.poisonresist, r.poison);
        }
        // Life-regen (MONSTER_InitStats @0x573cb0): hpregen = maxhp * DamageRegen / 16.
        const regen = world.monDamageRegen(@intCast(u.class_id));
        if (regen > 0) u.set(.hpregen, @divTrunc(u.get(.maxhp) * regen, 16));
        return u;
    }

    /// Spawn a summoned PET of monster `class_id` at (x,y) in `ls`, owned by `owner_guid` (the
    /// summoner). Gets real MonLvl-scaled stats (buildMonsterUnit); owner_id marks it a pet so it is
    /// owner-safe from the summoner's own attacks and its AI hunts hostile monsters. AI + regen timers
    /// armed like any monster. Returns the new guid.
    fn spawnPet(self: *GameInstance, ls: *LevelState, level_id: u16, class_id: i32, x: i32, y: i32, owner_guid: u32) !u32 {
        const guid = self.allocGuid();
        var u = self.buildMonsterUnit(guid, class_id, x, y, level_id, false);
        u.owner_id = owner_guid;
        try ls.units.put(self.gpa, guid, u);
        try ls.ai.put(self.gpa, guid, .{});
        ls.timers.trigger(self.gpa, guid, @intFromEnum(sim.UnitType.monster), .aithink) catch {};
        ls.timers.trigger(self.gpa, guid, @intFromEnum(sim.UnitType.monster), .statregen) catch {};
        return guid;
    }

    /// Enforce a summoner's pet cap for one summoned CLASS: if it already owns `cap` live pets of
    /// `class_id`, remove the OLDEST (lowest guid) so the new summon replaces it — faithful to D2's
    /// per-skill minion cap (skeletons roll off at the cap; a new golem replaces the old).
    fn enforcePetCap(ls: *LevelState, owner_guid: u32, class_id: u32, cap: i32) void {
        if (cap <= 0) return;
        var count: i32 = 0;
        var oldest: u32 = 0;
        var it = ls.units.iterator();
        while (it.next()) |e| {
            const u = e.value_ptr;
            if (u.owner_id == owner_guid and u.class_id == class_id and u.isAlive()) {
                count += 1;
                if (oldest == 0 or e.key_ptr.* < oldest) oldest = e.key_ptr.*;
            }
        }
        if (count >= cap and oldest != 0) {
            _ = ls.units.remove(oldest);
            _ = ls.ai.remove(oldest);
            _ = ls.poison_dots.remove(oldest);
            _ = ls.stationary.remove(oldest);
        }
    }

    /// The MonStats.AI script for a monster class, mapped to the faithful per-monster AI ports in
    /// sim.monai (`.generic` when that AI has no bespoke port yet — the baseline loop handles it).
    fn aiScript(self: *GameInstance, class_id: i32) sim.monai.Script {
        const mc = self.mon_combat orelse return .generic;
        return sim.monai.Script.fromName(mc.aiName(@intCast(@max(0, class_id))));
    }

    /// A difficulty-resolved MonStats aip param (1-based, matching aip1..aip8) for a monster class.
    fn aip(self: *GameInstance, class_id: i32, n: u8) i32 {
        const mc = self.mon_combat orelse return 0;
        const combat = mc.combat(@intCast(@max(0, class_id))) orelse return 0;
        if (n < 1 or n > 8) return 0;
        return combat.ai_params[n - 1][@intFromEnum(self.difficulty)];
    }

    /// True when a fellow monster's corpse sits within `range` subtiles of `(x,y)` — the trigger for
    /// the Fallen's flee reaction (AI_Function1_Fallen scans for a nearby dead monster, dist < 0xF).
    fn monsterCorpseWithin(self: *GameInstance, ls: *LevelState, x: i32, y: i32, range: i32) bool {
        _ = self;
        const r2: i64 = @as(i64, range) * range;
        var it = ls.corpses.keyIterator();
        while (it.next()) |cg| {
            const cu = ls.units.getPtr(cg.*) orelse continue;
            if (cu.unit_type != .monster) continue;
            const dx: i64 = cu.x - x;
            const dy: i64 = cu.y - y;
            if (dx * dx + dy * dy <= r2) return true;
        }
        return false;
    }

    /// Spawn a hostile monster of `class_id` at (x,y) in `ls` (owner unset = hostile to the player), arming
    /// its AI + regen timers. Shared by the raise/spawn AIs. Returns the new guid (0 on alloc failure).
    /// NOTE: mutates ls.units — callers MUST re-fetch any held `*Unit` afterward.
    fn spawnHostileMonster(self: *GameInstance, ls: *LevelState, level_id: u16, class_id: i32, x: i32, y: i32) u32 {
        const guid = self.allocGuid();
        const u = self.buildMonsterUnit(guid, class_id, x, y, level_id, false);
        ls.units.put(self.gpa, guid, u) catch return 0;
        ls.ai.put(self.gpa, guid, .{}) catch {};
        ls.timers.trigger(self.gpa, guid, @intFromEnum(sim.UnitType.monster), .aithink) catch {};
        ls.timers.trigger(self.gpa, guid, @intFromEnum(sim.UnitType.monster), .statregen) catch {};
        return guid;
    }

    /// Raise-the-dead step shared by FallenShaman (@0x5f1440) and GreaterMummy (@0x5f2b10): find the
    /// nearest monster corpse within `radius` subtiles (optionally only fallen, for the shaman) and, on a
    /// `chance_pct` roll, resurrect it — a fresh hostile of the corpse's class spawns at the body and the
    /// corpse is consumed. Returns true when a raise happened (the caster's turn ends there, as in the
    /// binary's return after the revive cast). NOTE: spawning mutates ls.units — do not touch the
    /// caster's `*Unit` after a true.
    fn reviveNearbyCorpse(self: *GameInstance, ls: *LevelState, caster_guid: u32, sx: i32, sy: i32, level_id: u16, radius: i32, chance_pct: i32, fallen_only: bool) bool {
        if (radius <= 0) return false;
        const r2: i64 = @as(i64, radius) * radius;
        var best: u32 = 0;
        var best_d2: i64 = std.math.maxInt(i64);
        var best_class: i32 = 0;
        var best_x: i32 = 0;
        var best_y: i32 = 0;
        var it = ls.corpses.keyIterator();
        while (it.next()) |cg| {
            if (cg.* == caster_guid) continue;
            const cu = ls.units.getPtr(cg.*) orelse continue;
            if (cu.unit_type != .monster) continue;
            if (fallen_only and self.aiScript(@intCast(cu.class_id)) != .fallen) continue;
            const dx: i64 = cu.x - sx;
            const dy: i64 = cu.y - sy;
            const d2 = dx * dx + dy * dy;
            if (d2 > r2 or d2 >= best_d2) continue;
            best = cg.*;
            best_d2 = d2;
            best_class = @intCast(cu.class_id);
            best_x = cu.x;
            best_y = cu.y;
        }
        if (best == 0) return false;
        if (self.combat_seed.pick(100) >= @as(u32, @intCast(@max(0, chance_pct)))) return false;
        _ = ls.corpses.remove(best);
        _ = ls.units.remove(best);
        _ = ls.ai.remove(best);
        return self.spawnHostileMonster(ls, level_id, best_class, best_x, best_y) != 0 or true;
    }

    /// Spawner step (SandMaggot / SandMaggotQueen): if the spawner owns fewer than `cap` live minions of
    /// its spawn class, emit one at its position. Returns the spawned guid, or 0 when at cap / no spawn
    /// class. The maggot keeps fighting afterward (the caller falls through to the generic loop).
    /// NOTE: on a non-zero return ls.units was mutated — re-fetch the spawner's `*Unit`.
    fn spawnerEmit(self: *GameInstance, ls: *LevelState, sx: i32, sy: i32, class_id: i32, level_id: u16) u32 {
        const mc = self.mon_combat orelse return 0;
        const combat = mc.combat(@intCast(@max(0, class_id))) orelse return 0;
        const minion_class: i32 = if (combat.spawn >= 0) combat.spawn else combat.minion[0];
        if (minion_class < 0) return 0;
        const cap = self.aip(class_id, 1); // aip1 = live-minion cap
        var count: i32 = 0;
        var it = ls.units.valueIterator();
        while (it.next()) |u| {
            if (u.unit_type == .monster and u.isAlive() and u.class_id == @as(u32, @intCast(minion_class))) count += 1;
        }
        if (!sim.monai.spawnerUnderCap(count, cap)) return 0;
        return self.spawnHostileMonster(ls, level_id, minion_class, sx, sy);
    }

    /// Baal (AI_Function1_BaalCrab, action 0xf) keeps ONE clone up: a hostile "baalclone" with a third
    /// of Baal's HP. Spawns when Baal has a target and no clone is currently alive. Returns true when a
    /// clone was spawned (ls.units mutated — do not touch `m` after). Only the true Baal clones (the
    /// BaalCrabClone AI does not recurse). Resolving the clone class uses the engine (Expansion-removed)
    /// id so it lines up with buildMonsterUnit.
    fn baalSpawnClone(self: *GameInstance, ls: *LevelState, m: *sim.Unit, guid: u32) bool {
        _ = guid;
        const mc = self.mon_combat orelse return false;
        if (!std.ascii.eqlIgnoreCase(mc.aiName(@intCast(@max(0, m.class_id))), "BaalCrab")) return false;
        if (self.baal_clone_class == -2) {
            self.baal_clone_class = if (sim.skill.monClassByName(self.gpa, "baalclone")) |c| @intCast(c) else -1;
        }
        const clone_class = self.baal_clone_class;
        if (clone_class < 0) return false;
        // One clone at a time — the cap is the throttle; a new one only after the old dies.
        var it = ls.units.valueIterator();
        while (it.next()) |u| {
            if (u.unit_type == .monster and u.isAlive() and u.class_id == @as(u32, @intCast(clone_class))) return false;
        }
        const clone_hp = @max(1, @divTrunc(m.get(.maxhp), 3));
        const cguid = self.spawnHostileMonster(ls, ls.level_id, clone_class, m.x + 2, m.y + 2);
        if (cguid == 0) return false;
        if (ls.units.getPtr(cguid)) |cu| {
            cu.set(.maxhp, clone_hp);
            cu.setLife(clone_hp);
        }
        return true;
    }

    /// True when this monster is the true Baal combat form (AI_Function1_BaalCrab). The clone
    /// (BaalCrabClone) is intentionally excluded so it does not recurse the weighted table.
    fn isBaalCrab(self: *GameInstance, m: *const sim.Unit) bool {
        const mc = self.mon_combat orelse return false;
        return std.ascii.eqlIgnoreCase(mc.aiName(@intCast(@max(0, m.class_id))), "BaalCrab");
    }

    /// One Baal think driven by the weighted action table (AI_Baal_SelectActionWeighted @0x5fc450):
    /// build the 16-weight array from the target's life / distance / clone count, roll it, and carry out
    /// the chosen action class — clone spawn, blink (repositions + casts, cooldown-gated), or a damaging
    /// cast. Returns true when the action consumed the turn; false lets Baal fall through to the generic
    /// approach/melee loop (the idle / conditional slots). NOTE: a clone spawn mutates ls.units — the
    /// caller must not touch `m` after a true return.
    /// The action->exact-skill mapping (nova/inferno/cold to specific Skill slots) is a documented
    /// refinement; the specific spell still comes from the existing rotation in tryMonsterCast.
    fn baalWeightedAct(self: *GameInstance, ls: *LevelState, m: *sim.Unit, guid: u32, t: *sim.Unit, dist2: i64) bool {
        const tmax = @max(1, t.get(.maxhp));
        var live_clones: i32 = 0;
        if (self.baal_clone_class >= 0) {
            var it = ls.units.valueIterator();
            while (it.next()) |u| {
                if (u.unit_type == .monster and u.isAlive() and u.class_id == @as(u32, @intCast(self.baal_clone_class))) live_clones += 1;
            }
        }
        const dist: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(dist2))));
        const ctx = sim.baal.Context{
            .target_life_pct = @intCast(@divTrunc(@as(i64, @max(0, t.life())) * 100, tmax)),
            .dist = dist,
            .clones_spawned = live_clones,
            .target_visible = true, // no server LOS model yet — treat the aggroed target as visible
            .normal_difficulty = self.difficulty == .normal,
        };
        switch (sim.baal.selectAction(ctx, &self.combat_seed)) {
            .clone => return self.baalSpawnClone(ls, m, guid), // one live clone at a time (cap in the helper)
            .teleport => {
                const ready = self.tick_count >= (ls.boss_teleport_cd.get(guid) orelse 0);
                if (!ready) return false;
                self.teleportMonsterNear(ls, m, guid, t.x, t.y);
                ls.boss_teleport_cd.put(self.gpa, guid, self.tick_count + BOSS_TELEPORT_CD) catch {};
                _ = self.tryMonsterCast(ls, m, t);
                return true;
            },
            .maul, .skill2, .skill3, .skill4, .ranged, .skill6, .skill7, .nova, .inferno, .cold => {
                return self.tryMonsterCast(ls, m, t); // false (out of range / melee-only) -> approach
            },
            .idle, .cond5, .cond7, .unused_a => return false, // fall through to the generic loop
        }
    }

    /// The Throne of Destruction (Levels.txt Id 131) — where Baal's 5 minion waves spawn.
    const THRONE_LEVEL: u16 = 131;
    /// The 5 Baal wave bosses' base monster classes (SuperUniques.txt "Baal Subject 1-5" = Colenzo /
    /// Achmel / Bartuc / Ventar / Lister). The superunique modifiers + MinGrp minion packs are a
    /// documented follow-up; this spawns the wave boss itself in sequence.
    const BAAL_WAVE_CLASSES = [sim.baal.NUM_WAVES][]const u8{
        "fallenshaman5", "unraveler5", "baalhighpriest", "venomlord", "baalminion1",
    };

    /// Drive the Throne-of-Destruction wave sequence (AI_Function1_BaalThrone @0x5ef320): spawn the next
    /// wave boss once the room is clear of live hostile monsters, and after the fifth wave bring out Baal.
    /// State lives on the LevelState (baal_wave / baal_spawned). A spawn mutates ls.units, so the room
    /// scan finishes before any spawn.
    fn driveBaalWaves(self: *GameInstance, ls: *LevelState) void {
        if (ls.level_id != THRONE_LEVEL) return;
        var alive = false;
        var it = ls.units.valueIterator();
        while (it.next()) |u| {
            if (u.isAlive() and sim.select.isHostileMonster(u)) {
                alive = true;
                break;
            }
        }
        switch (sim.baal.nextWaveAction(ls.baal_wave, alive, ls.baal_spawned)) {
            .wait, .done => {},
            .spawn_wave => |n| {
                if (sim.skill.monClassByName(self.gpa, BAAL_WAVE_CLASSES[n])) |cls|
                    _ = self.spawnHostileMonster(ls, ls.level_id, @intCast(cls), ls.entry_x + 8, ls.entry_y);
                ls.baal_wave = n + 1;
            },
            .spawn_baal => {
                if (sim.skill.monClassByName(self.gpa, "baalcrab")) |cls|
                    _ = self.spawnHostileMonster(ls, ls.level_id, @intCast(cls), ls.entry_x + 8, ls.entry_y);
                ls.baal_spawned = true;
            },
        }
    }

    /// Heal the nearest wounded fellow monster within ALLY_SUPPORT_RANGE of `(sx,sy)` by a slice of its
    /// max life — the server model of an ally-support caster's heal (Overseer/ZakarumPriest/Nihlathak).
    /// Only touches stat values, never ls.units membership, so callers' `*Unit`s stay valid.
    fn supportHealAlly(self: *GameInstance, ls: *LevelState, self_guid: u32, sx: i32, sy: i32) void {
        _ = self;
        const r2: i64 = @as(i64, ALLY_SUPPORT_RANGE) * ALLY_SUPPORT_RANGE;
        var best: ?*sim.Unit = null;
        var best_d2: i64 = std.math.maxInt(i64);
        var it = ls.units.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == self_guid) continue;
            const u = e.value_ptr;
            if (!sim.select.isHostileMonster(u)) continue; // a fellow (un-owned, live) monster
            if (u.life() >= u.get(.maxhp)) continue; // already full
            const dx: i64 = u.x - sx;
            const dy: i64 = u.y - sy;
            const d2 = dx * dx + dy * dy;
            if (d2 > r2 or d2 >= best_d2) continue;
            best = u;
            best_d2 = d2;
        }
        if (best) |u| {
            const heal = @max(1, @divTrunc(u.get(.maxhp), ALLY_HEAL_DIV));
            u.setLife(@min(u.get(.maxhp), u.life() + heal));
        }
    }

    /// Nihlathak's corpse explosion (AI_Function1_Nihlathak @0x5ee5d0 -> Skill3, srvdofunc 127
    /// @0x5d16a0): consume the nearest monster corpse within reach and blast his enemies (players +
    /// their pets) around it. The damage is the engine's corpse-explosion model — a [calc1%, calc2%]
    /// roll of the CORPSE's max life, dealt half fire / half physical inside the CE skill's
    /// `aurarangecalc` — the same binary-faithful helper the player CE uses; the corpse is consumed.
    /// The aip3 roll gate is applied only after a corpse is found (matching the binary's order).
    /// NOTE: mutates ls.units (corpse removed) — callers must not touch `m` after a true return.
    /// TODO: Nihlathak's calc[0]% self-heal of the damage dealt (srvdofunc 127) is a follow-up — it
    /// needs his Skill3 row's calc[0] resolved; the damage half is the player-facing threat.
    fn nihlathakCorpseExplode(self: *GameInstance, ls: *LevelState, m: *sim.Unit) bool {
        const sk = if (self.skills) |*s| s else return false;
        const ce_id = sk.idByName("Corpse Explosion") orelse return false;
        const corpse_guid = self.findCorpse(ls, m.x, m.y, NIH_CORPSE_RANGE) orelse return false;
        if (!sim.monai.nihlathakCorpseExplodes(true, &self.combat_seed, self.aip(@intCast(m.class_id), 3))) return false;
        const corpse = ls.units.getPtr(corpse_guid).?;
        const cx = corpse.x;
        const cy = corpse.y;
        const clvl = corpse.get(.level);
        const my_level = @max(1, m.get(.level));
        const hit = sim.skill.corpseExplosion(sk, .{}, my_level, corpse.get(.maxhp), my_level, clvl, &self.combat_seed);
        const radius = sk.evalCalc(.{}, 0, ce_id, my_level, "aurarangecalc");
        const r2: i64 = @as(i64, radius) * radius;
        const half = @divTrunc(hit.rolled, 2);
        var it = ls.units.valueIterator();
        while (it.next()) |u| {
            if (!sim.select.isMonsterEnemy(u)) continue; // players + their pets are his enemies
            const dx: i64 = u.x - cx;
            const dy: i64 = u.y - cy;
            if (dx * dx + dy * dy > r2) continue;
            const fire = sim.combat.applyDamageComponent(half, .fire, u).applied;
            const phys = sim.combat.applyDamageComponent(hit.rolled - half, .none, u).applied;
            sim.combat.applyToLife(u, fire + phys);
        }
        _ = ls.units.remove(corpse_guid);
        _ = ls.corpses.remove(corpse_guid);
        return true;
    }

    /// Detonate a suicide rusher: deal its rolled A1 damage to every enemy within SUICIDE_BLAST_RADIUS of
    /// `(bx,by)`, then kill the rusher (it dies in its own blast; sweepDeaths turns it into a corpse).
    /// Only stat/life values change (no ls.units membership churn), so callers' `*Unit`s stay valid.
    fn suicideDetonate(self: *GameInstance, ls: *LevelState, m: *sim.Unit) void {
        const min = m.get(.mindamage);
        const max = @max(min, m.get(.maxdamage));
        const r2: i64 = @as(i64, SUICIDE_BLAST_RADIUS) * SUICIDE_BLAST_RADIUS;
        var it = ls.units.valueIterator();
        while (it.next()) |u| {
            if (!sim.select.isMonsterEnemy(u)) continue;
            const dx: i64 = u.x - m.x;
            const dy: i64 = u.y - m.y;
            if (dx * dx + dy * dy > r2) continue;
            const dmg = self.combat_seed.rollBetween(min, @max(1, max));
            sim.combat.applyToLife(u, dmg);
        }
        m.setLife(0);
    }

    fn aiThinkMonster(self: *GameInstance, ls: *LevelState, guid: u32) void {
        const m = ls.units.getPtr(guid) orelse return;
        if (m.unit_type != .monster or !m.isAlive()) return;
        const st = ls.ai.getPtr(guid) orelse return;

        // A summoned PET (skeleton/golem/valkyrie) hunts the nearest HOSTILE monster; a hostile
        // monster goes after the nearest of {player, pet} — so it will engage minions between it and
        // the player rather than walk through them.
        // A FROZEN unit cannot act at all until it thaws.
        if (ls.frozen.get(guid)) |ff| {
            if (self.tick_count < ff) return;
            _ = ls.frozen.remove(guid);
        }

        const is_pet = m.isPet();

        // A FEARED hostile monster flees directly away from the nearest player until its fear wears off.
        if (!is_pet) {
            if (ls.feared.get(guid)) |end_frame| {
                if (self.tick_count < end_frame) {
                    var pit = ls.units.valueIterator();
                    if (sim.select.nearestMatching(&pit, m.x, m.y, sim.select.isLivePlayer)) |p| {
                        _ = self.moveUnitToward(ls, m, guid, m.x + (m.x - p.x), m.y + (m.y - p.y), AI_CONFIG.monster_step, false);
                    }
                    return;
                }
                _ = ls.feared.remove(guid);
            }
        }

        var vit = ls.units.valueIterator();
        const filter: *const fn (*const sim.Unit) bool = if (is_pet) &sim.select.isHostileMonster else &sim.select.isMonsterEnemy;
        const tgt = sim.select.nearestMatching(&vit, m.x, m.y, filter);

        // A stationary trap sentry never moves: it just fires its own skill at any hostile monster that
        // has come into cast range (tryMonsterCast self-gates on range), else sits idle.
        if (is_pet and ls.stationary.contains(guid)) {
            if (tgt) |t| _ = self.tryMonsterCast(ls, m, t);
            return;
        }

        // An idle pet (no enemy in sight) trails its owner so it doesn't get left behind on the level.
        if (is_pet and tgt == null) {
            if (ls.units.getPtr(m.owner_id)) |owner| {
                const dx = owner.x - m.x;
                const dy = owner.y - m.y;
                if (dx * dx + dy * dy > PET_FOLLOW_DIST * PET_FOLLOW_DIST) {
                    _ = self.moveUnitToward(ls, m, guid, owner.x, owner.y, AI_CONFIG.monster_step, false);
                }
            }
            return;
        }

        // Per-monster AI-script behavior (MonStats.AI) — faithful ports (sim.monai) layered ahead of
        // the generic loop. They add what the baseline lacks: the Fallen scatter, the shaman's revive.
        if (!is_pet) switch (self.aiScript(@intCast(m.class_id))) {
            .fallen => {
                // AI_Function1_Fallen: flee from a fellow's corpse — run directly away from the player.
                if (sim.monai.fallenShouldFlee(self.monsterCorpseWithin(ls, m.x, m.y, sim.monai.FALLEN_CORPSE_FLEE_RANGE))) {
                    var pit = ls.units.valueIterator();
                    if (sim.select.nearestMatching(&pit, m.x, m.y, sim.select.isLivePlayer)) |p| {
                        _ = self.moveUnitToward(ls, m, guid, m.x + (m.x - p.x), m.y + (m.y - p.y), AI_CONFIG.monster_step, false);
                        return;
                    }
                }
            },
            .fallen_shaman => {
                // AI_Function1_FallenShaman: resurrect a nearby dead fallen (radius aip4, chance aip1,
                // fallen corpses only). On a revive its turn ends (ls.units mutated — return).
                const cls: i32 = @intCast(m.class_id);
                if (self.reviveNearbyCorpse(ls, guid, m.x, m.y, ls.level_id, self.aip(cls, 4), self.aip(cls, 1), true)) return;
            },
            .raiser => {
                // AI_Function1_GreaterMummy: raise ANY nearby corpse (radius aip3, chance aip3). On a
                // raise its turn ends; otherwise it drops to the generic loop for its curse/approach.
                const cls: i32 = @intCast(m.class_id);
                if (self.reviveNearbyCorpse(ls, guid, m.x, m.y, ls.level_id, self.aip(cls, 3), self.aip(cls, 3), false)) return;
            },
            .spawner => {
                // AI_Function1_SandMaggot(Queen): lay a larva/egg of its spawn class up to the aip1 cap.
                // A spawn reallocates ls.units (dangling m/tgt), so end the turn there; at cap it falls
                // through to the generic loop and keeps fighting.
                if (self.spawnerEmit(ls, m.x, m.y, @intCast(m.class_id), ls.level_id) != 0) return;
            },
            .ranged_kite => {
                // Skittish ranged (QuillRat family / SkeletonBow): once the target closes inside the
                // standoff it back-pedals to reopen the gap and looses a shot, rather than meleeing;
                // at range it falls through to the generic approach+cast loop. moveUnitToward/cast
                // don't reallocate ls.units, so `m` stays valid across the step.
                if (tgt) |t| {
                    const dx = t.x - m.x;
                    const dy = t.y - m.y;
                    if (sim.monai.kiteBackpedals(dx * dx + dy * dy, RANGED_KITE_STANDOFF)) {
                        _ = self.moveUnitToward(ls, m, guid, m.x - dx, m.y - dy, AI_CONFIG.monster_step, false);
                        _ = self.tryMonsterCast(ls, m, t);
                        return;
                    }
                }
            },
            .stationary => {
                // Emplacement (tower / hydra / totem / trap / catapult): never moves — fires its
                // MonStats skill at any enemy that wanders into range, otherwise holds. tryMonsterCast
                // self-gates on range and doesn't reallocate ls.units.
                if (tgt) |t| _ = self.tryMonsterCast(ls, m, t);
                return;
            },
            .passive => return, // town / neutral NPC — no combat AI
            .boss_teleport => {
                if (tgt) |t| {
                    const dx = t.x - m.x;
                    const dy = t.y - m.y;
                    // Baal drives every think off the binary's weighted action table (clone / blink /
                    // cast / idle); the other blink bosses (Mephisto + the Uber pair) keep the simple
                    // out-of-range blink. Either path that acts ends the turn.
                    if (self.isBaalCrab(m)) {
                        if (self.baalWeightedAct(ls, m, guid, t, dx * dx + dy * dy)) return;
                    } else {
                        const ready = self.tick_count >= (ls.boss_teleport_cd.get(guid) orelse 0);
                        if (sim.monai.bossBlinks(dx * dx + dy * dy, BOSS_TELEPORT_RANGE, ready)) {
                            self.teleportMonsterNear(ls, m, guid, t.x, t.y);
                            ls.boss_teleport_cd.put(self.gpa, guid, self.tick_count + BOSS_TELEPORT_CD) catch {};
                            _ = self.tryMonsterCast(ls, m, t);
                            return;
                        }
                    }
                }
            },
            .aura_chill => {
                // Duriel Holy Freeze: stamp a chill on every enemy within aura range this think, then
                // fight through the generic loop. Only the `chilled` map is touched, so m/tgt stay valid.
                var ait = ls.units.iterator();
                while (ait.next()) |e| {
                    if (!sim.select.isMonsterEnemy(e.value_ptr)) continue;
                    const dx: i64 = e.value_ptr.x - m.x;
                    const dy: i64 = e.value_ptr.y - m.y;
                    if (sim.monai.withinRadius(dx * dx + dy * dy, AURA_CHILL_RANGE))
                        ls.chilled.put(self.gpa, e.key_ptr.*, self.tick_count + AURA_CHILL_FRAMES) catch {};
                }
            },
            .burrower => {
                // SandRaider emerge-ambush: submerged = invulnerable + untargetable and idle until the
                // dive timer lapses, then surface next to the target and strike; surfaced, it fights via
                // the generic loop and re-dives after BURROW_SURFACE_FRAMES.
                const phase_end = ls.burrow_until.get(guid) orelse 0;
                switch (sim.monai.burrowDecide(m.submerged, self.tick_count, phase_end, tgt != null)) {
                    .stay_submerged => return, // underground, invulnerable, no action
                    .surface_and_strike => {
                        m.submerged = false;
                        if (tgt) |t| {
                            self.teleportMonsterNear(ls, m, guid, t.x, t.y);
                            _ = self.tryMonsterCast(ls, m, t);
                        }
                        ls.burrow_until.put(self.gpa, guid, self.tick_count + BURROW_SURFACE_FRAMES) catch {};
                        return;
                    },
                    .dive => {
                        m.submerged = true;
                        const dur: u64 = @intCast(@max(20, self.aip(@intCast(m.class_id), 5))); // aip5 burrow duration
                        ls.burrow_until.put(self.gpa, guid, self.tick_count + dur) catch {};
                        return;
                    },
                    .fight => {}, // fall through to the generic loop while surfaced
                }
            },
            .coward => {
                // Vampire / Panther Woman: run from the target while badly wounded, else fight normally.
                if (sim.monai.cowardFlees(m.life(), m.get(.maxhp), tgt != null, COWARD_HP_PCT)) {
                    const t = tgt.?;
                    _ = self.moveUnitToward(ls, m, guid, m.x + (m.x - t.x), m.y + (m.y - t.y), AI_CONFIG.monster_step, false);
                    return;
                }
            },
            .ally_support => {
                // Overseer / ZakarumPriest / OblivionKnight / HighPriest: mend a wounded ally each
                // think, then fight through the generic loop. Only stat values change (m/tgt valid).
                self.supportHealAlly(ls, guid, m.x, m.y);
            },
            .nihlathak => {
                // AI_Function1_Nihlathak @0x5ee5d0 step 3: detonate a nearby monster corpse (Skill3 /
                // srvdofunc 127) at his enemies, gated by roll < aip3. A corpse-explode consumes the
                // corpse (ls.units mutated -> end the turn). Otherwise he mends a wounded ally like the
                // other supporters, then drops to the generic cast/melee loop.
                if (self.nihlathakCorpseExplode(ls, m)) return;
                self.supportHealAlly(ls, guid, m.x, m.y);
            },
            .suicide_rush => {
                // Charge the target; detonate on contact (damages the blast area, then dies).
                if (tgt) |t| {
                    const dx = t.x - m.x;
                    const dy = t.y - m.y;
                    if (sim.monai.suicideDetonates(dx * dx + dy * dy, SUICIDE_DETONATE_RANGE)) {
                        self.suicideDetonate(ls, m);
                    } else {
                        _ = self.moveUnitToward(ls, m, guid, t.x, t.y, AI_CONFIG.monster_step, false);
                    }
                    return;
                }
            },
            .generic => {},
        };

        switch (sim.ai.decideMonster(m, tgt, AI_CONFIG, self.tick_count, st)) {
            .idle => {},
            .approach => |a| _ = self.moveUnitToward(ls, m, guid, a.tx, a.ty, AI_CONFIG.monster_step, false),
            .attack => if (tgt) |t| {
                if (is_pet) {
                    // A caster pet (revived shaman/mage, Skeletal Mage) casts its own MonStats skill at
                    // the foe — with the missile owned by the PLAYER so it is owner-safe versus every one
                    // of the player's minions. A melee pet (skeleton warrior) falls back to a unit-vs-unit
                    // to-hit/physical swing (its MonLvl-scaled attack rating + A1 damage vs the foe).
                    if (!self.tryMonsterCast(ls, m, t)) {
                        const r = sim.combat.resolveAttack(m, t, &self.combat_seed, .{});
                        if (r.hit) sim.combat.applyToLife(t, r.damage);
                    }
                } else if (!self.tryMonsterCast(ls, m, t)) {
                    // A CASTER monster (Shaman / mage / Will-o-Wisp / ...) casts its MonStats skill at
                    // the target through the generic lib path when it has a castable damaging skill;
                    // otherwise it MELEEs through the faithful to-hit/block/physical model with the
                    // monster's MonLvl-scaled A1 attack rating; the player blocks off its BlockFactor.
                    const atk = sim.combat.monsterAttackFrom(m);
                    const bf: i32 = sim.derive.charStats(.sorceress).block_factor;
                    const res = sim.combat.resolveMonsterAttack(atk, t, &self.combat_seed, bf);
                    if (res.hit and !res.blocked) sim.combat.applyToLife(t, res.damage);
                }
            },
        }
    }

    /// Cast range for a caster monster (subtiles). Within this it casts its skill; farther, it
    /// approaches (the AI's decideMonster already gates .attack to melee range, so a caster monster
    /// close enough to "attack" casts instead of swinging).
    const MONSTER_CAST_RANGE: i32 = 24;

    /// Splash radius (subtiles) for a monster's direct-AoE cast (its nova / meteor / blizzard) — it hits
    /// every player + pet within this of the target, not only the primary target. Documented footprint.
    const MONSTER_AOE_RADIUS: i32 = 6;

    /// A pet farther than this (subtiles) from its owner, with no enemy to fight, walks back toward it.
    const PET_FOLLOW_DIST: i32 = 6;

    /// Standoff distance (subtiles) a skittish-ranged monster (QuillRat family / SkeletonBow) tries to
    /// keep: inside this it back-pedals and shoots instead of meleeing. The binary uses per-AI hardcoded
    /// gates (SkeletonBow's 20-tile check, QuillRat's aip1 range) — this is a documented single footprint
    /// standing in for those; the ranged SHOT itself routes through the monster's real MonStats skill.
    const RANGED_KITE_STANDOFF: i32 = 10;

    /// A teleporting boss (Mephisto / Baal) blinks to the target when it is farther than this (subtiles).
    /// Mephisto's gate is dist>30 or target-behind-wall; Baal blinks ~25 units — this single reach stands
    /// in for those (the exact per-boss trigger + Skill6/Skill5 teleport-skill is documented in monai).
    const BOSS_TELEPORT_RANGE: i32 = 26;
    /// Frames between boss teleports so the blink is periodic, not every think.
    const BOSS_TELEPORT_CD: u64 = 40;
    /// Where a blinking boss lands relative to the target — this many subtiles off, on the boss's side.
    const BOSS_TELEPORT_LANDING: i32 = 4;

    /// Reach (subtiles) of Duriel's Holy-Freeze chilling aura and how long (frames) a chill lingers once
    /// out of range. The exact Holy Freeze radius lives in Skills.txt aurarange; this is a documented
    /// footprint. A chilled unit moves at half step (the graded slow the host models for the aura).
    const AURA_CHILL_RANGE: i32 = 12;
    const AURA_CHILL_FRAMES: u64 = 25;

    /// SandRaider burrow cadence (frames): how long it stays SURFACED and fighting before diving again.
    /// The submerged duration itself is the monster's aip5 (RE'd burrow duration); this is the surface
    /// window between dives (a documented footprint — the DT1 burrow/emerge animation timing isn't a
    /// clean table value on the server).
    const BURROW_SURFACE_FRAMES: u64 = 60;

    /// A `coward` monster (Vampire / Panther Woman) flees while its life is under this percent.
    const COWARD_HP_PCT: i32 = 33;
    /// Reach (subtiles) of an `ally_support` monster's heal, and how much of a wounded ally's max life it
    /// restores per think (a gradual heal aura — the exact per-skill heal lives in Skills.txt hpadd).
    const ALLY_SUPPORT_RANGE: i32 = 16;
    const ALLY_HEAL_DIV: i32 = 32;
    /// Reach (subtiles) within which Nihlathak looks for a corpse to detonate. Mirrors the codebase's
    /// player-CE corpse-search distance (SKILLS_FindNearbyCorpse uses the skill's own range on the
    /// engine; 16 is the established host value used for player Corpse Explosion / Revive).
    const NIH_CORPSE_RANGE: i32 = 16;

    /// A `suicide_rush` monster detonates when the target is within this many subtiles, dealing its melee
    /// damage to everything inside SUICIDE_BLAST_RADIUS and dying. Documented footprints (the real blast
    /// is the death-burst skill 0's radius); the damage itself is the monster's own A1 range.
    const SUICIDE_DETONATE_RANGE: i32 = 3;
    const SUICIDE_BLAST_RADIUS: i32 = 5;

    /// Blink `u` next to (tx,ty): an instant reposition landing BOSS_TELEPORT_LANDING subtiles from the
    /// target on the boss's current side, snapped to a walkable cell when the path grid knows one. Marks
    /// the unit moved so the new position is broadcast. No ls.units realloc — `u` stays valid.
    fn teleportMonsterNear(self: *GameInstance, ls: *LevelState, u: *sim.Unit, guid: u32, tx: i32, ty: i32) void {
        var dx = u.x - tx;
        const dy = u.y - ty;
        if (dx == 0 and dy == 0) dx = 1;
        const mag: f32 = @sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy)));
        const scale: f32 = @as(f32, @floatFromInt(BOSS_TELEPORT_LANDING)) / @max(1.0, mag);
        var lx = tx + @as(i32, @intFromFloat(@as(f32, @floatFromInt(dx)) * scale));
        var ly = ty + @as(i32, @intFromFloat(@as(f32, @floatFromInt(dy)) * scale));
        // Prefer a landing the boss can actually stand on; fall back onto the target's own cell.
        if (ls.level != null and !ls.passable(lx, ly, MONSTER_MASK)) {
            if (ls.freeNear(lx, ly, MONSTER_MASK, BOSS_TELEPORT_LANDING)) |free| {
                lx = free.x;
                ly = free.y;
            } else {
                lx = tx;
                ly = ty;
            }
        }
        u.x = lx;
        u.y = ly;
        ls.moved.put(self.gpa, guid, {}) catch {};
    }

    /// Footprint radius (subtiles) of a persistent ground effect (Fire Wall / Blaze / Blizzard). The
    /// exact per-effect collision width isn't a clean table value (it emerges from the segment/shard
    /// collision registration); this is a documented modest footprint — the ONLY estimated value in the
    /// ground-effect port (its damage, duration and per-frame cadence are all RE'd from the recon/data).
    const GROUND_EFFECT_RADIUS: i32 = 8;

    /// Perpendicular step (subtiles) between adjacent arrows of a missile fan (Multiple Shot / Teeth).
    /// The exact engine spread lives in SKILLS_NormalizeDirectionPerp geometry, not a column — this is a
    /// documented approximation; the projectile COUNT (calc1) is faithful.
    const MISSILE_FAN_SPACING: i32 = 3;

    /// If monster `m` has a castable damaging skill (from its MonStats Skill1..8) and `t` is within
    /// cast range, cast it through the generic lib path and apply the outcome — spawn its missile
    /// (Vampire fireball, shaman bolt) or apply its direct-elemental hit (Will-o-Wisp Chain Lightning).
    /// Returns true when a cast happened so the caller skips the melee swing.
    fn tryMonsterCast(self: *GameInstance, ls: *LevelState, m: *sim.Unit, t: *sim.Unit) bool {
        if (self.skills == null or self.missile_data == null) return false;
        const mc = self.monsterCaster(@intCast(@max(0, m.class_id)));
        // Rotate through the monster's damaging skills: multi-skill casters (act bosses, Succubus, ...)
        // cycle Skill1..N across casts instead of spamming the first. Single-skill monsters are unaffected.
        const rot = ls.cast_rotation.get(m.unit_id) orelse 0;
        const cast_id = mc.pickCastableRotating(&self.skills.?, rot) orelse return false; // melee-only monster
        const dx = t.x - m.x;
        const dy = t.y - m.y;
        if (dx * dx + dy * dy > MONSTER_CAST_RANGE * MONSTER_CAST_RANGE) return false;
        // Committed to a cast this tick — advance the rotation so the next cast picks the next skill.
        ls.cast_rotation.put(self.gpa, m.unit_id, rot + 1) catch {};

        // A monster's DIRECT-AoE cast (nova / meteor / blizzard — EType, no missile) splashes onto every
        // player + pet within MONSTER_AOE_RADIUS of the target, re-resolving the element per victim — not
        // just the primary target. (Missile / single-hit casts fall through to monsterCast below.)
        if (self.skills.?.byId(cast_id)) |csd| {
            // Monster missile-RING skills (srvdofunc 99 = FireMissileRing8Dir, 106 = ring-on-target):
            // fire the srvmissilea in 8 directions from the caster; faction targeting lands them on the
            // player + pets (the recon's optional second inner ring is a refinement).
            if (csd.doFunc() == .fire_missile_ring8_dir or csd.doFunc() == .fire_missile_ring_on_target) {
                var syn: [sim.spell.MAX_SYNERGIES]sim.spell.Synergy = undefined;
                var lvl: i32 = 1;
                for (mc.ids[0..mc.count], 0..) |id, i| {
                    if (id == cast_id) lvl = mc.levels[i];
                }
                const cst = sim.skill.castElemental(&self.skills.?, mc.book, cast_id, lvl, &syn);
                var ring: [8]sim.Missile = undefined;
                const n = sim.skill.castRadialMissiles(&self.skills.?, &self.missile_data.?, m.unit_id, cast_id, m.x, m.y, 8, cst, &ring);
                for (ring[0..n]) |rm| {
                    var x = rm;
                    x.guid = self.allocGuid();
                    ls.missiles.append(self.gpa, x) catch {};
                }
                return true;
            }
            if (csd.kind() == .direct) {
                var lvl: i32 = 1;
                for (mc.ids[0..mc.count], 0..) |id, i| {
                    if (id == cast_id) lvl = mc.levels[i];
                }
                var tgts: std.ArrayListUnmanaged(*sim.Unit) = .empty;
                defer tgts.deinit(self.gpa);
                var it = ls.units.valueIterator();
                while (it.next()) |u| {
                    if (sim.select.isMonsterEnemy(u)) tgts.append(self.gpa, u) catch {};
                }
                _ = sim.skill.castDirectAreaElemental(&self.skills.?, mc.book, cast_id, lvl, t.x, t.y, MONSTER_AOE_RADIUS, tgts.items, &self.combat_seed);
                return true;
            }
        }

        const out = sim.skill.monsterCast(&self.skills.?, &self.missile_data.?, m, mc, t, &self.combat_seed);
        switch (out) {
            .none => return false,
            .missile => |mm| {
                var x = mm;
                x.guid = self.allocGuid();
                // A pet's cast is owned by its master, so the bolt is owner-safe versus the player and
                // ALL of its minions (Missile.canHit skips units whose owner_id matches the missile's).
                if (m.isPet()) x.owner_id = m.owner_id;
                ls.missiles.append(self.gpa, x) catch {};
                return true;
            },
            else => {
                _ = sim.skill.applyOutcome(out, t); // direct-elemental / melee arm applies to the target
                return true;
            },
        }
    }

    /// Tick every active poison DoT one frame across all levels: deal its `per_frame` to the poisoned
    /// unit's life and count it down; drop the entry when it runs out (or its unit is gone/dead). A
    /// monster CAN die from poison here (life floored at 0 → normal death cleanup collects it).
    fn tickPoison(self: *GameInstance) void {
        var lit = self.levels.valueIterator();
        while (lit.next()) |lp| lp.*.tickPoison();
    }

    /// Bit in Skills.txt `aurafilter` marking an aura that targets the caster's OWN side (self / party
    /// / pets) rather than enemies. Empirically set on every ally paladin aura (Might / Concentration /
    /// Fanaticism / Defiance / Blessed Aim / Prayer / Thorns / Vigor, all `aurafilter`=73731) and clear
    /// on the enemy auras (Conviction / Holy Fire / Holy Freeze / Sanctuary). We only self-apply ally
    /// auras — an enemy aura must never debuff its own caster.
    const AURA_TARGETS_OWN_SIDE: i32 = 0x10000;

    /// Apply each paladin's active ally aura to itself every frame: refresh the aura's stats as a
    /// 2-frame buff on the caster (refresh-not-stack holds them constant while active; they lapse ~2
    /// frames after the aura stops or changes). The caster is always inside its own aura's range.
    /// Enemy-side auras (Conviction et al.) are gated out here; applying their debuff to nearby foes
    /// is a further step.
    /// Pulse every active ground effect one frame: deal its skill's staged elemental damage to hostile
    /// monsters within radius of its centre (castDirectAreaElemental, replicating the engine's per-frame
    /// hit) and reap it once past end_frame. Synergy bonuses (an empty book here) are a refinement.
    fn tickGroundEffects(self: *GameInstance) void {
        if (self.skills == null) return;
        const sk = &self.skills.?;
        var lit = self.levels.valueIterator();
        while (lit.next()) |lp| lp.*.tickGroundEffects(sk, &self.combat_seed, self.tick_count, self.gpa);
    }

    fn tickAuras(self: *GameInstance) void {
        if (self.buff_ctx == null or self.skills == null) return;
        const sk = &self.skills.?;
        const isc = &self.buff_ctx.?.isc;
        for (self.clients.items) |c| {
            if (c.active_aura == 0) continue;
            const row = sk.rowById(c.active_aura) orelse continue;
            const filter = sk.table.getInt(i32, row, "aurafilter") orelse 0;
            const ls = self.levels.get(c.level_id) orelse continue;
            const book = c.build.book(sk);
            const lvl = book.get(c.active_aura);
            if (filter & AURA_TARGETS_OWN_SIDE != 0) {
                // Ally aura (Might / Concentration / ...): self-apply to the caster.
                if (ls.units.getPtr(c.player_guid)) |u| c.buffs.apply(u, sk, isc, c.active_aura, lvl, 2);
            } else {
                // Enemy aura — up to two independent effects (Holy Freeze has both):
                const caster = ls.units.getPtr(c.player_guid) orelse continue;
                const radius = sk.evalCalc(book, 0, c.active_aura, lvl, "aurarangecalc");
                // (a) STAT penalty (Conviction resist/def, Holy Freeze slow): refresh on foes in range.
                if (sk.table.get(row, "aurastat1").len != 0) {
                    const r2: i64 = @as(i64, radius) * radius;
                    var it = ls.units.valueIterator();
                    while (it.next()) |u| {
                        if (!sim.select.isHostileMonster(u)) continue;
                        const dx: i64 = u.x - caster.x;
                        const dy: i64 = u.y - caster.y;
                        if (dx * dx + dy * dy > r2) continue;
                        const gop = ls.aura_debuffs.getOrPut(self.gpa, u.unit_id) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = .{};
                        gop.value_ptr.apply(u, sk, isc, c.active_aura, lvl, 2);
                    }
                }
                // (b) periodic elemental DAMAGE (Holy Fire/Freeze/Shock/Sanctuary). Skills_SrvDoFunc_066
                // pulses the aura's staged E* damage to every foe within aurarangecalc every `perdelay`
                // frames (SKILLS_CalcPerDelayInterval = D2GetSkillCalc(perdelay), floored at 5).
                if (sk.byId(c.active_aura)) |sd| {
                    if (sd.dmg.etype != .none) {
                        var interval = sk.evalCalc(book, 0, c.active_aura, lvl, "perdelay");
                        if (interval < 6) interval = 5;
                        if (@mod(@as(i64, @intCast(self.tick_count)), @as(i64, interval)) == 0) {
                            var tgts: std.ArrayListUnmanaged(*sim.Unit) = .empty;
                            defer tgts.deinit(self.gpa);
                            var it2 = ls.units.valueIterator();
                            while (it2.next()) |u| {
                                if (sim.select.isHostileMonster(u)) tgts.append(self.gpa, u) catch {};
                            }
                            _ = sim.skill.castDirectAreaElemental(sk, book, c.active_aura, lvl, caster.x, caster.y, radius, tgts.items, &self.combat_seed);
                        }
                    }
                }
            }
        }
        // Tick + reap enemy-aura debuffs: a monster that left every aura's range (or whose aura stopped)
        // is no longer refreshed and its penalty lapses within ~2 frames; a dead/gone unit is dropped.
        var lit = self.levels.valueIterator();
        while (lit.next()) |lp| {
            const ls = lp.*;
            var expired: [128]u32 = undefined;
            var ne: usize = 0;
            var it = ls.aura_debuffs.iterator();
            while (it.next()) |e| {
                if (ls.units.getPtr(e.key_ptr.*)) |u| {
                    e.value_ptr.tick(u, 1);
                    if (!e.value_ptr.anyActive() and ne < expired.len) {
                        expired[ne] = e.key_ptr.*;
                        ne += 1;
                    }
                } else if (ne < expired.len) {
                    expired[ne] = e.key_ptr.*;
                    ne += 1;
                }
            }
            for (expired[0..ne]) |g| _ = ls.aura_debuffs.remove(g);
        }
    }

    /// Tick every active curse one frame across all levels: count its debuff down and, on expiry (or
    /// if the cursed unit is gone/dead), lift the debuff stats and drop the entry.
    fn tickCurses(self: *GameInstance) void {
        var lit = self.levels.valueIterator();
        while (lit.next()) |lp| lp.*.tickCurses();
    }

    /// Tick every player's timed buffs one frame: count each down and, at 0, remove its stat
    /// contributions so the buff disappears. Buffs live on the Client and modify its player unit.
    fn tickBuffs(self: *GameInstance) void {
        for (self.clients.items) |c| {
            const ls = self.levels.get(c.level_id) orelse continue;
            const u = ls.units.getPtr(c.player_guid) orelse continue;
            c.buffs.tick(u, 1);
        }
    }

    /// The MonsterCaster for a monster class, built lazily off its MonStats row and cached per class.
    fn monsterCaster(self: *GameInstance, class_id: u16) sim.skill.MonsterCaster {
        if (self.monster_casters.get(class_id)) |mc| return mc;
        const mc = sim.skill.casterForClass(self.gpa, &self.skills.?, class_id);
        self.monster_casters.put(self.gpa, class_id, mc) catch {};
        return mc;
    }

    /// The next waypoint on the route from `u` to (tx,ty), in WORLD subtiles — A* over the level's
    /// live map, so the route bends around whoever is standing in the way and not just around walls.
    /// Null when there is no map, no route, or the target is out of a monster's reach.
    fn nextWaypoint(self: *GameInstance, ls: *LevelState, u: *sim.Unit, tx: i32, ty: i32, is_player: bool) ?pf.Point {
        const lv = ls.level orelse return null;
        const nv = ls.navigator(self.gpa) orelse return null;

        // PATH_BuildDirectPathToTarget (0x6492f0) refuses a target further than 99 subtiles on
        // either axis. A player still gets there: clamp an intermediate goal inside the gate and
        // re-path next frame from the new position, which is the engine's own incremental
        // navigation. A monster past the gate does not path at all — there are many of them and
        // the target is too far away to matter yet.
        var gx = tx;
        var gy = ty;
        const dx = tx - u.x;
        const dy = ty - u.y;
        if (@abs(dx) >= PATH_GATE or @abs(dy) >= PATH_GATE) {
            if (!is_player) return null;
            const denom: i32 = @intCast(@max(@abs(dx), @abs(dy)));
            gx = u.x + @divTrunc(dx * (PATH_GATE - 1), denom);
            gy = u.y + @divTrunc(dy * (PATH_GATE - 1), denom);
        }

        const mask = if (is_player) PLAYER_MASK else MONSTER_MASK;
        const pm = nv.passMapFor(mask, .point) catch return null;
        const from = lv.fromWorld(.{ .x = u.x, .y = u.y });
        const to = lv.fromWorld(.{ .x = gx, .y = gy });
        self.path_buf.clearRetainingCapacity();
        self.pather.find(pm, from.x, from.y, to.x, to.y, .{
            // A node budget rather than best-effort: an unreachable or too-expensive target falls
            // back to straight-line stepping, which at least keeps the unit moving, instead of
            // walking it confidently into the closest reachable dead end.
            .max_nodes = if (is_player) PLAYER_PATH_NODES else MONSTER_PATH_NODES,
        }, &self.path_buf) catch return null;
        if (self.path_buf.items.len == 0) return null;
        // find() always emits the (possibly snapped) start first; the step target is what follows.
        const next = self.path_buf.items[@min(1, self.path_buf.items.len - 1)];
        return lv.toWorld(next);
    }

    /// A* expansion budget per query. A player is one unit and gets a real search; a monster is one
    /// of dozens on the level every frame and gets a cheap one.
    const PLAYER_PATH_NODES: u32 = 20_000;
    const MONSTER_PATH_NODES: u32 = 2_000;

    /// Step a unit one tick toward (tx,ty), routing around the level's collision when it has a map.
    /// Returns true once the unit has arrived at the final target. `is_player` selects the engine's
    /// player path shape (PATH_ExtendPathEndpoint), matching how D2 routes players vs. monsters.
    fn moveUnitToward(self: *GameInstance, ls: *LevelState, u: *sim.Unit, guid: u32, tx: i32, ty: i32, step_in: i32, is_player: bool) bool {
        // A CHILLED unit (Duriel Holy-Freeze aura) crawls at half step until its chill lapses.
        var step = step_in;
        if (ls.chilled.get(guid)) |end| {
            if (self.tick_count < end) step = @max(1, @divTrunc(step_in, 2)) else _ = ls.chilled.remove(guid);
        }
        var used_path = false;
        if (self.nextWaypoint(ls, u, tx, ty, is_player)) |wp| {
            if (wp.x != u.x or wp.y != u.y) {
                _ = u.stepToward(wp.x, wp.y, step);
                used_path = true;
            }
        }
        var reached = false;
        if (used_path) {
            // A* steps toward the next waypoint; snap to the final target when within
            // one step of it so the caller can retire the move.
            const dx = tx - u.x;
            const dy = ty - u.y;
            if (dx * dx + dy * dy <= step * step) {
                u.x = tx;
                u.y = ty;
                reached = true;
            }
        } else {
            reached = u.stepToward(tx, ty, step);
        }
        ls.moved.put(self.gpa, guid, {}) catch {};
        return reached;
    }

    // --- death + loot -------------------------------------------------------

    /// How long a corpse lingers before it decays (frames; ~20s at 25fps) — long enough for a
    /// Necromancer to Corpse-Explode / Revive it, matching D2's generous corpse lifetime.
    const CORPSE_TTL: i32 = 500;

    fn sweepDeaths(self: *GameInstance, ls: *LevelState) void {
        var newly: std.ArrayListUnmanaged(u32) = .empty;
        defer newly.deinit(self.gpa);
        var it = ls.units.iterator();
        while (it.next()) |e| {
            const u = e.value_ptr;
            // A newly dead monster (not yet a tracked corpse) rolls its drops once, then becomes a corpse.
            if (u.unit_type == .monster and !u.isAlive() and !ls.corpses.contains(e.key_ptr.*)) {
                newly.append(self.gpa, e.key_ptr.*) catch {};
            }
        }
        for (newly.items) |guid| {
            if (ls.units.getPtr(guid)) |u| self.rollMonsterDrops(ls, u.*);
            ls.corpses.put(self.gpa, guid, CORPSE_TTL) catch {
                // out of memory for the corpse table: fall back to the old reap-immediately behaviour
                _ = ls.units.remove(guid);
            };
            _ = ls.ai.remove(guid); // a corpse does not think
            _ = ls.targets.remove(guid);
        }

        // Age corpses; reap the ones that decayed (or whose body was already consumed/removed).
        var expired: std.ArrayListUnmanaged(u32) = .empty;
        defer expired.deinit(self.gpa);
        var cit = ls.corpses.iterator();
        while (cit.next()) |e| {
            e.value_ptr.* -= 1;
            if (e.value_ptr.* <= 0 or ls.units.getPtr(e.key_ptr.*) == null) expired.append(self.gpa, e.key_ptr.*) catch {};
        }
        for (expired.items) |guid| {
            _ = ls.units.remove(guid);
            _ = ls.corpses.remove(guid);
            _ = ls.stationary.remove(guid);
        }
    }

    /// The nearest CORPSE (a tracked dead monster) within `max_dist` subtiles of (x,y), for a
    /// corpse-consuming skill. Null if none in range.
    fn findCorpse(self: *GameInstance, ls: *LevelState, x: i32, y: i32, max_dist: i32) ?u32 {
        _ = self;
        var best: ?u32 = null;
        var best_d2: i64 = @as(i64, max_dist) * max_dist;
        var it = ls.corpses.iterator();
        while (it.next()) |e| {
            const u = ls.units.getPtr(e.key_ptr.*) orelse continue;
            const dx: i64 = u.x - x;
            const dy: i64 = u.y - y;
            const d2 = dx * dx + dy * dy;
            if (d2 <= best_d2) {
                best_d2 = d2;
                best = e.key_ptr.*;
            }
        }
        return best;
    }

    fn rollMonsterDrops(self: *GameInstance, ls: *LevelState, m: sim.Unit) void {
        self.ensureItemTables() catch {
            self.spawnGold(ls, m.x, m.y, 1);
            return;
        };
        const mlvl = @max(1, m.get(.level));
        var tc_buf: [24]u8 = undefined;
        const tc = std.fmt.bufPrint(&tc_buf, "Act {d} Equip A", .{@as(u16, self.act) + 1}) catch "Act 1 Equip A";

        var any = false;
        if (self.item_tables != null and self.tc_set != null) {
            if (items.rollDrop(self.gpa, &self.drop_seed, &self.game_seed, &self.item_tables.?, &self.tc_set.?, tc, mlvl, .{})) |drops| {
                defer self.gpa.free(drops);
                for (drops) |d| {
                    switch (d.kind) {
                        .gold => self.spawnGold(ls, m.x, m.y, d.quantity),
                        .item, .quiver => self.spawnItemDrop(ls, m.x, m.y, d),
                        else => continue,
                    }
                    any = true;
                }
            } else |_| {}
        }
        if (!any) self.spawnGold(ls, m.x, m.y, 1); // placeholder pile when the roll failed
    }

    fn spawnGold(self: *GameInstance, ls: *LevelState, x: i32, y: i32, amount: i32) void {
        ls.ground_items.append(self.gpa, .{ .guid = self.allocGuid(), .x = x, .y = y, .code = .{ 'g', 'l', 'd', 0 }, .is_gold = true, .quantity = @max(1, amount) }) catch {};
    }
    fn spawnItem(self: *GameInstance, ls: *LevelState, x: i32, y: i32, code: [4]u8) void {
        ls.ground_items.append(self.gpa, .{ .guid = self.allocGuid(), .x = x, .y = y, .code = code }) catch {};
    }

    /// Spawn a ground item from a rolled Drop, preserving its identity (quality + affix/unique/set ids +
    /// mod seed) so a picked-up item keeps its stats through to equip. Used by the loot rolls.
    fn spawnItemDrop(self: *GameInstance, ls: *LevelState, x: i32, y: i32, d: items.Drop) void {
        var code: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(code[0..], &d.item_code);
        ls.ground_items.append(self.gpa, .{
            .guid = self.allocGuid(),
            .x = x,
            .y = y,
            .code = code,
            .quantity = @max(1, d.quantity),
            .drop = d,
        }) catch {};
    }

    fn ensureItemTables(self: *GameInstance) !void {
        if (self.item_tables != null) return;
        var t = try items.Tables.load(self.gpa);
        errdefer t.deinit();
        const set = try items.treasure.build(self.gpa, &t);
        self.item_tables = t;
        self.tc_set = set;
    }

    fn ensureShrineTables(self: *GameInstance) !void {
        if (self.shrine_tables != null) return;
        self.shrine_tables = try sim.shrines.Table.load(self.gpa);
    }

    /// Roll an item's mod stats (items.properties.rollDropStats) into `out` using its stored generation
    /// seed + Drop identity. Requires the item tables; a no-provenance item yields nothing.
    fn rolledItemStats(self: *GameInstance, out: *std.ArrayListUnmanaged(items.properties.RolledStat), si: *const StoredItem) void {
        self.ensureItemTables() catch return;
        const t = if (self.item_tables) |*tt| tt else return;
        var seed = items.rng.Seed.fromValue(si.item_seed);
        items.properties.rollDropStats(self.gpa, out, &seed, t, &si.drop) catch {};

        // Base-type fixed stats: armor rolls its defense in [minac,maxac] (ISC id 31) and carries its
        // base durability (73 max / 72 current); weapons carry durability (their base damage is a grouped
        // stat — a documented follow-up). Rolled off the SAME item seed so display + equip agree.
        const code = std.mem.sliceTo(&si.code, 0);
        if (t.itemRef(code)) |ref| {
            const tbl = t.itemTable(ref.table);
            switch (ref.table) {
                .armor => {
                    const lo: i32 = @intCast(tbl.int(ref.row, "minac"));
                    const hi: i32 = @intCast(tbl.int(ref.row, "maxac"));
                    const ac: i32 = if (hi > lo) lo + @as(i32, @intCast(seed.pick(@intCast(hi - lo + 1)))) else lo;
                    out.append(self.gpa, .{ .stat = 31, .value = ac }) catch {};
                    self.appendDurability(out, tbl, ref.row);
                },
                .weapons => self.appendDurability(out, tbl, ref.row),
                .misc => {},
            }
        }
    }

    fn appendDurability(self: *GameInstance, out: *std.ArrayListUnmanaged(items.properties.RolledStat), tbl: *const items.txt.Table, row: usize) void {
        const dur: i32 = @intCast(tbl.int(row, "durability"));
        if (dur <= 0) return; // indestructible base (e.g. rings/amulets don't reach here)
        out.append(self.gpa, .{ .stat = 73, .value = dur }) catch {}; // maxdurability
        out.append(self.gpa, .{ .stat = 72, .value = dur }) catch {}; // current durability
    }

    /// Add (`add`) or remove an item's rolled mod stats on a player unit — the equip/unequip stat effect.
    /// Deterministic: the same item_seed reproduces the same stats, so an unequip exactly reverses the
    /// equip. Stat ids are ItemStatCost ids applied straight into the unit's StatList (bounds-checked).
    fn applyItemMods(self: *GameInstance, player: *sim.Unit, si: *const StoredItem, add: bool) void {
        var stats: std.ArrayListUnmanaged(items.properties.RolledStat) = .empty;
        defer stats.deinit(self.gpa);
        self.rolledItemStats(&stats, si);
        const sign: i32 = if (add) 1 else -1;
        for (stats.items) |rs| {
            if (rs.stat < 0 or rs.stat >= 512) continue; // ISC ids fit the 512-slot StatList
            player.stats.add(@enumFromInt(@as(u16, @intCast(rs.stat))), rs.value * sign);
        }
    }

    /// Equip inventory item `guid` into BodyLocs `slot`: pull it from the grid and add its mods to the
    /// player. An occupied slot is unequipped back to the inventory first. Returns false when the item
    /// isn't carried or a needed swap can't be placed. The InteractWithBody wire command is a follow-up;
    /// this is the mechanic + stat effect that command will drive.
    fn equipItem(self: *GameInstance, c: *Client, ls: *LevelState, guid: u32, slot: u8) bool {
        var idx: ?usize = null;
        for (c.inventory.items, 0..) |it, i| {
            if (it.guid == guid) {
                idx = i;
                break;
            }
        }
        const i = idx orelse return false;
        if (c.equipped.contains(slot) and !self.unequipItem(c, ls, slot)) return false;
        const si = c.inventory.orderedRemove(i);
        c.equipped.put(self.gpa, slot, si) catch {
            c.inventory.append(self.gpa, si) catch {};
            return false;
        };
        if (ls.units.getPtr(c.player_guid)) |p| self.applyItemMods(p, &si, true);
        return true;
    }

    /// Serialize a stored/equipped item to the S->C wire bit-stream (items.wire.writeItem) into `out`,
    /// returning the byte length. Builds the wire Item from the StoredItem's Drop identity + its rolled
    /// mod stats, so the client renders it with its real affixes. `dest` is eItemLoc (3 ground / 1
    /// equipped / 0 stored); `a`,`b` are x,y for a ground item or (body_loc, 0) equipped. `out` must be
    /// zero-initialized (the bit writer ORs into it).
    fn serializeItem(self: *GameInstance, out: []u8, si: *const StoredItem, dest: u8, a: u16, b: u16) usize {
        var it = items.wire.Item{ .flags = items.wire.flag.IDENTIFIED, .version = 0x60, .dest = dest };
        it.code = si.code;
        var cl: u8 = 0;
        while (cl < 4 and si.code[cl] != 0) cl += 1;
        it.code_len = cl;
        it.ilvl = @intCast(std.math.clamp(si.drop.item_level, 0, 127));
        it.quality = @enumFromInt(@intFromEnum(si.drop.quality));
        it.prefix = si.drop.prefix_id;
        it.suffix = si.drop.suffix_id;
        it.unique_id = si.drop.unique_id;
        it.set_id = si.drop.set_id;
        if (dest == 3 or dest == 5) {
            it.on_ground = true;
            it.x = a;
            it.y = b;
        } else {
            it.body_loc = @intCast(a);
        }
        var stats: std.ArrayListUnmanaged(items.properties.RolledStat) = .empty;
        defer stats.deinit(self.gpa);
        self.rolledItemStats(&stats, si);
        for (stats.items) |rs| {
            if (it.n_stats >= items.wire.MAX_STATS or rs.stat < 0) continue;
            it.stats[it.n_stats] = .{ .id = @intCast(rs.stat), .value = rs.value };
            it.n_stats += 1;
        }
        return items.wire.writeItemInto(out, &it);
    }

    /// Unequip the item in BodyLocs `slot` back into the inventory grid, removing its mods. Returns false
    /// when the slot is empty or the inventory has no room for the item's footprint (item stays worn).
    fn unequipItem(self: *GameInstance, c: *Client, ls: *LevelState, slot: u8) bool {
        var si = c.equipped.get(slot) orelse return false;
        const spot = c.invFindSlot(si.w, si.h) orelse return false;
        if (ls.units.getPtr(c.player_guid)) |p| self.applyItemMods(p, &si, false);
        si.x = spot[0];
        si.y = spot[1];
        c.inventory.append(self.gpa, si) catch return false;
        _ = c.equipped.remove(slot);
        return true;
    }
};

// --- helpers ----------------------------------------------------------------

/// A per-frame sub-missile EMITTER (Frozen Orb, missile pSrvDoFunc 15): keyed by the parent orb's guid,
/// it spawns `sub` every `interval` frames at a ring direction that rotates by `rotate` each shot — the
/// classic spiral of ice bolts. Dropped when the orb missile expires.
/// Frozen-Orb/Blizzard/Hydra sub-missile emitter + persistent ground AoE — moved to d2-game
/// (levelstate.zig); aliased here since the host's tick logic still drives them.
const EmitterState = sim.EmitterState;
const GroundEffect = sim.GroundEffect;

/// Squared distance from point (px,py) to the segment [(ax,ay),(bx,by)] — for swept-path skills like
/// Whirlwind (a monster is hit if it lies within melee reach of the whirl line).
fn segDist2(ax: i32, ay: i32, bx: i32, by: i32, px: i32, py: i32) i64 {
    const dx: i64 = bx - ax;
    const dy: i64 = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) {
        const ex = @as(i64, px - ax);
        const ey = @as(i64, py - ay);
        return ex * ex + ey * ey;
    }
    var t = @as(i64, px - ax) * dx + @as(i64, py - ay) * dy;
    if (t < 0) t = 0 else if (t > len2) t = len2;
    const cx = @as(i64, ax) + @divTrunc(t * dx, len2);
    const cy = @as(i64, ay) + @divTrunc(t * dy, len2);
    const ex = @as(i64, px) - cx;
    const ey = @as(i64, py) - cy;
    return ex * ex + ey * ey;
}

/// The town level id for an act (0-based act) — Town Portal's destination.
fn townLevelForAct(act: u8) u16 {
    return switch (act) {
        0 => 1, // Rogue Encampment
        1 => 40, // Lut Gholein
        2 => 75, // Kurast Docks
        3 => 103, // Pandemonium Fortress
        else => 109, // Harrogath
    };
}

fn clampU16(v: i32) u16 {
    if (v < 0) return 0;
    if (v > 0xFFFF) return 0xFFFF;
    return @intCast(v);
}

fn inRange(ax: i32, ay: i32, bx: i32, by: i32) bool {
    const dx = ax - bx;
    const dy = ay - by;
    return dx * dx + dy * dy <= VIEW_RADIUS * VIEW_RADIUS;
}

/// Size a C->S packet by opcode. Thin wrapper over `cs.sizeOf`, which mirrors the 1.14d engine's
/// authoritative incoming size table (`NET_D2GS_CLIENT_OUTGOING_SIZE`) byte-exact — every opcode the
/// real client can send in the 0x00..0x70 range (plus the 0xFF control packet) is sized, including
/// the variable-length ones (0x14/0x15 chat, 0x66, 0x6C). Returns null if the full packet isn't
/// present yet, 0 for a genuinely unknown/unframeable opcode (desync).
pub fn csPacketSize(buf: []const u8) ?usize {
    return cs.sizeOf(buf);
}

fn actStartLevel(act: u8) u16 {
    return switch (act) {
        0 => 1, // Rogue Encampment
        1 => 40, // Lut Gholein
        2 => 75, // Kurast Docks
        3 => 103, // Pandemonium Fortress
        4 => 109, // Harrogath
        else => 1,
    };
}

// --- tests ------------------------------------------------------------------

test "load act encodes the seed byte-exact" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0xDEADBEEF, 0, .normal);
    defer gi.deinit();
    var buf: [sc.LoadAct.SIZE]u8 = undefined;
    const bytes = gi.encodeLoadAct(&buf);
    try std.testing.expectEqual(@as(usize, 12), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x03), bytes[0]);
    const rt = try sc.LoadAct.decode(bytes);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), rt.map_seed);
    try std.testing.expectEqual(@as(u16, 1), rt.area);
}

test "integration: the composed loop over the wire (join->see->damage->0xAB->death->drop->pickup)" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8); // Den of Evil — monster-bearing interior
    defer gi.deinit();
    _ = try gi.generateLevel();

    // A capturing S->C sink + a frame-walker that records which opcodes actually appear
    // as PROPERLY FRAMED packets (byte-scanning would false-positive on payload bytes).
    const Cap = struct {
        var buf: [256 * 1024]u8 = undefined;
        var len: usize = 0;
        fn sink(_: i32, bytes: []const u8) isize {
            const n = @min(bytes.len, buf.len - len);
            @memcpy(buf[len..][0..n], bytes[0..n]);
            len += n;
            return @intCast(bytes.len);
        }
        fn feed(bytes: []const u8) void {
            _ = sink(0, bytes);
        }
        fn reset() void {
            len = 0;
        }
        /// Walk the captured RAW stream (AF00 = compression off) by the per-opcode size table
        /// (sc.packetSize), the same way the real client demuxes; return the set of opcodes seen.
        fn seen() [256]bool {
            var s = [_]bool{false} ** 256;
            var off: usize = 0;
            while (off < len) {
                const n = sc.packetSize(buf[off..len]) orelse break;
                if (n == 0 or off + n > len) break;
                s[buf[off]] = true;
                off += n;
            }
            return s;
        }
    };
    Cap.reset();

    // Join burst (LoadAct + CreatePlayer), then a tick so the client learns its monsters. The
    // join burst goes out RAW on the wire (AF00), so feed it unframed.
    const c = try gi.addClient(-1, "", "");
    var jbuf: [1024]u8 = undefined;
    Cap.feed(gi.buildJoinPackets(c, &jbuf));
    gi.tick(&Cap.sink);
    {
        const s = Cap.seen();
        try std.testing.expect(s[sc.LoadAct.OPCODE]); // 0x03
        try std.testing.expect(s[sc.CreatePlayer.OPCODE]); // 0x59
        try std.testing.expect(s[sc.AssignMonster.OPCODE]); // 0xAC — a monster was assigned
    }

    // Pick a monster the client now knows and damage it to half — expect a 0xAB health bar.
    var mguid: u32 = 0;
    var kit = c.known.keyIterator();
    const ls = gi.levels.get(gi.level_id).?;
    while (kit.next()) |kp| {
        if (ls.units.getPtr(kp.*)) |u| if (u.unit_type == .monster) {
            mguid = kp.*;
            break;
        };
    }
    try std.testing.expect(mguid != 0);
    Cap.reset();
    {
        const m = ls.units.getPtr(mguid).?;
        m.set(.maxhp, 100);
        m.setLife(40);
    }
    gi.tick(&Cap.sink); // processUnitUpdateFlags queues 0xAB...
    gi.tick(&Cap.sink); // ...flushed at the next UpdateClients
    try std.testing.expect(Cap.seen()[sc.UnitHpPercent.OPCODE]); // 0xAB

    // Kill it — the client should get a RemoveObject, and a drop should hit the ground.
    Cap.reset();
    const items_before = ls.ground_items.items.len;
    ls.units.getPtr(mguid).?.setLife(0);
    gi.tick(&Cap.sink);
    try std.testing.expect(Cap.seen()[sc.RemoveObject.OPCODE]); // 0x0a — client removes the dying unit
    try std.testing.expect(ls.corpses.contains(mguid)); // held server-side as a corpse (for Corpse Explosion / Revive)
    try std.testing.expect(!ls.units.getPtr(mguid).?.isAlive()); // ...as a dead body, not a live target
    try std.testing.expect(ls.ground_items.items.len > items_before); // dropped loot (rolled once, on death)

    // Move the freshest drop onto the player and pick it up — it leaves the world.
    const player = ls.units.getPtr(c.player_guid).?;
    const gi_last = &ls.ground_items.items[ls.ground_items.items.len - 1];
    gi_last.x = player.x;
    gi_last.y = player.y;
    const pick_guid = gi_last.guid;
    const count_before = ls.ground_items.items.len;
    var pbuf: [16]u8 = undefined;
    _ = gi.handleCommand(c, (cs.PickUpItem{ .unit_type = 4, .guid = pick_guid }).encode(&pbuf));
    try std.testing.expectEqual(count_before - 1, ls.ground_items.items.len); // picked up
}

test "Act-1 town spawns interactable NPCs; interacting queues NpcInteract 0x28" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal); // level 1 = Rogue Encampment
    defer gi.deinit();
    const ls = try gi.generateLevel();

    // Town NPCs come from the level's DS1 presets (real positions), tracked as interactable NPCs with
    // no AI armed. The core Act-1 vendors must be among them.
    try std.testing.expect(ls.npcs.count() > 0);
    var seen_class = std.AutoHashMap(u16, void).init(gpa);
    defer seen_class.deinit();
    var it = ls.npcs.keyIterator();
    while (it.next()) |gp| {
        const u = ls.units.getPtr(gp.*).?;
        try std.testing.expect(u.unit_type == .monster);
        try std.testing.expect(!ls.ai.contains(gp.*)); // NPCs don't think
        try seen_class.put(@intCast(u.class_id), {});
    }
    const core_vendors = [_]u16{ 148, 154, 147 }; // akara, charsi, gheed
    for (core_vendors) |cid| try std.testing.expect(seen_class.contains(cid));

    // Interacting with an NPC (0x13, unit_type=monster) queues the S->C 0x28 open-menu packet.
    const c = try gi.addClient(-1, "", "");
    c.pending.clearRetainingCapacity();
    var npc_it = ls.npcs.keyIterator();
    const npc_guid = npc_it.next().?.*;
    var ibuf: [16]u8 = undefined;
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 1, .guid = npc_guid }).encode(&ibuf));
    // The sequence is 0x27 NpcInfo (opens the dialog) then 0x28 PlayerQuestInfo, both carrying the guid.
    try std.testing.expectEqual(@as(usize, sc.NpcInfo.SIZE + sc.NpcInteract.SIZE), c.pending.items.len);
    try std.testing.expectEqual(sc.NpcInfo.OPCODE, c.pending.items[0]); // 0x27 first
    try std.testing.expectEqual(npc_guid, std.mem.readInt(u32, c.pending.items[2..6], .little));
    try std.testing.expectEqual(sc.NpcInteract.OPCODE, c.pending.items[sc.NpcInfo.SIZE]); // 0x28 follows
    try std.testing.expectEqual(npc_guid, std.mem.readInt(u32, c.pending.items[sc.NpcInfo.SIZE + 2 ..][0..4], .little));
}

test "traversal: interacting with the town warp generates + moves the client to the Blood Moor" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal); // level 1 = Rogue Encampment town
    defer gi.deinit();
    const town = try gi.generateLevel();

    // The town carries an outgoing warp to the Blood Moor (id 2) — the whole world is meant
    // to be reachable from town. Without it the server would serve a single dead-end level.
    var warp_guid: u32 = 0;
    for (town.warps.items) |w| {
        if (w.dest_level == 2) warp_guid = w.guid;
    }
    try std.testing.expect(warp_guid != 0);
    try std.testing.expect(gi.levels.get(2) == null); // destination not generated yet

    const c = try gi.addClient(-1, "", "");
    try std.testing.expectEqual(@as(u16, 1), c.level_id);

    // Interact with the warp (C->S 0x13): the client should transition to the Blood Moor,
    // which is generated + populated on demand at that moment.
    var ibuf: [16]u8 = undefined;
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = warp_guid }).encode(&ibuf));

    try std.testing.expectEqual(@as(u16, 2), c.level_id); // now in the Blood Moor
    const moor = gi.levels.get(2).?; // generated on demand
    try std.testing.expect(moor.units.contains(c.player_guid)); // player carried across
    try std.testing.expect(!town.units.contains(c.player_guid)); // and left the town
}

test "monster damage broadcasts 0xAB hp% to viewers who know it, threshold-gated" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;

    // Grab a monster and make the client already know it.
    var mguid: u32 = 0;
    var it = ls.units.iterator();
    while (it.next()) |e| if (e.value_ptr.unit_type == .monster) {
        mguid = e.key_ptr.*;
        break;
    };
    try std.testing.expect(mguid != 0);
    try c.known.put(gpa, mguid, {});
    const m = ls.units.getPtr(mguid).?;
    m.set(.maxhp, 100);
    m.setLife(50); // 50% -> pct 64, delta from seed 128 is 64 (>4) -> broadcast

    gi.broadcastHpChanges(ls);
    try std.testing.expect(c.pending.items.len >= sc.UnitHpPercent.SIZE);
    const hp = try sc.UnitHpPercent.decode(c.pending.items[0..]);
    try std.testing.expectEqual(mguid, hp.guid);
    try std.testing.expectEqual(@as(u8, 64), hp.hp_pct);
    try std.testing.expectEqual(@as(u8, 64), ls.hp_pct_sent.get(mguid).?);

    // A sub-threshold change (<=4) sends nothing more.
    c.pending.clearRetainingCapacity();
    m.setLife(49); // pct 62, |62-64| = 2 <= 4
    gi.broadcastHpChanges(ls);
    try std.testing.expectEqual(@as(usize, 0), c.pending.items.len);
}

test "statRegen accumulates the <<8 hpregen delta into whole HP over frames" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    defer gi.deinit();
    var ls = LevelState{
        .level_id = 0,
        .summary = .{ .level_id = 0, .seed = 0, .difficulty = .normal, .room_count = 0, .tile_count = 0, .collision_cells = 0 },
        .entry_x = 0,
        .entry_y = 0,
    };
    defer ls.deinit(gpa);

    var u = sim.Unit.init(.monster);
    u.unit_id = 42;
    u.set(.maxhp, 100);
    u.setLife(50);
    u.set(.hpregen, 200); // 200/256 hp per frame -> a whole HP every ~2 frames

    // Frame 1: 200 acc -> 0 whole (acc 200). Frame 2: 400 -> +1 whole (acc 144).
    gi.statRegen(&ls, &u);
    try std.testing.expectEqual(@as(i32, 50), u.life());
    gi.statRegen(&ls, &u);
    try std.testing.expectEqual(@as(i32, 51), u.life());

    // Runs to the maxhp cap and stops there.
    var i: usize = 0;
    while (i < 500) : (i += 1) gi.statRegen(&ls, &u);
    try std.testing.expectEqual(@as(i32, 100), u.life());
}

/// Minimal LevelState for the monster-behavior tests below.
fn testLevelState() LevelState {
    return .{
        .level_id = 0,
        .summary = .{ .level_id = 0, .seed = 0, .difficulty = .normal, .room_count = 0, .tile_count = 0, .collision_cells = 0 },
        .entry_x = 0,
        .entry_y = 0,
    };
}

fn testPlayer(id: u32, x: i32, y: i32, hp: i32) sim.Unit {
    var u = sim.Unit.init(.player);
    u.unit_id = id;
    u.x = x;
    u.y = y;
    u.set(.maxhp, hp);
    u.setLife(hp);
    return u;
}

fn testMonster(id: u32, x: i32, y: i32, hp: i32) sim.Unit {
    var u = sim.Unit.init(.monster);
    u.unit_id = id;
    u.x = x;
    u.y = y;
    u.set(.maxhp, hp);
    u.setLife(hp);
    return u;
}

test "behavior: suicide detonation damages enemies in the blast and kills the rusher" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 2, 0, 100)); // inside blast (dist^2 = 4 <= 25)
    try ls.units.put(gpa, 2, testPlayer(2, 50, 0, 100)); // outside blast
    var m = testMonster(3, 0, 0, 40);
    m.set(.mindamage, 10);
    m.set(.maxdamage, 10); // fixed roll -> 10 damage
    gi.suicideDetonate(&ls, &m);
    try std.testing.expect(!m.isAlive()); // died in its own blast
    const near_life = ls.units.getPtr(1).?.life();
    try std.testing.expect(near_life < 100 and near_life >= 88); // took ~10 (rolled 10..12) from the blast
    try std.testing.expectEqual(@as(i32, 100), ls.units.getPtr(2).?.life()); // too far, untouched
}

test "behavior: ally support heals the nearest wounded fellow monster only" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testMonster(1, 0, 0, 100)); // the healer
    var wounded = testMonster(2, 3, 0, 100); // nearby, wounded
    wounded.setLife(50);
    try ls.units.put(gpa, 2, wounded);
    try ls.units.put(gpa, 3, testMonster(3, 4, 0, 100)); // nearby, already full
    var far = testMonster(4, 40, 0, 100); // wounded but out of range
    far.setLife(50);
    try ls.units.put(gpa, 4, far);
    gi.supportHealAlly(&ls, 1, 0, 0);
    try std.testing.expectEqual(@as(i32, 53), ls.units.getPtr(2).?.life()); // +maxhp/32 = +3
    try std.testing.expectEqual(@as(i32, 100), ls.units.getPtr(3).?.life()); // full, skipped
    try std.testing.expectEqual(@as(i32, 50), ls.units.getPtr(4).?.life()); // out of range
    // A healer at full health among only-full allies heals nobody (no wounded target).
    gi.supportHealAlly(&ls, 1, 0, 0); // heals unit 2 again (still the nearest wounded)
    try std.testing.expectEqual(@as(i32, 56), ls.units.getPtr(2).?.life());
}

test "behavior: teleport lands the boss BOSS_TELEPORT_LANDING subtiles from the target" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    var ls = testLevelState();
    defer ls.deinit(gpa);
    var m = testMonster(3, 0, 0, 100);
    gi.teleportMonsterNear(&ls, &m, 3, 40, 0); // target at (40,0); no path grid -> exact landing
    try std.testing.expectEqual(@as(i32, 40 - GameInstance.BOSS_TELEPORT_LANDING), m.x); // lands 4 short of the target
    try std.testing.expectEqual(@as(i32, 0), m.y);
    try std.testing.expect(ls.moved.contains(3)); // broadcast as moved
}

test "behavior: monsterCorpseWithin sees a monster corpse only inside the range" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    var ls = testLevelState();
    defer ls.deinit(gpa);
    var corpse = testMonster(1, 10, 0, 100); // dist 10 from origin
    corpse.setLife(0); // a corpse
    try ls.units.put(gpa, 1, corpse);
    try ls.corpses.put(gpa, 1, 500);
    try std.testing.expect(gi.monsterCorpseWithin(&ls, 0, 0, 15)); // 15 >= 10 -> seen
    try std.testing.expect(!gi.monsterCorpseWithin(&ls, 0, 0, 5)); // 5 < 10 -> not seen
    // A live unit that is not tracked as a corpse never counts.
    _ = ls.corpses.remove(1);
    try std.testing.expect(!gi.monsterCorpseWithin(&ls, 0, 0, 15));
}

test "behavior: a hostile monster approaches a nearby player (generic AI end-to-end)" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    var ls = testLevelState();
    defer ls.deinit(gpa);
    // 20 subtiles east: beyond melee_range (8) but inside aggro_radius (80) -> it approaches.
    try ls.units.put(gpa, 1, testPlayer(1, 20, 0, 100)); // the target
    try ls.units.put(gpa, 2, testMonster(2, 0, 0, 100)); // a plain hostile monster (class 0 -> generic)
    try ls.ai.put(gpa, 2, .{});
    const before_x = ls.units.getPtr(2).?.x;
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.units.getPtr(2).?.x > before_x); // stepped toward the player
    try std.testing.expect(ls.moved.contains(2)); // and was flagged for a position broadcast
}

test "behavior: a submerged burrower is skipped by hostile targeting end-to-end" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    var ls = testLevelState();
    defer ls.deinit(gpa);
    // A PET hunts the nearest hostile monster; a submerged one must be invisible to it.
    var burrower = testMonster(2, 5, 0, 100);
    burrower.submerged = true;
    try ls.units.put(gpa, 2, burrower);
    var vit = ls.units.valueIterator();
    try std.testing.expect(sim.select.nearestMatching(&vit, 0, 0, sim.select.isHostileMonster) == null);
    // Once it surfaces, it becomes a valid target again.
    ls.units.getPtr(2).?.submerged = false;
    var vit2 = ls.units.valueIterator();
    try std.testing.expect(sim.select.nearestMatching(&vit2, 0, 0, sim.select.isHostileMonster) != null);
}

/// First monster class id whose MonStats.AI maps to `script` (null if none / tables unavailable) — lets
/// the end-to-end tests below pick a REAL monster of each behavior instead of hard-coding class ids.
fn firstClassForScript(gi: *GameInstance, script: sim.monai.Script) ?i32 {
    const mc = gi.mon_combat orelse return null;
    var id: i32 = 0;
    while (id < @as(i32, @intCast(mc.mon.len))) : (id += 1) {
        if (gi.aiScript(id) == script) return id;
    }
    return null;
}

test "behavior e2e: a coward monster flees the player while badly wounded" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    const cls = firstClassForScript(&gi, .coward) orelse return; // e.g. Vampire
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 20, 0, 100)); // player to the east
    var m = testMonster(2, 0, 0, 100);
    m.class_id = @intCast(cls);
    m.setLife(10); // 10% < COWARD_HP_PCT -> flee
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.units.getPtr(2).?.x < 0); // ran AWAY from the eastern player
    // At full health the same monster does NOT flee (falls through to the generic approach).
    ls.units.getPtr(2).?.x = 0;
    ls.units.getPtr(2).?.setLife(100);
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.units.getPtr(2).?.x > 0); // approached instead
}

test "behavior e2e: a stationary monster holds position, never chasing the player" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    const cls = firstClassForScript(&gi, .stationary) orelse return; // e.g. Hydra / a turret
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 20, 0, 100));
    var m = testMonster(2, 0, 0, 100);
    m.class_id = @intCast(cls);
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expectEqual(@as(i32, 0), ls.units.getPtr(2).?.x); // did not move
    try std.testing.expect(!ls.moved.contains(2));
}

test "behavior e2e: a ranged kiter back-pedals when the player closes inside its standoff" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    const cls = firstClassForScript(&gi, .ranged_kite) orelse return; // e.g. Skeleton Archer
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 5, 0, 100)); // close: dist 5 < standoff 10
    var m = testMonster(2, 0, 0, 100);
    m.class_id = @intCast(cls);
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.units.getPtr(2).?.x < 0); // back-pedalled away from the close player
}

test "behavior e2e: a suicide rusher detonates on contact and dies" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    const cls = firstClassForScript(&gi, .suicide_rush) orelse return;
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 2, 0, 100)); // within contact range (dist 2 <= 3)
    var m = testMonster(2, 0, 0, 40);
    m.class_id = @intCast(cls);
    m.set(.mindamage, 10);
    m.set(.maxdamage, 10);
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(!ls.units.getPtr(2).?.isAlive()); // detonated + died
    try std.testing.expect(ls.units.getPtr(1).?.life() < 100); // player caught in the blast
}

test "behavior e2e: a fallen scatters from a fellow monster's corpse" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    const cls = firstClassForScript(&gi, .fallen) orelse return;
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 20, 0, 100)); // player east
    var m = testMonster(2, 0, 0, 100);
    m.class_id = @intCast(cls);
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});
    var corpse = testMonster(3, 3, 0, 100); // a fellow's body 3 subtiles away (< flee range 15)
    corpse.setLife(0);
    try ls.units.put(gpa, 3, corpse);
    try ls.corpses.put(gpa, 3, 500);
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.units.getPtr(2).?.x < 0); // scattered AWAY from the eastern player
    // Remove the corpse: no longer scared -> it approaches instead.
    _ = ls.corpses.remove(3);
    _ = ls.units.remove(3);
    ls.units.getPtr(2).?.x = 0;
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.units.getPtr(2).?.x > 0);
}

test "behavior e2e: a teleporting boss blinks to a distant player" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    const cls = firstClassForScript(&gi, .boss_teleport) orelse return; // Mephisto / Baal
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 40, 0, 100)); // 40 > BOSS_TELEPORT_RANGE (26)
    var m = testMonster(2, 0, 0, 100);
    m.class_id = @intCast(cls);
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.units.getPtr(2).?.x > 20); // blinked across the gap to the player
}

test "behavior e2e: Baal's weighted action table eventually spawns a clone" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    gi.world = drlg.World.init(gpa, 0x1, .normal) catch return; // baalSpawnClone -> buildMonsterUnit
    // Find the true Baal combat form (AI=BaalCrab), not Mephisto (the other boss_teleport monster).
    const mc = gi.mon_combat orelse return;
    var baal_cls: i32 = -1;
    var id: i32 = 0;
    while (id < @as(i32, @intCast(mc.mon.len))) : (id += 1) {
        if (std.ascii.eqlIgnoreCase(mc.aiName(@intCast(id)), "BaalCrab")) {
            baal_cls = id;
            break;
        }
    }
    if (baal_cls < 0) return;
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 3, 0, 1000)); // an adjacent target to fight
    var m = testMonster(2, 0, 0, 5000);
    m.class_id = @intCast(baal_cls);
    m.set(.level, 90);
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});

    // The clone slot carries weight ~20 while Baal has no clone; over many thinks it fires and
    // AI_Baal_SpawnClone puts a baalclone in the world. (Verifies the weighted table -> host wiring.)
    var saw_clone = false;
    var i: usize = 0;
    while (i < 600 and !saw_clone) : (i += 1) {
        gi.aiThinkMonster(&ls, 2);
        if (gi.baal_clone_class >= 0) {
            var it = ls.units.valueIterator();
            while (it.next()) |u| {
                if (u.unit_type == .monster and u.isAlive() and u.class_id == @as(u32, @intCast(gi.baal_clone_class))) {
                    saw_clone = true;
                    break;
                }
            }
        }
    }
    try std.testing.expect(saw_clone);
}

test "behavior e2e: Baal's throne spawns 5 waves in sequence, then Baal" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    gi.ensureMonCombat() catch return;
    gi.world = drlg.World.init(gpa, 0x1, .normal) catch return; // spawnHostileMonster -> buildMonsterUnit
    var ls = testLevelState();
    ls.level_id = GameInstance.THRONE_LEVEL; // Throne of Destruction
    defer ls.deinit(gpa);

    var total_spawned: usize = 0;
    // First wave: spawn it, then confirm a live wave blocks the next spawn.
    gi.driveBaalWaves(&ls);
    try std.testing.expectEqual(@as(u8, 1), ls.baal_wave);
    if (ls.units.count() > 0) { // wave 0 spawned a live boss
        total_spawned += ls.units.count();
        gi.driveBaalWaves(&ls);
        try std.testing.expectEqual(@as(u8, 1), ls.baal_wave); // blocked while the wave lives
    }
    // Waves 1..4: clear the room, then each drive spawns the next wave and advances the cursor.
    var wave: u8 = 1;
    while (wave < sim.baal.NUM_WAVES) : (wave += 1) {
        var it = ls.units.valueIterator();
        while (it.next()) |u| u.setLife(0);
        const before = ls.units.count();
        gi.driveBaalWaves(&ls);
        try std.testing.expectEqual(wave + 1, ls.baal_wave);
        if (ls.units.count() > before) total_spawned += ls.units.count() - before;
    }
    // All five waves cleared -> Baal comes out (once).
    var cit = ls.units.valueIterator();
    while (cit.next()) |u| u.setLife(0);
    try std.testing.expect(!ls.baal_spawned);
    gi.driveBaalWaves(&ls);
    try std.testing.expect(ls.baal_spawned);
    try std.testing.expect(total_spawned > 0); // waves actually spawned monsters
    // A live BaalCrab now exists.
    var found_baal = false;
    var bit = ls.units.valueIterator();
    while (bit.next()) |u| {
        if (u.isAlive() and std.ascii.eqlIgnoreCase(gi.mon_combat.?.aiName(@intCast(@max(0, u.class_id))), "BaalCrab")) found_baal = true;
    }
    try std.testing.expect(found_baal);
}

test "behavior e2e: an aura_chill boss chills a nearby enemy" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    const cls = firstClassForScript(&gi, .aura_chill) orelse return; // Duriel
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 5, 0, 100)); // within AURA_CHILL_RANGE (12)
    try ls.units.put(gpa, 3, testPlayer(3, 40, 0, 100)); // far, out of range
    var m = testMonster(2, 0, 0, 100);
    m.class_id = @intCast(cls);
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.chilled.contains(1)); // the near player is chilled
    try std.testing.expect(!ls.chilled.contains(3)); // the far one is not
}

test "behavior e2e: a burrower dives on its first think and becomes untargetable" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    const cls = firstClassForScript(&gi, .burrower) orelse return; // SandRaider / FrogDemon
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 1, testPlayer(1, 20, 0, 100));
    var m = testMonster(2, 0, 0, 100);
    m.class_id = @intCast(cls);
    try ls.units.put(gpa, 2, m);
    try ls.ai.put(gpa, 2, .{});
    gi.aiThinkMonster(&ls, 2);
    try std.testing.expect(ls.units.getPtr(2).?.submerged); // dived underground
    try std.testing.expect(!sim.select.isHostileMonster(ls.units.getPtr(2).?)); // now untargetable
}

test "behavior: a raiser resurrects a nearby corpse into a fresh hostile monster" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    gi.world = drlg.World.init(gpa, 0x1, .normal) catch return; // buildMonsterUnit needs a world
    var ls = testLevelState();
    defer ls.deinit(gpa);
    try ls.units.put(gpa, 2, testMonster(2, 0, 0, 100)); // the raiser
    var corpse = testMonster(3, 3, 0, 100); // a monster corpse nearby
    corpse.class_id = 19; // a plain monster class
    corpse.setLife(0);
    try ls.units.put(gpa, 3, corpse);
    try ls.corpses.put(gpa, 3, 500);
    // radius 20, chance 100 (always), any corpse (not fallen-only).
    const raised = gi.reviveNearbyCorpse(&ls, 2, 0, 0, 0, 20, 100, false);
    try std.testing.expect(raised);
    try std.testing.expect(!ls.corpses.contains(3)); // the body was consumed
    try std.testing.expect(!ls.units.contains(3));
    // A fresh LIVE hostile monster (not the raiser, not the old corpse) now exists.
    var live: usize = 0;
    var it = ls.units.valueIterator();
    while (it.next()) |u| {
        if (u.unit_type == .monster and u.isAlive()) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live); // the raiser + the newly raised
}

test "behavior: Nihlathak detonates a nearby corpse, damaging his enemies and consuming it" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    gi.ensureMonCombat() catch return;
    gi.world = drlg.World.init(gpa, 0x1, .normal) catch return;
    const cls = firstClassForScript(&gi, .nihlathak) orelse return; // the boss row (AI=Nihlathak)
    var ls = testLevelState();
    defer ls.deinit(gpa);

    var nih = testMonster(2, 0, 0, 500);
    nih.class_id = @intCast(cls);
    nih.set(.level, 30);
    try ls.units.put(gpa, 2, nih);
    // A monster corpse within reach of Nihlathak.
    var corpse = testMonster(3, 6, 0, 300);
    corpse.class_id = 19;
    corpse.set(.level, 10);
    corpse.setLife(0);
    try ls.units.put(gpa, 3, corpse);
    try ls.corpses.put(gpa, 3, 500);
    // A player standing on the corpse — squarely inside any blast radius.
    try ls.units.put(gpa, 4, testPlayer(4, 6, 0, 1000));
    const p_before = ls.units.getPtr(4).?.life();

    // aip3 = 80, so the explosion fires within a few rolls; drive the step directly until it does.
    var fired = false;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const m = ls.units.getPtr(2).?;
        if (gi.nihlathakCorpseExplode(&ls, m)) {
            fired = true;
            break;
        }
    }
    try std.testing.expect(fired);
    try std.testing.expect(!ls.corpses.contains(3)); // the body was consumed
    try std.testing.expect(!ls.units.contains(3));
    try std.testing.expect(ls.units.getPtr(4).?.life() < p_before); // the player took blast damage
}

test "behavior: a spawner emits its minion class, capped at aip1" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    gi.ensureSkillTables() catch return;
    gi.world = drlg.World.init(gpa, 0x1, .normal) catch return;
    const cls = firstClassForScript(&gi, .spawner) orelse return; // SandMaggot(Queen) etc.
    var ls = testLevelState();
    defer ls.deinit(gpa);
    // Emit until the cap is reached; each successful emit adds exactly one live minion.
    var emitted: usize = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (gi.spawnerEmit(&ls, 0, 0, cls, 0) != 0) emitted += 1 else break;
    }
    // A spawner class with a resolved spawn/minion column + positive cap spawns at least one and stops
    // at its cap; one whose data has no spawn column emits nothing (both are valid, non-crashing).
    if (emitted > 0) {
        try std.testing.expect(ls.units.count() == emitted); // one unit per emit
        try std.testing.expect(gi.spawnerEmit(&ls, 0, 0, cls, 0) == 0); // at cap now -> no more
    }
}

test "outdoor level spawns seeded objects" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(3); // Cold Plains — Act-1 wilderness carrying seeded shrines/objects
    defer gi.deinit();
    const ls = try gi.generateLevel();
    try std.testing.expect(ls.objects.items.len >= 1);
}

test "generate populates monsters + entry point" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 7, 0x13572468, 0, .normal);
    gi.setLevel(8); // Den of Evil (maze) — monster-bearing + generates standalone
    defer gi.deinit();
    const ls = try gi.generateLevel();
    try std.testing.expect(ls.summary.room_count >= 1);
    try std.testing.expect(ls.units.count() >= 1);
}

test "monster allocation: how many spawn in the level and where (queryable count + positions)" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 7, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    const ls = try gi.generateLevel();

    // Count the spawned monsters (not the player / pets) and their spatial spread — proving the
    // roster is placed across the level, not stacked at one point.
    var count: usize = 0;
    var minx: i32 = std.math.maxInt(i32);
    var maxx: i32 = std.math.minInt(i32);
    var miny: i32 = std.math.maxInt(i32);
    var maxy: i32 = std.math.minInt(i32);
    var it = ls.units.valueIterator();
    while (it.next()) |u| {
        if (u.unit_type != .monster or u.owner_id != sim.unit.NO_OWNER) continue;
        count += 1;
        minx = @min(minx, u.x);
        maxx = @max(maxx, u.x);
        miny = @min(miny, u.y);
        maxy = @max(maxy, u.y);
    }
    std.debug.print("\nLevel 8: {d} monsters across bbox x[{d}..{d}] y[{d}..{d}] over {d} rooms\n", .{ count, minx, maxx, miny, maxy, ls.summary.room_count });
    try std.testing.expect(count >= 3); // a real roster, not a placeholder
    try std.testing.expect(maxx > minx or maxy > miny); // spread across the area, not one cell
}

test "csPacketSize frames coord/entity/chat commands" {
    var buf: [16]u8 = undefined;
    const w = cs.WalkToLocation{ .x = 1, .y = 2 };
    try std.testing.expectEqual(@as(?usize, 5), csPacketSize(w.encode(&buf)));
    const e = cs.LeftSkillOnEntity{ .unit_type = 1, .guid = 3 };
    try std.testing.expectEqual(@as(?usize, 9), csPacketSize(e.encode(&buf)));
    try std.testing.expectEqual(@as(?usize, 0), csPacketSize(&[_]u8{0x7F}));
}

test "walk sets a target and tick moves the player toward it" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();

    const sink = struct {
        fn f(_: i32, _: []const u8) isize {
            return 0;
        }
    }.f;

    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const start_x = ls.units.getPtr(c.player_guid).?.x;

    var buf: [8]u8 = undefined;
    const walk = cs.WalkToLocation{ .x = clampU16(start_x + 1000), .y = clampU16(ls.entry_y) };
    _ = gi.handleCommand(c, walk.encode(&buf));
    try std.testing.expect(ls.targets.contains(c.player_guid));

    gi.tick(&sink);
    const new_x = ls.units.getPtr(c.player_guid).?.x;
    try std.testing.expect(new_x != start_x);
    try std.testing.expect(ls.moved.contains(c.player_guid));
}

/// A bare level for tests: `w`x`h` of open floor with nothing on it. Its origin is (0,0), so
/// level-local subtiles and world subtiles are the same coordinate — a test writes walls straight
/// into `cells` and talks about them in the same numbers it gives the units.
fn bareLevel(gpa: std.mem.Allocator, w: i32, h: i32) !drlg.Level {
    const cells = try gpa.alloc(u16, @intCast(w * h));
    @memset(cells, 0);
    errdefer gpa.free(cells);
    return drlg.Level.initBare(gpa, w, h, cells);
}

test "player routes around a wall instead of walking through it" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0, 0, .normal);
    defer gi.deinit();

    // A solid 3-wide vertical wall at x in {19,20,21} for y in [0,31], leaving a gap along the
    // bottom (y in [32,39]). A straight line from the player to the target crosses the wall at
    // y=20, so a collision-blind stepper would land ON a blocked cell; the pathfinder must
    // detour through the gap.
    const w: i32 = 40;
    var lv = try bareLevel(gpa, w, 40);
    defer lv.deinit();
    var yy: i32 = 0;
    while (yy <= 31) : (yy += 1) {
        for ([_]i32{ 19, 20, 21 }) |xx| lv.cells[@intCast(xx + yy * w)] = pf.Colbit.wall;
    }

    var ls = LevelState{
        .level_id = 0,
        .summary = .{ .level_id = 0, .seed = 0, .difficulty = .normal, .room_count = 0, .tile_count = 0, .collision_cells = 0 },
        .entry_x = 5,
        .entry_y = 20,
        .level = &lv,
    };
    defer ls.deinit(gpa);

    const guid: u32 = 1;
    var u = sim.Unit.init(.player);
    u.unit_id = guid;
    u.x = 5;
    u.y = 20;
    try ls.units.put(gpa, guid, u);

    const target_x: i32 = 35;
    const target_y: i32 = 20;

    var reached = false;
    var ticks: usize = 0;
    while (ticks < 500) : (ticks += 1) {
        const up = ls.units.getPtr(guid).?;
        if (gi.moveUnitToward(&ls, up, guid, target_x, target_y, MOVE_STEP, true)) {
            reached = true;
            break;
        }
        // The player must never occupy a blocked subtile.
        if (ls.toLocal(up.x, up.y) == null) return error.PlayerLeftGrid;
        try std.testing.expect(ls.passable(up.x, up.y, GameInstance.PLAYER_MASK));
    }

    try std.testing.expect(reached);
    const fin = ls.units.getPtr(guid).?;
    try std.testing.expectEqual(target_x, fin.x);
    try std.testing.expectEqual(target_y, fin.y);
    // Reaching the far side means it went around the bottom gap, not through the wall.
    try std.testing.expect(fin.x > 21);
}

test "Teleport moves the player to a passable in-range cell, rejects blocked/out-of-range/no-mana" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0, 0, .normal);
    defer gi.deinit();
    try gi.ensureSkillTables();

    // 60x60 grid: passable everywhere except a solid blocked block around (44,44) that is larger
    // than the teleport landing-snap radius (so a cast INTO it cannot snap out to a walkable cell).
    const w: i32 = 60;
    var lv = try bareLevel(gpa, w, 60);
    defer lv.deinit();
    var by: i32 = 30;
    while (by <= 58) : (by += 1) {
        var bx: i32 = 30;
        while (bx <= 58) : (bx += 1) lv.cells[@intCast(bx + by * w)] = pf.Colbit.wall;
    }

    var ls = LevelState{
        .level_id = 0,
        .summary = .{ .level_id = 0, .seed = 0, .difficulty = .normal, .room_count = 0, .tile_count = 0, .collision_cells = 0 },
        .entry_x = 5,
        .entry_y = 5,
        .level = &lv,
    };
    defer ls.deinit(gpa);

    const guid: u32 = 1;
    var u = sim.Unit.init(.player);
    u.unit_id = guid;
    u.x = 20;
    u.y = 10;
    u.set(.maxmana, 1000);
    u.set(.mana, 1000);
    try ls.units.put(gpa, guid, u);

    const cost = gi.skills.?.byId(SKILL_TELEPORT).?.manaCost();
    try std.testing.expect(cost > 0);

    // In-range, passable dest (20,10)->(28,15): dist^2 = 64+25 = 89 < 40^2 -> MOVED, mana deducted.
    {
        const up = ls.units.getPtr(guid).?;
        try std.testing.expectEqual(GameInstance.TeleportResult.moved, gi.tryTeleport(&ls, up, guid, 28, 15));
        try std.testing.expectEqual(@as(i32, 28), up.x);
        try std.testing.expectEqual(@as(i32, 15), up.y);
        try std.testing.expectEqual(@as(i32, 1000 - cost), up.get(.mana));
        try std.testing.expect(ls.moved.contains(guid));
    }
    // Blocked dest deep in the blocked block (44,44), in range of (28,15) but with no walkable cell
    // within the landing-snap radius: rejected, position + mana unchanged.
    {
        const up = ls.units.getPtr(guid).?;
        const before = .{ up.x, up.y, up.get(.mana) };
        try std.testing.expectEqual(GameInstance.TeleportResult.blocked, gi.tryTeleport(&ls, up, guid, 44, 44));
        try std.testing.expectEqual(before[0], up.x);
        try std.testing.expectEqual(before[1], up.y);
        try std.testing.expectEqual(before[2], up.get(.mana)); // no mana spent on a rejected cast
    }
    // Out-of-range dest (28,15)->(28,58): dy=43 > 40 -> rejected.
    {
        const up = ls.units.getPtr(guid).?;
        try std.testing.expectEqual(GameInstance.TeleportResult.out_of_range, gi.tryTeleport(&ls, up, guid, 28, 58));
        try std.testing.expectEqual(@as(i32, 28), up.x);
    }
    // No mana: drain the pool, then an otherwise-valid cast (to passable (10,20)) is rejected.
    {
        const up = ls.units.getPtr(guid).?;
        up.set(.mana, cost - 1);
        try std.testing.expectEqual(GameInstance.TeleportResult.no_mana, gi.tryTeleport(&ls, up, guid, 10, 20));
        try std.testing.expectEqual(@as(i32, 28), up.x); // unchanged
        try std.testing.expectEqual(cost - 1, up.get(.mana));
    }
}

test "inventory: picked items occupy the grid; a full inventory rejects further pickups" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const p = ls.units.getPtr(c.player_guid).?;

    // Two potions (1x1) dropped in reach; pick both up -> stored left-to-right on the top row.
    gi.spawnItem(ls, p.x, p.y + 1, .{ 'h', 'p', '1', 0 });
    gi.spawnItem(ls, p.x, p.y + 1, .{ 'h', 'p', '1', 0 });
    const g1 = ls.ground_items.items[0].guid;
    const g2 = ls.ground_items.items[1].guid;
    var buf: [16]u8 = undefined;
    _ = gi.handleCommand(c, (cs.PickUpItem{ .unit_type = 4, .guid = g1 }).encode(&buf));
    _ = gi.handleCommand(c, (cs.PickUpItem{ .unit_type = 4, .guid = g2 }).encode(&buf));
    try std.testing.expectEqual(@as(usize, 2), c.inventory.items.len);
    try std.testing.expectEqual(@as(u8, 0), c.inventory.items[0].x);
    try std.testing.expectEqual(@as(u8, 0), c.inventory.items[0].y);
    try std.testing.expectEqual(@as(u8, 1), c.inventory.items[1].x); // next free cell over
    try std.testing.expectEqual(@as(u8, 0), c.inventory.items[1].y);
    try std.testing.expectEqual(@as(usize, 0), ls.ground_items.items.len); // both left the ground

    // Fill the whole INV_W x INV_H grid, then a further pickup is REJECTED (item stays on the ground).
    c.inventory.clearRetainingCapacity();
    var yy: u8 = 0;
    while (yy < INV_H) : (yy += 1) {
        var xx: u8 = 0;
        while (xx < INV_W) : (xx += 1) {
            try c.inventory.append(gpa, .{ .guid = 9000 + @as(u32, yy) * INV_W + xx, .code = .{ 'h', 'p', '1', 0 }, .x = xx, .y = yy, .w = 1, .h = 1 });
        }
    }
    try std.testing.expect(c.invFindSlot(1, 1) == null); // grid is full
    gi.spawnItem(ls, p.x, p.y + 1, .{ 'h', 'p', '1', 0 });
    const gf = ls.ground_items.items[ls.ground_items.items.len - 1].guid;
    const ground_before = ls.ground_items.items.len;
    _ = gi.handleCommand(c, (cs.PickUpItem{ .unit_type = 4, .guid = gf }).encode(&buf));
    try std.testing.expectEqual(ground_before, ls.ground_items.items.len); // rejected: still on the ground
    try std.testing.expectEqual(gf, ls.ground_items.items[ls.ground_items.items.len - 1].guid);
}

test "equip a unique item adds its rolled stats; unequip removes them exactly" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureItemTables() catch return;
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const player = ls.units.getPtr(c.player_guid).?;

    // Find a unique whose rolled mods include at least one modeled stat.
    const seed_val: u32 = 0xABCD;
    const ut = &gi.item_tables.?.unique_items;
    var uid: u16 = 0;
    var probe: std.ArrayListUnmanaged(items.properties.RolledStat) = .empty;
    defer probe.deinit(gpa);
    for (0..ut.rowCount()) |row| {
        if (ut.int(row, "enabled") == 0) continue;
        probe.clearRetainingCapacity();
        var s = items.rng.Seed.fromValue(seed_val);
        var d = items.Drop{ .kind = .item, .quality = .unique, .unique_id = @intCast(row + 1), .item_level = 99 };
        items.properties.rollDropStats(gpa, &probe, &s, &gi.item_tables.?, &d) catch continue;
        if (probe.items.len > 0) {
            uid = @intCast(row + 1);
            break;
        }
    }
    if (uid == 0) return; // no valued unique (shouldn't happen with real data)

    // Stash it in the inventory with the SAME seed so equip reproduces those stats.
    var si = StoredItem{ .guid = gi.allocGuid(), .code = .{ 0, 0, 0, 0 }, .x = 0, .y = 0, .w = 2, .h = 2, .item_seed = seed_val };
    si.drop = .{ .kind = .item, .quality = .unique, .unique_id = uid, .item_level = 99 };
    const ucode = ut.str(uid - 1, "code");
    @memcpy(si.code[0..@min(4, ucode.len)], ucode[0..@min(4, ucode.len)]);
    try c.inventory.append(gpa, si);

    var before: [512]i32 = player.stats.values;
    try std.testing.expect(gi.equipItem(c, ls, si.guid, 3)); // torso slot
    try std.testing.expect(c.equipped.contains(3));
    try std.testing.expectEqual(@as(usize, 0), c.inventory.items.len); // left the grid
    try std.testing.expect(!std.mem.eql(i32, before[0..], player.stats.values[0..])); // stats gained

    try std.testing.expect(gi.unequipItem(c, ls, 3));
    try std.testing.expect(!c.equipped.contains(3));
    try std.testing.expectEqual(@as(usize, 1), c.inventory.items.len); // back in the grid
    try std.testing.expectEqualSlices(i32, before[0..], player.stats.values[0..]); // exact revert
}

test "serializeItem emits a wire item that parses back with its quality + stats" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureItemTables() catch return;

    // A valued unique, as a StoredItem.
    const ut = &gi.item_tables.?.unique_items;
    var uid: u16 = 0;
    var probe: std.ArrayListUnmanaged(items.properties.RolledStat) = .empty;
    defer probe.deinit(gpa);
    for (0..ut.rowCount()) |row| {
        if (ut.int(row, "enabled") == 0) continue;
        probe.clearRetainingCapacity();
        var s = items.rng.Seed.fromValue(0xABCD);
        var d0 = items.Drop{ .kind = .item, .quality = .unique, .unique_id = @intCast(row + 1), .item_level = 99 };
        items.properties.rollDropStats(gpa, &probe, &s, &gi.item_tables.?, &d0) catch continue;
        if (probe.items.len > 0) {
            uid = @intCast(row + 1);
            break;
        }
    }
    if (uid == 0) return;
    var si = StoredItem{ .guid = 1, .code = .{ 0, 0, 0, 0 }, .x = 0, .y = 0, .w = 1, .h = 1, .item_seed = 0xABCD };
    si.drop = .{ .kind = .item, .quality = .unique, .unique_id = uid, .item_level = 99 };
    const ucode = ut.str(uid - 1, "code");
    @memcpy(si.code[0..@min(4, ucode.len)], ucode[0..@min(4, ucode.len)]);

    var buf = [_]u8{0} ** 128;
    const n = gi.serializeItem(&buf, &si, 3, 10, 20); // as a ground drop
    try std.testing.expect(n > 0);
    var r = items.WireBitReader.init(buf[0..n]);
    const got = items.wire.parse(&r);
    try std.testing.expectEqual(items.wire.Quality.unique, got.quality);
    try std.testing.expectEqual(uid, got.unique_id);
    try std.testing.expect(got.on_ground and got.x == 10 and got.y == 20);
    try std.testing.expect(got.n_stats > 0); // the unique's rolled mods survived the round-trip
}

test "a rolled ground item is announced to the client as a full item bitstream (0x9C)" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureItemTables() catch return;
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const player = ls.units.getPtr(c.player_guid).?;

    // A valued unique dropped on the ground next to the player.
    const ut = &gi.item_tables.?.unique_items;
    var uid: u16 = 0;
    var probe: std.ArrayListUnmanaged(items.properties.RolledStat) = .empty;
    defer probe.deinit(gpa);
    for (0..ut.rowCount()) |row| {
        if (ut.int(row, "enabled") == 0) continue;
        probe.clearRetainingCapacity();
        var s = items.rng.Seed.fromValue(0xABCD);
        var d0 = items.Drop{ .kind = .item, .quality = .unique, .unique_id = @intCast(row + 1), .item_level = 99 };
        items.properties.rollDropStats(gpa, &probe, &s, &gi.item_tables.?, &d0) catch continue;
        if (probe.items.len > 0) {
            uid = @intCast(row + 1);
            break;
        }
    }
    if (uid == 0) return;
    var d = items.Drop{ .kind = .item, .quality = .unique, .unique_id = uid, .item_level = 99, .item_seed = 0xABCD };
    const ucode = ut.str(uid - 1, "code");
    @memcpy(d.item_code[0..@min(4, ucode.len)], ucode[0..@min(4, ucode.len)]);
    gi.spawnItemDrop(ls, player.x, player.y + 1, d);
    const item_guid = ls.ground_items.items[ls.ground_items.items.len - 1].guid;

    // The client diff announces it — its ItemAction body must be the full parseable item bitstream.
    var pw = sc.PacketWriter.init(c.outbuf);
    gi.diffClient(c, ls, &pw);
    const bytes = pw.bytes();

    var found = false;
    var pos: usize = 0;
    while (pos < bytes.len) : (pos += 1) {
        if (bytes[pos] != sc.ItemAction.OPCODE) continue;
        const ia = sc.ItemAction.decode(bytes[pos..]) catch continue;
        if (ia.guid != item_guid) continue;
        try std.testing.expect(ia.body.len > 8); // a real bitstream, not the 8-byte stub
        var r = items.WireBitReader.init(ia.body);
        const parsed = items.wire.parse(&r);
        try std.testing.expectEqual(items.wire.Quality.unique, parsed.quality);
        try std.testing.expectEqual(uid, parsed.unique_id);
        found = true;
        break;
    }
    try std.testing.expect(found);
}

test "a dropped unique keeps its identity through pickup and equips with stats" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureItemTables() catch return;
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const player = ls.units.getPtr(c.player_guid).?;

    // A valued unique for some base code.
    const seed_val: u32 = 0xABCD;
    const ut = &gi.item_tables.?.unique_items;
    var uid: u16 = 0;
    var probe: std.ArrayListUnmanaged(items.properties.RolledStat) = .empty;
    defer probe.deinit(gpa);
    for (0..ut.rowCount()) |row| {
        if (ut.int(row, "enabled") == 0) continue;
        probe.clearRetainingCapacity();
        var s = items.rng.Seed.fromValue(seed_val);
        var d0 = items.Drop{ .kind = .item, .quality = .unique, .unique_id = @intCast(row + 1), .item_level = 99 };
        items.properties.rollDropStats(gpa, &probe, &s, &gi.item_tables.?, &d0) catch continue;
        if (probe.items.len > 0) {
            uid = @intCast(row + 1);
            break;
        }
    }
    if (uid == 0) return;

    // Drop it as a ground item carrying its full identity, next to the player.
    var d = items.Drop{ .kind = .item, .quality = .unique, .unique_id = uid, .item_level = 99, .item_seed = seed_val };
    const ucode = ut.str(uid - 1, "code");
    @memcpy(d.item_code[0..@min(4, ucode.len)], ucode[0..@min(4, ucode.len)]);
    gi.spawnItemDrop(ls, player.x, player.y + 1, d);
    const g = ls.ground_items.items[ls.ground_items.items.len - 1].guid;

    var buf: [16]u8 = undefined;
    _ = gi.handleCommand(c, (cs.PickUpItem{ .unit_type = 4, .guid = g }).encode(&buf));
    try std.testing.expectEqual(@as(usize, 1), c.inventory.items.len); // picked up
    try std.testing.expectEqual(uid, c.inventory.items[0].drop.unique_id); // identity survived
    try std.testing.expectEqual(seed_val, c.inventory.items[0].item_seed);

    var before: [512]i32 = player.stats.values;
    try std.testing.expect(gi.equipItem(c, ls, g, 3));
    try std.testing.expect(!std.mem.eql(i32, before[0..], player.stats.values[0..])); // stats gained
}

test "env cycle advances and its equipped-item recalc leaves stats unchanged" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureItemTables() catch return;
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const player = ls.units.getPtr(c.player_guid).?;

    // The environment cycle counter advances one per call.
    gi.updateActEnvironments();
    gi.updateActEnvironments();
    try std.testing.expectEqual(@as(u64, 2), gi.env_ticks);

    // Equip a valued unique, then trigger the cycle-boundary recalc and confirm it nets zero.
    const ut = &gi.item_tables.?.unique_items;
    var uid: u16 = 0;
    var probe: std.ArrayListUnmanaged(items.properties.RolledStat) = .empty;
    defer probe.deinit(gpa);
    for (0..ut.rowCount()) |row| {
        if (ut.int(row, "enabled") == 0) continue;
        probe.clearRetainingCapacity();
        var s = items.rng.Seed.fromValue(0xABCD);
        var d0 = items.Drop{ .kind = .item, .quality = .unique, .unique_id = @intCast(row + 1), .item_level = 99 };
        items.properties.rollDropStats(gpa, &probe, &s, &gi.item_tables.?, &d0) catch continue;
        if (probe.items.len > 0) {
            uid = @intCast(row + 1);
            break;
        }
    }
    if (uid == 0) return;
    var si = StoredItem{ .guid = gi.allocGuid(), .code = .{ 0, 0, 0, 0 }, .x = 0, .y = 0, .w = 2, .h = 2, .item_seed = 0xABCD };
    si.drop = .{ .kind = .item, .quality = .unique, .unique_id = uid, .item_level = 99 };
    try c.inventory.append(gpa, si);
    _ = gi.equipItem(c, ls, si.guid, 3);

    const equipped_snapshot: [512]i32 = player.stats.values;
    gi.env_ticks = GameInstance.ENV_CYCLE_FRAMES - 1;
    gi.updateActEnvironments(); // hits the cycle boundary -> recalcEquippedItems
    try std.testing.expectEqual(GameInstance.ENV_CYCLE_FRAMES, gi.env_ticks);
    try std.testing.expectEqualSlices(i32, equipped_snapshot[0..], player.stats.values[0..]); // net zero
}

test "C->S equip (0x1A) and unequip (0x1C) drive the equipment model over the wire" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureItemTables() catch return;
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const player = ls.units.getPtr(c.player_guid).?;

    const ut = &gi.item_tables.?.unique_items;
    var uid: u16 = 0;
    var probe: std.ArrayListUnmanaged(items.properties.RolledStat) = .empty;
    defer probe.deinit(gpa);
    for (0..ut.rowCount()) |row| {
        if (ut.int(row, "enabled") == 0) continue;
        probe.clearRetainingCapacity();
        var s = items.rng.Seed.fromValue(0xABCD);
        var d0 = items.Drop{ .kind = .item, .quality = .unique, .unique_id = @intCast(row + 1), .item_level = 99 };
        items.properties.rollDropStats(gpa, &probe, &s, &gi.item_tables.?, &d0) catch continue;
        if (probe.items.len > 0) {
            uid = @intCast(row + 1);
            break;
        }
    }
    if (uid == 0) return;
    var si = StoredItem{ .guid = gi.allocGuid(), .code = .{ 0, 0, 0, 0 }, .x = 0, .y = 0, .w = 2, .h = 2, .item_seed = 0xABCD };
    si.drop = .{ .kind = .item, .quality = .unique, .unique_id = uid, .item_level = 99 };
    try c.inventory.append(gpa, si);

    var before: [512]i32 = player.stats.values;
    var buf: [16]u8 = undefined;
    // Equip to the torso slot (3) via the 0x1A command.
    _ = gi.handleCommand(c, (cs.EquipItem{ .guid = si.guid, .body_loc = 3 }).encode(&buf));
    try std.testing.expect(c.equipped.contains(3));
    try std.testing.expectEqual(@as(usize, 0), c.inventory.items.len);
    try std.testing.expect(!std.mem.eql(i32, before[0..], player.stats.values[0..])); // stats gained

    // Unequip that slot via the 0x1C command.
    _ = gi.handleCommand(c, (cs.UnequipItem{ .body_loc = 3 }).encode(&buf));
    try std.testing.expect(!c.equipped.contains(3));
    try std.testing.expectEqual(@as(usize, 1), c.inventory.items.len);
    try std.testing.expectEqualSlices(i32, before[0..], player.stats.values[0..]); // exact revert
}

test "pick up gold and an item from the ground (C->S 0x16)" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const p = ls.units.getPtr(c.player_guid).?;

    // A 120-gold pile + an item within pickup range, plus a pile out of range.
    gi.spawnGold(ls, p.x + 2, p.y, 120);
    gi.spawnItem(ls, p.x, p.y + 2, .{ 'h', 'p', '1', 0 });
    gi.spawnGold(ls, p.x + 500, p.y, 50);
    const gold_guid = ls.ground_items.items[0].guid;
    const item_guid = ls.ground_items.items[1].guid;
    const far_guid = ls.ground_items.items[2].guid;

    var buf: [16]u8 = undefined;
    _ = gi.handleCommand(c, (cs.PickUpItem{ .unit_type = 4, .guid = gold_guid }).encode(&buf));
    _ = gi.handleCommand(c, (cs.PickUpItem{ .unit_type = 4, .guid = item_guid }).encode(&buf));
    _ = gi.handleCommand(c, (cs.PickUpItem{ .unit_type = 4, .guid = far_guid }).encode(&buf)); // rejected: range

    try std.testing.expectEqual(@as(i32, 120), p.get(.gold));
    try std.testing.expectEqual(@as(usize, 1), ls.ground_items.items.len); // only the far pile left
    try std.testing.expectEqual(far_guid, ls.ground_items.items[0].guid);

    // The pending buffer holds GoldPickup (0x19, amount 120) then ItemAction (0x9C, picked).
    try std.testing.expect(c.pending.items.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x19), c.pending.items[0]);
    try std.testing.expectEqual(@as(u8, 120), c.pending.items[1]);
    try std.testing.expectEqual(@as(u8, 0x9C), c.pending.items[2]);

    // A tick flushes the pending events ahead of the diff and clears the buffer. The wire is RAW
    // (AF00 = compression off), so split by the per-opcode size table (sc.packetSize) to read the
    // leading two packet opcodes.
    const cap = struct {
        var first_ops: [2]u8 = .{ 0, 0 };
        fn f(_: i32, bytes: []const u8) isize {
            if (first_ops[0] == 0) {
                var off: usize = 0;
                var seen: usize = 0;
                while (off < bytes.len and seen < 2) {
                    const n = sc.packetSize(bytes[off..]) orelse break;
                    if (n == 0 or off + n > bytes.len) break;
                    first_ops[seen] = bytes[off];
                    seen += 1;
                    off += n;
                }
            }
            return @intCast(bytes.len);
        }
    };
    gi.tick(&cap.f);
    try std.testing.expectEqual(@as(usize, 0), c.pending.items.len);
    try std.testing.expectEqual(@as(u8, 0x19), cap.first_ops[0]); // gold event leads the flush
    try std.testing.expectEqual(@as(u8, 0x9C), cap.first_ops[1]); // then the item action
}

test "srvdofunc gaps: Frenzy/Double Swing strike twice, Charge repositions + hits" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureSkillTables() catch return;
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const player = ls.units.getPtr(c.player_guid).?;
    player.set(.mindamage, 20);
    player.set(.maxdamage, 20);
    player.set(.tohit, 100000); // near-cap hit chance so the loop lands quickly

    // A durable target monster right next to the player.
    try ls.units.put(gpa, 9001, testMonster(9001, player.x + 2, player.y, 100000));

    const skills = &gi.skills.?;
    // Frenzy (9, buff + attack) / Double Swing (70, dual-strike) / Charge (67, close + strike): each
    // was a no-op before. Loop-cast until damage lands (hit rolls cap at ~95%, so a few casts suffice).
    for ([_][]const u8{
        "Frenzy",     "Double Swing", "Charge",       "Jab",   "Charged Strike",
        "Dragon Talon", "Dragon Claw", "Sacrifice",   "Maul",  "Rabies",
        "Feral Rage", "Smite",
    }) |name| {
        const sid = skills.idByName(name) orelse continue;
        var dealt = false;
        var i: usize = 0;
        while (i < 60 and !dealt) : (i += 1) {
            const before = ls.units.getPtr(9001).?.life();
            gi.castSkill(c, ls, sid, .{ .guid = 9001 });
            if (ls.units.getPtr(9001).?.life() < before) dealt = true;
        }
        try std.testing.expect(dealt); // the skill actually strikes now
    }

    // Volcano (123): a ground-fire effect placed at the cast point (was a no-op before).
    if (skills.idByName("Volcano")) |vid| {
        const p = ls.units.getPtr(c.player_guid).?;
        const ge_before = ls.ground_effects.items.len;
        gi.castSkill(c, ls, vid, .{ .x = @intCast(p.x + 5), .y = @intCast(p.y) });
        try std.testing.expect(ls.ground_effects.items.len > ge_before);
    }

    // Confuse (61): a crowd-control skill — stuns (disables) the target (was a no-op before).
    if (ls.units.getPtr(9001) != null and skills.idByName("Confuse") != null) {
        _ = ls.frozen.remove(9001);
        ls.units.getPtr(9001).?.setLife(100000); // keep it alive
        gi.castSkill(c, ls, skills.idByName("Confuse").?, .{ .guid = 9001 });
        try std.testing.expect(ls.frozen.contains(9001));
    }
}

/// Sum of every server-side effect channel a cast can touch; the coverage test asserts each skill
/// changes it (or deals damage). Re-fetch the player each call — the units map rehashes in the test.
fn worldActivity(ls: *LevelState, c: *Client) u64 {
    var a: u64 = 0;
    if (ls.units.getPtr(c.player_guid)) |player| {
        for (player.stats.values) |v| a +%= @as(u64, @bitCast(@as(i64, v))); // stat delta = buff/shapeshift
    }
    a += ls.missiles.items.len;
    a += ls.units.count();
    a += ls.ground_effects.items.len;
    a += ls.ground_items.items.len;
    a += ls.frozen.count();
    a += ls.feared.count();
    a += ls.chilled.count();
    a += ls.curses.count();
    a += ls.aura_debuffs.count();
    a += ls.moved.count();
    a += ls.emitters.count();
    a += ls.stationary.count();
    a += ls.poison_dots.count(); // poison DoTs (Poison Dagger / Poison Explosion) tick over time
    a += c.active_aura;
    a += c.form_skill;
    a += c.revives.items.len; // Necromancer Revive consumes a corpse + spawns a pet (nets 0 on unit count)
    a += @intFromBool(c.golem_guid != 0);
    a += c.level_id;
    return a;
}

test "srvdofunc coverage: every player active skill produces an observable server effect" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8); // Blood Moor — a non-town level (Hydra / golem-at-cursor refuse town)
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureSkillTables() catch return;
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const player = ls.units.getPtr(c.player_guid).?;
    player.set(.mindamage, 50);
    player.set(.maxdamage, 50);
    player.set(.tohit, 1_000_000); // land melee/attack rolls immediately
    player.set(.mana, 1 << 24);
    player.set(.maxmana, 1 << 24);
    const mx: u16 = @intCast(player.x + 2);
    const my: u16 = @intCast(player.y);

    const skills = &gi.skills.?;

    // No server-side effect in the standalone model — client reveals + corpse-loot utilities.
    const allow = [_][]const u8{
        "Identify",   "Telekinesis", "Find Potion", "Find Item", "Find Gold",
    };

    var unhandled: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unhandled.deinit(gpa);

    var r: usize = 0;
    while (r < skills.table.rowCount()) : (r += 1) {
        const name = skills.table.get(r, "skill");
        if (name.len == 0) continue;
        if (skills.table.get(r, "charclass").len == 0) continue; // player skills only
        const id: u16 = @intCast(skills.table.getInt(i32, r, "Id") orelse continue);
        const sd = skills.byId(id) orelse continue;
        if (sd.is_passive) continue; // passives are always-on, never actively "cast"
        if (sd.doFunc() == .use_scroll_or_book) continue; // Town Portal / Identify book: client warp/reveal utility

        if (sd.is_aura) { // an aura cast makes it the active aura (tickAuras applies it each frame)
            gi.castSkill(c, ls, id, .{ .guid = 9001, .x = mx, .y = my });
            if (c.active_aura != id) unhandled.append(gpa, name) catch {};
            continue;
        }

        // Clean slate per skill so an effect that REPLACES (a re-keyed curse, a golem swap) still deltas.
        ls.missiles.clearRetainingCapacity();
        ls.ground_effects.clearRetainingCapacity();
        ls.ground_items.clearRetainingCapacity();
        ls.moved.clearRetainingCapacity();
        ls.frozen.clearRetainingCapacity();
        ls.feared.clearRetainingCapacity();
        ls.chilled.clearRetainingCapacity();
        ls.curses.clearRetainingCapacity();
        ls.aura_debuffs.clearRetainingCapacity();
        ls.emitters.clearRetainingCapacity();
        ls.stationary.clearRetainingCapacity();
        ls.poison_dots.clearRetainingCapacity();
        ls.corpses.clearRetainingCapacity();
        c.buffs = .{}; // drop the slot list without reversing stat deltas (the reversal path is fragile)
        c.active_aura = 0;
        c.form_skill = 0;
        if (c.golem_guid != 0) {
            _ = ls.units.remove(c.golem_guid);
            c.golem_guid = 0;
        }
        // Fresh durable target + a registered corpse (for the corpse-consumers) for each skill.
        _ = ls.units.remove(9001);
        _ = ls.units.remove(9002);
        ls.units.put(gpa, 9001, testMonster(9001, mx, my, 1_000_000)) catch {};
        var corpse = testMonster(9002, mx, my + 1, 1_000_000);
        corpse.class_id = 19; // a plain monster class so Revive can clone it
        corpse.setLife(0); // a consumable corpse near the cast point
        ls.units.put(gpa, 9002, corpse) catch {};
        ls.corpses.put(gpa, 9002, 1000) catch {}; // findCorpse only sees registered corpses

        var handled = false;
        var k: usize = 0;
        while (k < 40 and !handled) : (k += 1) {
            if (ls.units.getPtr(9001)) |t| t.setLife(1_000_000) else handled = true;
            const a0 = worldActivity(ls, c);
            gi.castSkill(c, ls, id, .{ .guid = 9001, .x = mx, .y = my });
            if (worldActivity(ls, c) != a0) handled = true;
            if (ls.units.getPtr(9001)) |t| {
                if (t.life() < 1_000_000) handled = true;
            } else handled = true; // target destroyed
            if (c.buffs.isActive(id)) handled = true; // a timed buff/charge state was granted
        }
        if (!handled) unhandled.append(gpa, name) catch {};
    }

    // Every unhandled skill must be in the allowlist, else it is a silent no-op regression.
    var bad: usize = 0;
    for (unhandled.items) |n| {
        var ok = false;
        for (allow) |a| {
            if (std.mem.eql(u8, a, n)) ok = true;
        }
        if (!ok) {
            std.debug.print("UNHANDLED srvdofunc skill: {s}\n", .{n});
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "srvmissilea delivery: Inferno/Chain Lightning/Thunder Storm/Firestorm spawn their real missile" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    gi.ensureSkillTables() catch return;
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const player = ls.units.getPtr(c.player_guid).?;
    player.set(.mana, 1 << 24);
    player.set(.maxmana, 1 << 24);
    const mx: u16 = @intCast(player.x + 4);
    const my: u16 = @intCast(player.y);
    const skills = &gi.skills.?;

    // These deliver via srvmissilea (empty srvmissile) — each must now spawn a real projectile.
    for ([_][]const u8{ "Inferno", "Chain Lightning", "Thunder Storm", "Firestorm" }) |name| {
        const id = skills.idByName(name) orelse continue;
        ls.missiles.clearRetainingCapacity();
        gi.castSkill(c, ls, id, .{ .x = mx, .y = my });
        try std.testing.expect(ls.missiles.items.len >= 1);
    }

    // Hydra (144) spawns three heads at the cursor.
    if (skills.idByName("Hydra")) |hid| {
        const before = ls.units.count();
        gi.castSkill(c, ls, hid, .{ .x = mx, .y = my });
        try std.testing.expectEqual(before + 3, ls.units.count());
    }
}

/// The `skip`-th nearest cell to (x,y) that is both walkable and in plain sight of it — where a test
/// may put an object it intends to interact with. On a real generated level the cells a fixed offset
/// from the spawn point are as likely to be rock as floor, and an object in rock is one no player
/// could ever see, so a test that places one there is testing an impossible map.
fn visibleSpotNear(ls: *LevelState, x: i32, y: i32, skip: usize) !drlg.Point {
    var seen: usize = 0;
    var r: i32 = 1;
    while (r <= 20) : (r += 1) {
        var oy: i32 = -r;
        while (oy <= r) : (oy += 1) {
            var ox: i32 = -r;
            while (ox <= r) : (ox += 1) {
                if (@abs(ox) != r and @abs(oy) != r) continue;
                const cx = x + ox;
                const cy = y + oy;
                if (!ls.passable(cx, cy, GameInstance.PLAYER_MASK)) continue;
                if (!ls.hasLineOfSight(x, y, cx, cy)) continue;
                if (seen < skip) {
                    seen += 1;
                    continue;
                }
                return .{ .x = cx, .y = cy };
            }
        }
    }
    return error.NoVisibleSpot;
}

test "operate a chest (drops + Opened) and a shrine (Operating), broadcast 0x0E" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const p = ls.units.getPtr(c.player_guid).?;

    // A chest (OperateFn 4) + a shrine (OperateFn 2) beside the player, one chest far away.
    const chest_at = try visibleSpotNear(ls, p.x, p.y, 0);
    const shrine_at = try visibleSpotNear(ls, p.x, p.y, 1);
    try ls.objects.append(gpa, .{ .guid = gi.allocGuid(), .class_id = 5, .x = chest_at.x, .y = chest_at.y, .operate_fn = OPFN_CHEST });
    try ls.objects.append(gpa, .{ .guid = gi.allocGuid(), .class_id = 2, .x = shrine_at.x, .y = shrine_at.y, .operate_fn = OPFN_SHRINE });
    try ls.objects.append(gpa, .{ .guid = gi.allocGuid(), .class_id = 5, .x = p.x + 500, .y = p.y, .operate_fn = OPFN_CHEST });
    const chest = ls.objects.items[0].guid;
    const shrine = ls.objects.items[1].guid;
    const far = ls.objects.items[2].guid;

    var buf: [12]u8 = undefined;
    const before = ls.ground_items.items.len;
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = chest }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 2), ls.objects.items[0].anim_mode); // Opened
    try std.testing.expect(ls.ground_items.items.len > before); // chest dropped loot

    // Re-opening does nothing (mode-gated).
    const after_open = ls.ground_items.items.len;
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = chest }).encode(&buf));
    try std.testing.expectEqual(after_open, ls.ground_items.items.len);

    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = shrine }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 1), ls.objects.items[1].anim_mode); // Operating

    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = far }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 0), ls.objects.items[2].anim_mode); // out of range

    // Pending buffer carries the two ObjectState 0x0E broadcasts (chest then shrine).
    try std.testing.expect(c.pending.items.len >= 2 * sc.ObjectState.SIZE);
    const st1 = try sc.ObjectState.decode(c.pending.items[0..]);
    try std.testing.expectEqual(chest, st1.guid);
    try std.testing.expectEqual(@as(u32, 2), st1.anim_mode);
    const st2 = try sc.ObjectState.decode(c.pending.items[sc.ObjectState.SIZE..]);
    try std.testing.expectEqual(shrine, st2.guid);
    try std.testing.expectEqual(@as(u32, 1), st2.anim_mode);
}

test "operate waypoint / well / door through the resolve->apply path" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const p = ls.units.getPtr(c.player_guid).?;

    const wp_at = try visibleSpotNear(ls, p.x, p.y, 0);
    const well_at = try visibleSpotNear(ls, p.x, p.y, 1);
    const door_at = try visibleSpotNear(ls, p.x, p.y, 2);
    try ls.objects.append(gpa, .{ .guid = gi.allocGuid(), .class_id = 5, .x = wp_at.x, .y = wp_at.y, .operate_fn = 23 }); // waypoint
    try ls.objects.append(gpa, .{ .guid = gi.allocGuid(), .class_id = 5, .x = well_at.x, .y = well_at.y, .operate_fn = 22 }); // well
    try ls.objects.append(gpa, .{ .guid = gi.allocGuid(), .class_id = 5, .x = door_at.x, .y = door_at.y, .operate_fn = 8 }); // door
    const wp = ls.objects.items[0].guid;
    const well = ls.objects.items[1].guid;
    const door = ls.objects.items[2].guid;
    var buf: [12]u8 = undefined;

    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = wp }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 1), GameInstance.objectByGuid(ls, wp).?.anim_mode); // waypoint active

    p.setLife(1); // wounded, then the well tops life+mana back up
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = well }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 1), GameInstance.objectByGuid(ls, well).?.anim_mode);
    try std.testing.expectEqual(p.get(.maxhp), p.life());

    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = door }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 5), GameInstance.objectByGuid(ls, door).?.anim_mode); // door toggled closed
}

test "line of sight is broken by a wall between the endpoints, clear otherwise" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x1, 0, .normal);
    defer gi.deinit();
    const W: i32 = 5;
    var lv = try bareLevel(gpa, W, 5);
    defer lv.deinit();
    lv.cells[@intCast(2 * W + 2)] = pf.Colbit.wall; // a single wall cell at (2,2)

    var ls = testLevelState();
    defer ls.deinit(gpa);
    ls.level = &lv;

    try std.testing.expect(!ls.hasLineOfSight(0, 2, 4, 2)); // row 2 passes through the wall
    try std.testing.expect(ls.hasLineOfSight(0, 0, 4, 0)); // row 0 is clear
    try std.testing.expect(ls.hasLineOfSight(0, 0, 1, 0)); // adjacent endpoints — always clear
}

test "a door toggles, then ignores re-operate until the debounce window passes" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const p = ls.units.getPtr(c.player_guid).?;

    gi.tick_count = 100; // past the start-of-game frame-0 edge
    try ls.objects.append(gpa, .{ .guid = gi.allocGuid(), .class_id = 9, .x = p.x, .y = p.y + 2, .operate_fn = OPFN_DOOR });
    const door = &ls.objects.items[ls.objects.items.len - 1];
    const guid = door.guid;

    var buf: [12]u8 = undefined;
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = guid }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 5), door.anim_mode); // opened door -> closing mode 5

    // Immediate re-operate is debounced (mode unchanged).
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = guid }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 5), door.anim_mode);

    // After the debounce window it toggles back.
    gi.tick_count += GameInstance.DOOR_DEBOUNCE_FRAMES;
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = guid }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 0), door.anim_mode);
}

test "operate a Refill shrine tops life+mana, then its reset timer re-enables it" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel();
    const c = try gi.addClient(-1, "", "");
    const ls = gi.levels.get(gi.level_id).?;
    const p = ls.units.getPtr(c.player_guid).?;

    // A damaged, mana-drained player and a Refill shrine (reset 2 min) beside them.
    p.set(.maxhp, 500);
    p.setLife(100);
    p.set(.maxmana, 200);
    p.set(.mana, 20);
    try ls.objects.append(gpa, .{
        .guid = gi.allocGuid(), .class_id = 2, .x = p.x, .y = p.y + 3,
        .operate_fn = OPFN_SHRINE, .shrine_effect = .refill, .shrine_reset_min = 2,
    });
    const shrine = ls.objects.items[ls.objects.items.len - 1].guid;
    const timers_before = ls.timers.count();

    var buf: [12]u8 = undefined;
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = shrine }).encode(&buf));

    const so = &ls.objects.items[ls.objects.items.len - 1];
    try std.testing.expectEqual(@as(u8, 1), so.anim_mode); // Operating
    try std.testing.expectEqual(@as(i32, 500), p.life()); // life topped to max
    try std.testing.expectEqual(@as(i32, 200), p.get(.mana)); // mana topped to max
    try std.testing.expectEqual(timers_before + 1, ls.timers.count()); // reset event scheduled

    // Fire the reset event at its target frame (now 0 + 2*1200+1) -> shrine re-enabled. (The
    // level's monster AI/regen timers also fire here; we assert only the shrine's own result.)
    gi.tick_count = sim.shrines.resetDelayFrames(2);
    gi.dispatchAllTimers(ls);
    try std.testing.expectEqual(@as(u8, 0), so.anim_mode); // Neutral again — reset event consumed

    // ...and the re-enabled shrine can be operated a second time.
    p.setLife(100);
    _ = gi.handleCommand(c, (cs.InteractWithEntity{ .unit_type = 2, .guid = shrine }).encode(&buf));
    try std.testing.expectEqual(@as(u8, 1), so.anim_mode);
    try std.testing.expectEqual(@as(i32, 500), p.life());
}

test "town NPCs come from DS1 presets: interactable, no AI, no hardcoded-fan duplicate" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(1); // Rogue Encampment (town)
    defer gi.deinit();
    _ = gi.generateLevel() catch return;
    const ls = gi.levels.get(1) orelse return;

    // Akara (class 148) is placed exactly once — from her DS1 preset, not doubled by a hardcoded fan.
    var akara: usize = 0;
    var it = ls.units.valueIterator();
    while (it.next()) |u| {
        if (u.class_id == 148) akara += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), akara);

    // The town's people are interactable NPCs with NO combat AI armed (passive presets).
    try std.testing.expect(ls.npcs.count() > 0);
    var nit = ls.npcs.keyIterator();
    while (nit.next()) |g| {
        try std.testing.expect(ls.units.contains(g.*));
        try std.testing.expect(!ls.ai.contains(g.*)); // no AI-think state for a town NPC
    }
    try std.testing.expect(ls.npcs.contains(blk: {
        var kit = ls.units.iterator();
        break :blk while (kit.next()) |e| {
            if (e.value_ptr.class_id == 148) break e.key_ptr.*;
        } else 0;
    })); // Akara herself is an interactable NPC
}

test "freeDungeons reaps an idle empty level while an occupied one persists" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(8);
    defer gi.deinit();
    _ = try gi.generateLevel(); // level 8 — will hold the client
    const c = try gi.addClient(-1, "", "");
    _ = c;
    _ = try gi.ensureLevel(2); // level 2 — no client, idle
    try std.testing.expect(gi.levels.get(2) != null);
    try std.testing.expect(gi.levels.get(8) != null);

    // First sweep just marks level 2 as newly-empty; nothing is freed yet.
    gi.tick_count = 100;
    gi.freeDungeons();
    try std.testing.expect(gi.levels.get(2) != null);

    // Past the idle window, the empty level is reaped; the occupied one stays.
    gi.tick_count = 100 + GameInstance.LEVEL_IDLE_FRAMES + 1;
    gi.freeDungeons();
    try std.testing.expect(gi.levels.get(2) == null); // reaped
    try std.testing.expect(gi.levels.get(8) != null); // client still present

    // A re-entered level regenerates from the seed.
    _ = try gi.ensureLevel(2);
    try std.testing.expect(gi.levels.get(2) != null);
}

test "warp transition moves the player to a connected level and re-populates it" {
    const gpa = std.testing.allocator;
    var gi = GameInstance.init(gpa, 1, 0x13572468, 0, .normal);
    gi.setLevel(29); // Jail 1 — warps to Jail 2 (30) via the real Vis graph
    defer gi.deinit();
    _ = try gi.generateLevel();

    const c = try gi.addClient(-1, "", "");
    const src = gi.levels.get(29).?;
    // Jail 1 has an outgoing warp to Jail 2 (30).
    var dest: u16 = 0;
    for (src.warps.items) |w| {
        if (w.dest_level == 30) dest = w.dest_level;
    }
    try std.testing.expectEqual(@as(u16, 30), dest);

    gi.warpClient(c, 30);
    try std.testing.expectEqual(@as(u16, 30), c.level_id);
    const dst = gi.levels.get(30).?;
    try std.testing.expect(dst.units.contains(c.player_guid)); // player moved into level 30
    try std.testing.expect(!src.units.contains(c.player_guid)); // and left level 29
    try std.testing.expect(dst.monsterCount() >= 1); // target level populated with monsters
    try std.testing.expect(c.pending_loadact); // client will get a fresh LoadAct
}

// --- headless session driver ------------------------------------------------
//
// Running the gameserver with NO sockets — a buffer where the networked host puts a write(2). This is
// the single-player / clientless path: the exact same GameInstance, driven a fixed number of ticks with
// scripted C->S input, its every server->client flush captured into memory. The host wraps these raw
// flushes into its own on-disk trace format; nothing here knows about files or sockets.

/// A C->S command to inject before a given game frame (already-encoded wire bytes).
pub const Cmd = struct { at_tick: u32, bytes: []const u8 };

/// One captured server->client flush: the logical tick it went out on (tick 0 = the join burst, tick
/// N+1 = frame N) and the RAW AF00 bytes. `bytes` is owned by the HeadlessRun that returned it.
pub const Flush = struct { tick: u32, bytes: []const u8 };

/// The captured output of a headless run: every server->client flush, in emission order.
pub const HeadlessRun = struct {
    flushes: std.ArrayListUnmanaged(Flush) = .empty,

    pub fn deinit(self: *HeadlessRun, gpa: std.mem.Allocator) void {
        for (self.flushes.items) |f| gpa.free(f.bytes);
        self.flushes.deinit(gpa);
    }
};

// The tick sink is a plain fn pointer (no context capture), so one run's flush lands in this scratch
// buffer and is copied out before the next tick. Threadlocal so concurrent headless runs on different
// threads don't clobber each other; a single run is inherently sequential.
threadlocal var g_capture: [1 << 20]u8 = undefined;
threadlocal var g_capture_len: usize = 0;

fn captureSink(_: i32, buf: []const u8) isize {
    const n = @min(buf.len, g_capture.len - g_capture_len);
    @memcpy(g_capture[g_capture_len..][0..n], buf[0..n]);
    g_capture_len += n;
    return @intCast(buf.len);
}

/// Drive a deterministic game headless for `ticks` frames — no sockets, a buffer sink — injecting each
/// `script` command before its frame, and capture every server->client flush. Tick 0 is the join burst;
/// tick N+1 is frame N. This is how a single-player or clientless host runs the gameserver. Caller owns
/// the returned HeadlessRun (call deinit).
pub fn runHeadless(
    gpa: std.mem.Allocator,
    seed: u32,
    level: u16,
    difficulty: sim.world.Difficulty,
    script: []const Cmd,
    ticks: u32,
) !HeadlessRun {
    var gi = GameInstance.init(gpa, 1, seed, 0, difficulty);
    gi.setLevel(level);
    defer gi.deinit();
    _ = try gi.generateLevel();
    const c = try gi.addClient(-1, "", "");

    var run = HeadlessRun{};
    errdefer run.deinit(gpa);

    // The join burst goes out RAW on the wire (AF00), same as every tick flush.
    var jbuf: [8192]u8 = undefined;
    try appendFlush(&run, gpa, 0, gi.buildJoinPackets(c, &jbuf));

    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        for (script) |cmd| {
            if (cmd.at_tick == t) _ = gi.handleCommand(c, cmd.bytes);
        }
        g_capture_len = 0;
        gi.tick(&captureSink);
        try appendFlush(&run, gpa, t + 1, g_capture[0..g_capture_len]);
    }
    return run;
}

fn appendFlush(run: *HeadlessRun, gpa: std.mem.Allocator, tick: u32, buf: []const u8) !void {
    const owned = try gpa.dupe(u8, buf);
    errdefer gpa.free(owned);
    try run.flushes.append(gpa, .{ .tick = tick, .bytes = owned });
}

test "runHeadless drives a game with a buffer sink and captures the join burst + frames" {
    const gpa = std.testing.allocator;
    var run = try runHeadless(gpa, 0x13572468, 1, .normal, &.{}, 3);
    defer run.deinit(gpa);
    // Join burst (tick 0) + one flush per driven frame (ticks 1..3).
    try std.testing.expectEqual(@as(usize, 4), run.flushes.items.len);
    try std.testing.expectEqual(@as(u32, 0), run.flushes.items[0].tick);
    try std.testing.expect(run.flushes.items[0].bytes.len > 0); // a real join burst went out
    try std.testing.expectEqual(@as(u32, 3), run.flushes.items[3].tick);
}
