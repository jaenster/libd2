//! Missile lifecycle — faithful port of the D2 1.14d server missile path.
//!
//! Ghidra session 62fbfe69, 1.14d Game.exe. Modelled functions:
//!   MISSILE_CreateFromUnitWithOffset @0x4cdc30  spawn a missile from a caster unit
//!   MISSILE_InitMissileUnit          @0x4cd0a0  init position + velocity toward target
//!   MISSILE_CanHitTarget             @0x4ccf40  per-tick collision test vs a unit
//!   Missiles_SrvHitFunc_*  (pattern)            on-hit -> combat damage
//!
//! Data is loaded from Missiles.txt (Vel/Range/Collide*). This pass models a
//! STRAIGHT-LINE bolt only: constant velocity toward the cast target, a distance
//! budget, and a radius collision test. Homing/guided, piercing (CollideKill=0),
//! area-of-effect splash, per-frame acceleration (Accel/MaxVel ramp), sub-missiles
//! (srvmissilea/b/c) and NextHit/NextDelay retargeting are explicit TODOs.
//!
//! COORDINATE NOTE: the engine tracks missiles in a fine position space; this slice
//! works directly in world SUBTILES (the on-wire unit coordinate). Missiles.txt Vel
//! is used as subtiles/tick and Range is scaled by RANGE_SCALE so a bolt crosses a
//! room rather than dying after a couple of subtiles — a deliberate slice
//! approximation of the fine->subtile conversion, kept until the precise position
//! model lands.

const std = @import("std");
const rng = @import("rng.zig");
const unit = @import("unit.zig");
const combat = @import("combat.zig");
const spell = @import("spell.zig");
const d2data = @import("d2-data");

const Seed = rng.Seed;
const Unit = unit.Unit;

/// Reach scale applied to Missiles.txt Range (see COORDINATE NOTE).
pub const RANGE_SCALE: i32 = 16;
/// Floor on the collision radius (world subtiles) so a slow/point-blank bolt still
/// connects even if a single tick's step under/over-shoots the target's subtile.
pub const MIN_COLLIDE: i32 = 12;

/// One Missiles.txt row, reduced to the fields the straight-line bolt reads.
pub const MissileData = struct {
    id: u16 = 0,
    /// Vel column — per-tick travel (subtiles, slice interpretation).
    vel: i32 = 0,
    /// Range column — raw; effective reach is range*RANGE_SCALE subtiles.
    range: i32 = 0,
    /// CollideType (0=none,1=units,3=units+walls,…); 0 => passes through everything.
    collide_type: i32 = 0,
    /// CollideKill: the missile is destroyed on its first unit collision.
    collide_kill: bool = false,
    /// Explicit damage (MinDamage/MaxDamage); 0/0 => damage is caster-derived at cast.
    min_damage: i32 = 0,
    max_damage: i32 = 0,
    /// MaxVel / Accel — a missile ramps its speed by `accel` subtiles/tick each tick toward `max_vel`
    /// (e.g. Guided Arrow, Charged Bolt). `accel == 0` => constant velocity.
    max_vel: i32 = 0,
    accel: i32 = 0,
    /// LevRange — extra Range added per skill level above 1 (per-level reach growth).
    lev_range: i32 = 0,
    /// CollideFriend — the missile may collide with allied units (auras / helpful missiles).
    collide_friend: bool = false,
    /// Pierce — the missile passes THROUGH a unit it hits instead of stopping (works with
    /// CollideKill=0). Distinct from CollideKill (which destroys on first unit hit).
    pierce: bool = false,
    /// NextDelay — frames a missile must wait before it may hit the SAME unit again (a lingering /
    /// piercing missile can't machine-gun one target). 0 => no per-unit cooldown.
    next_delay: i32 = 0,
    /// HitSubMissile1..4 — the "Missile" names this missile spawns AT its impact point when it hits
    /// (Exploding Arrow -> explodingarrowexp2, Immolation Arrow -> immolationfire, Meteor -> ...).
    /// Empty strings for unused slots; the names borrow the Missiles table.
    hit_sub: [4][]const u8 = .{ "", "", "", "" },
    /// pSrvDoFunc — the server per-frame handler id. 15 = a spread sub-missile EMITTER (Frozen Orb):
    /// every `param1` frames it spawns `sub_missile1` at a ring direction that rotates by `param2`.
    srv_do_func: i32 = 0,
    param1: i32 = 0,
    param2: i32 = 0,
    /// SubMissile1 — the child a per-frame emitter spawns (Frozen Orb -> frozenorbbolt). Borrows the table.
    sub_missile1: []const u8 = "",
};

/// CollideType bit for walls/collision map (D2 MISSILE_COLLIDE_UNITS=1, WALLS=2; the common
/// bolt value 3 = units+walls). A missile whose collide_type has this bit dies on a blocked cell.
pub const COLLIDE_WALLS: i32 = 2;

/// Loaded Missiles.txt (the REAL 1.14d table from d2-data — ~150 columns, 684 rows), indexed by
/// the lowercase "Missile" name (skills reference it via srvmissile) and by numeric Id. Columns
/// are addressed by NAME. Cited columns: Missile, Id, Vel, Range, CollideType, CollideKill,
/// MinDamage, MaxDamage.
pub const Missiles = struct {
    table: d2data.Table,

    pub fn load(gpa: std.mem.Allocator) !Missiles {
        return .{ .table = try d2data.open(gpa, "Missiles") };
    }
    pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Missiles {
        return .{ .table = try d2data.tsv.parse(gpa, src) };
    }
    pub fn deinit(self: *Missiles) void {
        self.table.deinit();
    }

    fn rowData(self: *const Missiles, row: usize) MissileData {
        const t = &self.table;
        return .{
            .id = @intCast(t.getInt(i32, row, "Id") orelse 0),
            .vel = t.getInt(i32, row, "Vel") orelse 0,
            .range = t.getInt(i32, row, "Range") orelse 0,
            .collide_type = t.getInt(i32, row, "CollideType") orelse 0,
            .collide_kill = (t.getInt(i32, row, "CollideKill") orelse 0) != 0,
            .min_damage = t.getInt(i32, row, "MinDamage") orelse 0,
            .max_damage = t.getInt(i32, row, "MaxDamage") orelse 0,
            .max_vel = t.getInt(i32, row, "MaxVel") orelse 0,
            .accel = t.getInt(i32, row, "Accel") orelse 0,
            .lev_range = t.getInt(i32, row, "LevRange") orelse 0,
            .collide_friend = (t.getInt(i32, row, "CollideFriend") orelse 0) != 0,
            .pierce = (t.getInt(i32, row, "Pierce") orelse 0) != 0,
            .next_delay = t.getInt(i32, row, "NextDelay") orelse 0,
            .hit_sub = .{
                t.get(row, "HitSubMissile1"), t.get(row, "HitSubMissile2"),
                t.get(row, "HitSubMissile3"), t.get(row, "HitSubMissile4"),
            },
            .srv_do_func = t.getInt(i32, row, "pSrvDoFunc") orelse 0,
            .param1 = t.getInt(i32, row, "Param1") orelse 0,
            .param2 = t.getInt(i32, row, "Param2") orelse 0,
            .sub_missile1 = t.get(row, "SubMissile1"),
        };
    }

    /// Spawn a missile's HitSubMissile children at `parent`'s current position when it impacts — the
    /// host calls this on a hit/expire and adds the returned missiles (assigning guids). Children aim
    /// the parent's heading (a 0-velocity child = a stationary cloud/explosion). Returns the count.
    pub fn spawnHitSubs(self: *const Missiles, parent: *const Missile, seed: *Seed, out: *[4]Missile) usize {
        _ = seed;
        var n: usize = 0;
        for (parent.hit_sub) |name| {
            if (name.len == 0) continue;
            const md = self.byName(name) orelse continue;
            // Aim along the parent's heading; a child with vel 0 stays put (cloud/explosion).
            const m = Missile.create(md, parent.owner_id, parent.x, parent.y, parent.x + parent.vx, parent.y + parent.vy, md.min_damage, md.max_damage);
            out[n] = m;
            n += 1;
        }
        return n;
    }

    /// Look up a missile by its Missiles.txt "Missile" name (skill srvmissile ref).
    pub fn byName(self: *const Missiles, name: []const u8) ?MissileData {
        const row = self.table.findRow("Missile", name) orelse return null;
        return self.rowData(row);
    }

    /// Look up a missile by numeric Id.
    pub fn byId(self: *const Missiles, id: u16) ?MissileData {
        const row = self.table.findByInt("Id", id) orelse return null;
        return self.rowData(row);
    }
};

/// A live missile in flight. Positions are world subtiles; velocity is subtiles/tick.
/// `owner_id` is the caster's unit id (collisions never hit the owner). `dmg_min/max`
/// are the whole-damage bounds rolled between on hit (snapshot at cast time).
pub const Missile = struct {
    id: u16 = 0, // missile id (streamed as the unit class on the wire)
    guid: u32 = 0, // assigned by the host when added to the game
    owner_id: u32 = 0xFFFFFFFF,
    x: i32 = 0,
    y: i32 = 0,
    vx: i32 = 0,
    vy: i32 = 0,
    vel: i32 = 0,
    /// Speed ramp: `vel` climbs by `accel` each tick toward `max_vel` (0 => constant velocity).
    max_vel: i32 = 0,
    accel: i32 = 0,
    range_left: i32 = 0,
    collide_radius: i32 = MIN_COLLIDE,
    collide_type: i32 = 0,
    collide_kill: bool = true,
    /// Passes through a unit it hits (Pierce) rather than stopping; can hit allies (CollideFriend).
    pierce: bool = false,
    collide_friend: bool = false,
    /// HitSubMissile names this missile spawns on impact (see Missiles.spawnHitSubs). Borrow the table.
    hit_sub: [4][]const u8 = .{ "", "", "", "" },
    /// Per-unit re-hit cooldown (NextDelay): after hitting `last_hit`, `hit_cd` frames must pass
    /// before that same unit can be hit again. Prevents a lingering/piercing missile from re-damaging
    /// one target every tick.
    next_delay: i32 = 0,
    hit_cd: i32 = 0,
    last_hit: u32 = 0xFFFFFFFF,
    dmg_min: i32 = 0,
    dmg_max: i32 = 0,
    /// The missile's damage is derived from the caster at hit time (e.g. a sorc cold bolt whose
    /// applied damage depends on the VICTIM's resist + the caster's mastery pierce) rather than the
    /// flat dmg_min/max roll. The host's `applyHit` owns that computation; stepAll skips its own
    /// rollDamage for these. Set for spells with empty Missiles.txt MinDamage/MaxDamage.
    caster_derived: bool = false,
    /// The elemental cast this missile carries — snapshot from the caster's build AT CAST TIME
    /// (skill.cast folds in the sorc's effective skill level + synergies + mastery pierce). On the
    /// first monster collision `applyElementalHitVs` resolves it against THAT victim's resist. Set
    /// (with `caster_derived`) for elemental bolts; null for flat-damage missiles.
    elem_cast: ?spell.Cast = null,
    /// HOMING (Guided Arrow / Bone Spirit, missile pSrvDoFunc 7): the host re-aims this toward the
    /// nearest valid target every few frames while it is in range (Missiles_SrvDoFunc_007). `reaim`
    /// recomputes the velocity toward a point at the current speed; the host owns target selection.
    homing: bool = false,

    /// Re-point the velocity toward (tx,ty) at the current speed — the homing step (Guided Arrow).
    pub fn reaim(self: *Missile, tx: i32, ty: i32) void {
        const dx = tx - self.x;
        const dy = ty - self.y;
        if (dx == 0 and dy == 0) return;
        const len = std.math.sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy)));
        const fv: f64 = @floatFromInt(@max(1, self.vel));
        self.vx = @intFromFloat(@round(@as(f64, @floatFromInt(dx)) / len * fv));
        self.vy = @intFromFloat(@round(@as(f64, @floatFromInt(dy)) / len * fv));
    }

    /// MISSILE_InitMissileUnit @0x4cd0a0 / MISSILE_CreateFromUnitWithOffset @0x4cdc30:
    /// spawn `data` from (sx,sy) with velocity aimed at (tx,ty). A zero-length aim
    /// (target on the caster) defaults to +X so the missile is still well-formed.
    pub fn create(data: MissileData, owner_id: u32, sx: i32, sy: i32, tx: i32, ty: i32, dmg_min: i32, dmg_max: i32) Missile {
        const vel = @max(1, data.vel);
        var vx: i32 = vel;
        var vy: i32 = 0;
        const dx = tx - sx;
        const dy = ty - sy;
        if (dx != 0 or dy != 0) {
            const len = std.math.sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy)));
            const fv: f64 = @floatFromInt(vel);
            vx = @intFromFloat(@round(@as(f64, @floatFromInt(dx)) / len * fv));
            vy = @intFromFloat(@round(@as(f64, @floatFromInt(dy)) / len * fv));
        }
        return .{
            .id = data.id,
            .owner_id = owner_id,
            .x = sx,
            .y = sy,
            .vx = vx,
            .vy = vy,
            .vel = vel,
            .max_vel = data.max_vel,
            .accel = data.accel,
            .range_left = @max(1, data.range) * RANGE_SCALE,
            .collide_radius = @max(MIN_COLLIDE, vel),
            .collide_type = data.collide_type,
            .collide_kill = data.collide_kill,
            .pierce = data.pierce,
            .collide_friend = data.collide_friend,
            .hit_sub = data.hit_sub,
            .next_delay = data.next_delay,
            .dmg_min = dmg_min,
            .dmg_max = dmg_max,
        };
    }

    /// Advance one tick: ramp speed (Accel toward MaxVel), translate by velocity, spend the budget.
    /// MISSILE_UpdateMissile @0x4ce6f0: velocity accelerates each frame; the direction is preserved
    /// by scaling the (vx,vy) components to the new magnitude.
    pub fn step(self: *Missile) void {
        if (self.accel != 0 and self.max_vel > self.vel and self.vel > 0) {
            const nv = @min(self.vel + self.accel, self.max_vel);
            self.vx = @divTrunc(self.vx * nv, self.vel);
            self.vy = @divTrunc(self.vy * nv, self.vel);
            self.vel = nv;
        }
        self.x += self.vx;
        self.y += self.vy;
        self.range_left -= self.vel;
    }

    /// Distance budget exhausted — the missile fizzles.
    pub fn expired(self: *const Missile) bool {
        return self.range_left <= 0;
    }

    /// MISSILE_CanHitTarget @0x4ccf40 (slice): a live, non-owner unit whose centre is
    /// within the collision radius. CollideType 0 never collides with units.
    pub fn canHit(self: *const Missile, u: *const Unit) bool {
        if (self.collide_type == 0) return false;
        if (!u.isAlive()) return false;
        if (u.unit_id == self.owner_id) return false; // never the caster itself
        if (u.owner_id != unit.NO_OWNER and u.owner_id == self.owner_id) return false; // nor the caster's own pets
        const dx = u.x - self.x;
        const dy = u.y - self.y;
        return dx * dx + dy * dy <= self.collide_radius * self.collide_radius;
    }

    /// This missile is subject to wall/collision-map collision (CollideType walls bit). When set,
    /// a step onto a blocked subtile retires the missile so it can never reach a unit behind a wall.
    pub fn collidesWalls(self: *const Missile) bool {
        return (self.collide_type & COLLIDE_WALLS) != 0;
    }

    /// On-hit damage roll (Missiles_SrvHitFunc_* pattern): uniform in [min,max].
    pub fn rollDamage(self: *const Missile, seed: *Seed) i32 {
        if (self.dmg_max <= self.dmg_min) return self.dmg_min;
        return seed.rollBetween(self.dmg_min, self.dmg_max);
    }
};

/// Find a live missile in a host-owned slice by guid (host visibility bookkeeping).
pub fn find(missiles: []Missile, guid: u32) ?*Missile {
    for (missiles) |*m| {
        if (m.guid == guid) return m;
    }
    return null;
}

/// On-hit elemental resolution for a `caster_derived` missile carrying an `elem_cast`: resolve the
/// snapshot cast against THIS victim's resist (its resist for the cast's element minus the cast's
/// Cold-Mastery / -%enemy-resist pierce) and subtract the applied damage from its life. Consumes
/// one RNG step (the damage roll). A no-op when the missile carries no `elem_cast`. This is the
/// host's `applyHit` seam moved into d2-sim: the elemental cast + resist math lives here, the host
/// only owns unit storage + the seed. Mirrors skill.resolveElementalVsUnit + applyElementalHit
/// (kept inline here to avoid a missile<->skill import cycle).
/// The resolved elemental hit a caster-derived missile deals to `victim` — computed but NOT applied,
/// so the host can apply it instant (most elements) or spread it as a DoT (poison). Consumes one RNG
/// step (the damage roll). Null if the missile carries no cast. `e_len` is the poison length in frames.
pub const MissileHit = struct { element: spell.Element, applied: i32, e_len: i32 };

pub fn elementalHitVs(m: *const Missile, victim: *const Unit, seed: *Seed) ?MissileHit {
    const cast = m.elem_cast orelse return null;
    const raw = cast.roll(seed);
    const target_resist = spell.ResistProfile.fromUnit(victim, cast.dmg.etype).percent;
    const applied = spell.applyResist(raw, target_resist - cast.pierce_percent);
    return .{ .element = cast.dmg.etype, .applied = applied, .e_len = cast.e_len };
}

pub fn applyElementalHitVs(m: *const Missile, victim: *Unit, seed: *Seed) void {
    const h = elementalHitVs(m, victim, seed) orelse return;
    if (h.applied > 0) combat.applyToLife(victim, h.applied);
}

/// Advance every missile one tick over the host's slice. For each missile, `ctx.target(m)`
/// returns the unit it collides with (the host owns unit storage AND the target policy — e.g.
/// "monsters only"); the damage is applied to that victim's life, then the missile steps +
/// checks wall collision and expiry. Retired missiles (killed on collision, blocked by a wall, or
/// out of range) are compacted out of the FRONT of the slice, preserving order; the surviving count
/// is returned so the host can shrink its ArrayList. The host keeps the collection; the lib only
/// rewrites the slice window and mutates victim life (same contract as combat.attackAndApply).
///
/// Optional `ctx` decls (duck-typed):
///   `blockedAt(x, y) bool` — wall/collision-map LoS. A CollideType-walls missile that steps onto a
///     blocked subtile is retired THERE, so it cannot hit a unit behind the wall. Absent => no walls.
///   `applyHit(*const Missile, *Unit) void` — host-owned on-hit damage for `caster_derived` missiles
///     (e.g. a cold bolt whose applied damage reads the victim's resist + caster's pierce). When
///     absent for such a missile, stepAll falls back to the flat rollDamage.
pub fn stepAll(missiles: []Missile, seed: *Seed, ctx: anytype) usize {
    const Ctx = @TypeOf(ctx);
    var w: usize = 0;
    for (missiles) |src| {
        var m = src;
        var retire = false;
        if (ctx.target(&m)) |victim| {
            // NextDelay: skip the SAME unit while its per-unit cooldown is still running (a lingering
            // missile passing over a target doesn't re-hit it every frame).
            const on_cooldown = victim.unit_id == m.last_hit and m.hit_cd > 0;
            if (!on_cooldown) {
                if (m.caster_derived and @hasDecl(Ctx, "applyHit")) {
                    ctx.applyHit(&m, victim);
                } else {
                    combat.applyToLife(victim, m.rollDamage(seed));
                }
                m.last_hit = victim.unit_id;
                m.hit_cd = m.next_delay;
                // CollideKill destroys the missile on its first unit hit — UNLESS it pierces, in which
                // case it deals its damage and travels on through the unit (Pierce).
                if (m.collide_kill and !m.pierce) retire = true;
            }
        }
        if (!retire) {
            m.step();
            if (m.hit_cd > 0) m.hit_cd -= 1; // per-unit re-hit cooldown ticks down each frame
            if (m.expired()) retire = true;
            // Wall line-of-sight: a units+walls missile dies on the blocked cell it steps into,
            // BEFORE it can be tested against a unit on the next tick (MISSILE_CanHitTarget's
            // CheckCollision arm). Off-map / blocked => retire here.
            if (!retire and m.collidesWalls() and @hasDecl(Ctx, "blockedAt") and ctx.blockedAt(m.x, m.y)) {
                retire = true;
            }
        }
        if (!retire) {
            missiles[w] = m;
            w += 1;
        }
    }
    return w;
}

const testing = std.testing;

test "find locates a missile by guid" {
    var arr = [_]Missile{
        .{ .guid = 10, .id = 1 },
        .{ .guid = 20, .id = 2 },
    };
    try testing.expectEqual(@as(u16, 2), find(&arr, 20).?.id);
    try testing.expectEqual(@as(?*Missile, null), find(&arr, 99));
}

test "stepAll damages a hit target, retires the killer, keeps a piercing/flying bolt" {
    // Two monsters; the ctx reports a hit only for the first missile (collide_kill => retire),
    // never for the second (which just flies until it expires).
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.setLife(100);

    const Ctx = struct {
        victim: *Unit,
        hit_guid: u32,
        fn target(self: @This(), m: *const Missile) ?*Unit {
            return if (m.guid == self.hit_guid) self.victim else null;
        }
    };

    var missiles = [_]Missile{
        .{ .guid = 1, .id = 58, .vel = 5, .range_left = 100, .collide_kill = true, .dmg_min = 7, .dmg_max = 7 },
        .{ .guid = 2, .id = 58, .vel = 5, .range_left = 10, .collide_kill = true },
    };
    var seed = Seed.fromValue(1);
    const ctx = Ctx{ .victim = &mob, .hit_guid = 1 };
    const surviving = stepAll(&missiles, &seed, ctx);

    try testing.expectEqual(@as(i32, 93), mob.life()); // took 7 from missile 1
    try testing.expectEqual(@as(usize, 1), surviving); // missile 1 retired on kill-collision
    try testing.expectEqual(@as(u32, 2), missiles[0].guid); // survivor compacted to front, stepped
    try testing.expectEqual(@as(i32, 5), missiles[0].range_left); // 10 - vel 5
}

test "NextDelay: a lingering missile hits a unit once, then waits out the cooldown" {
    var mob = Unit.init(.monster);
    mob.unit_id = 3;
    mob.setLife(1000);
    const Ctx = struct {
        victim: *Unit,
        fn target(self: @This(), m: *const Missile) ?*Unit {
            _ = m;
            return self.victim; // the unit is always in range (a lingering overlap)
        }
    };
    // A non-killing, non-moving missile over the unit with NextDelay 3: it should hit once, then not
    // again for 3 frames.
    var arr = [_]Missile{.{ .guid = 1, .id = 1, .vel = 0, .range_left = 1000, .collide_kill = false, .next_delay = 3, .dmg_min = 10, .dmg_max = 10 }};
    var seed = Seed.fromValue(1);
    const ctx = Ctx{ .victim = &mob };

    _ = stepAll(&arr, &seed, ctx); // frame 1: hits (1000 -> 990), cd set to 3
    try testing.expectEqual(@as(i32, 990), mob.life());
    _ = stepAll(&arr, &seed, ctx); // frame 2: on cooldown -> no hit
    _ = stepAll(&arr, &seed, ctx); // frame 3: still cooling
    try testing.expectEqual(@as(i32, 990), mob.life()); // untouched during cooldown
    _ = stepAll(&arr, &seed, ctx); // frame 4: cooldown elapsed -> hits again (990 -> 980)
    try testing.expectEqual(@as(i32, 980), mob.life());
}

test "a Pierce missile deals its damage but travels on through the unit (not retired)" {
    var mob = Unit.init(.monster);
    mob.setLife(1000);
    const Ctx = struct {
        victim: *Unit,
        fn target(self: @This(), m: *const Missile) ?*Unit {
            _ = m;
            return self.victim;
        }
    };
    // collide_kill=true would normally retire it, but Pierce overrides -> it survives + keeps flying.
    var arr = [_]Missile{.{ .guid = 1, .id = 1, .vel = 5, .range_left = 1000, .collide_kill = true, .pierce = true, .dmg_min = 10, .dmg_max = 10 }};
    var seed = Seed.fromValue(1);
    const surviving = stepAll(&arr, &seed, Ctx{ .victim = &mob });
    try testing.expectEqual(@as(usize, 1), surviving); // pierced through, still in flight
    try testing.expectEqual(@as(i32, 990), mob.life()); // still dealt its 10 damage
}

test "stepAll retires a units+walls bolt on a blocked cell before it hits a unit behind it" {
    // A CollideType-3 bolt travelling +X toward a monster at x=40, with a wall at x>=20. The bolt
    // must die on the wall (never reach the monster). ctx reports the unit hit only if the bolt
    // gets within radius of x=40 (it never should).
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.x = 40;
    mob.y = 0;
    mob.setLife(100);

    const Ctx = struct {
        victim: *Unit,
        fn target(self: @This(), m: *const Missile) ?*Unit {
            return if (m.canHit(self.victim)) self.victim else null;
        }
        fn blockedAt(_: @This(), x: i32, _: i32) bool {
            return x >= 20;
        }
    };

    const data = MissileData{ .id = 59, .vel = 12, .range = 50, .collide_type = 3, .collide_kill = true };
    var missiles = [_]Missile{Missile.create(data, 1, 0, 0, 40, 0, 0, 0)};
    var seed = Seed.fromValue(1);
    const ctx = Ctx{ .victim = &mob };
    var live: usize = 1;
    var ticks: usize = 0;
    while (live > 0 and ticks < 100) : (ticks += 1) {
        live = stepAll(missiles[0..live], &seed, ctx);
    }
    try testing.expectEqual(@as(usize, 0), live); // bolt retired
    try testing.expectEqual(@as(i32, 100), mob.life()); // monster behind the wall took nothing
}

test "stepAll routes caster_derived damage through ctx.applyHit" {
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.setLife(100);

    const Ctx = struct {
        victim: *Unit,
        fn target(self: @This(), m: *const Missile) ?*Unit {
            return if (m.guid == 1) self.victim else null;
        }
        fn applyHit(_: @This(), _: *const Missile, v: *Unit) void {
            combat.applyToLife(v, 25); // caster-derived: fixed here, resist-aware in the host
        }
    };

    var missiles = [_]Missile{
        .{ .guid = 1, .id = 59, .vel = 5, .range_left = 100, .collide_kill = true, .caster_derived = true, .dmg_min = 7, .dmg_max = 7 },
    };
    var seed = Seed.fromValue(1);
    const surviving = stepAll(&missiles, &seed, Ctx{ .victim = &mob });
    try testing.expectEqual(@as(usize, 0), surviving);
    try testing.expectEqual(@as(i32, 75), mob.life()); // 25 from applyHit, NOT the flat 7 roll
}

test "applyElementalHitVs resolves the carried cast against the victim's resist (with pierce)" {
    // A cold cast (sample element row; this test exercises the MISSILE hit-resolution path, not the
    // table read — see skill.zig for the table-driven cast assembly). Cold Mastery 5 => -40% pierce.
    const cold: spell.ElementalDamage = .{
        .etype = .cold,
        .e_min = 6,
        .e_max = 10,
        .e_min_lev = .{ 2, 4, 6, 8, 10 },
        .e_max_lev = .{ 3, 5, 7, 9, 11 },
        .hit_shift = 7,
    };
    const c = spell.Cast{ .dmg = cold, .skill_level = 20, .pierce_percent = 40 };
    var mob = Unit.init(.monster);
    mob.set(.coldresist, 75); // 75% - 40% pierce = 35% effective.
    mob.setLife(10000);
    var m = Missile{ .id = 59, .caster_derived = true, .elem_cast = c };
    var seed = Seed.fromValue(0xB01);
    applyElementalHitVs(&m, &mob, &seed);
    // Recompute the same roll deterministically and assert the applied 35%-resisted damage landed.
    var seed2 = Seed.fromValue(0xB01);
    const raw = c.roll(&seed2);
    const expect = spell.applyResist(raw, 35);
    try testing.expect(expect > 0);
    try testing.expectEqual(@as(i32, 10000) - expect, mob.life());
}

test "applyElementalHitVs is a no-op for a missile with no elem_cast" {
    var mob = Unit.init(.monster);
    mob.setLife(500);
    var m = Missile{ .id = 58 };
    var seed = Seed.fromValue(1);
    applyElementalHitVs(&m, &mob, &seed);
    try testing.expectEqual(@as(i32, 500), mob.life());
}

test "load missiles by name and id" {
    var m = try Missiles.load(testing.allocator);
    defer m.deinit();
    const fb = m.byName("firebolt").?;
    try testing.expectEqual(@as(u16, 58), fb.id);
    try testing.expectEqual(@as(i32, 20), fb.vel);
    try testing.expectEqual(@as(i32, 50), fb.range);
    try testing.expect(fb.collide_kill);
    try testing.expectEqual(@as(u16, 27), m.byId(27).?.id); // magicarrow
    try testing.expectEqual(@as(?MissileData, null), m.byName("nope"));
}

test "HitSubMissile: a missile spawns its child missiles at the impact point" {
    var m = try Missiles.load(testing.allocator);
    defer m.deinit();
    // Exploding Arrow spawns explodingarrowexp2 on hit.
    const ea = m.byName("explodingarrow").?;
    try testing.expectEqualStrings("explodingarrowexp2", ea.hit_sub[0]);

    // Create the parent, fly it, then spawn its hit-subs at its position.
    var parent = Missile.create(ea, 7, 0, 0, 100, 0, 0, 0);
    parent.x = 40;
    parent.y = 8;
    var seed = Seed.fromValue(1);
    var kids: [4]Missile = undefined;
    const n = m.spawnHitSubs(&parent, &seed, &kids);
    try testing.expect(n >= 1);
    try testing.expectEqual(m.byName("explodingarrowexp2").?.id, kids[0].id); // the right child
    try testing.expectEqual(@as(i32, 40), kids[0].x); // spawned at the parent's impact point
    try testing.expectEqual(@as(i32, 8), kids[0].y);
    try testing.expectEqual(@as(u32, 7), kids[0].owner_id); // inherits the caster
}

test "missile delivery fields (MaxVel/Accel/Pierce) load + the speed ramp works" {
    var m = try Missiles.load(testing.allocator);
    defer m.deinit();
    // Blessed Hammer accelerates: Vel=18, MaxVel=30, Accel=250 (clamped to MaxVel in one tick).
    const bh = m.byName("blessedhammer").?;
    try testing.expectEqual(@as(i32, 18), bh.vel);
    try testing.expectEqual(@as(i32, 30), bh.max_vel);
    try testing.expectEqual(@as(i32, 250), bh.accel);

    // Ramp physics: a bolt with vel 5, accel 3, max 11 aimed +X speeds 5 -> 8 -> 11 -> 11.
    const data = MissileData{ .id = 1, .vel = 5, .range = 1000, .accel = 3, .max_vel = 11 };
    var b = Missile.create(data, 9, 0, 0, 100, 0, 0, 0);
    try testing.expectEqual(@as(i32, 5), b.vel);
    b.step();
    try testing.expectEqual(@as(i32, 8), b.vel);
    try testing.expectEqual(@as(i32, 8), b.vx); // aimed +X, so vx tracks vel
    b.step();
    try testing.expectEqual(@as(i32, 11), b.vel);
    b.step();
    try testing.expectEqual(@as(i32, 11), b.vel); // capped at MaxVel
}

test "TABLE-DRIVEN: icebolt missile (Id 59) resolves from the REAL Missiles.txt (Vel=12/Range=50/CollideType=3)" {
    var m = try Missiles.load(testing.allocator);
    defer m.deinit();
    // The srvmissile the Ice Bolt skill (Skills.txt Id 39) spawns. Columns cited: Vel/Range/
    // CollideType/CollideKill, read by NAME from the real 1.14d Missiles.txt row.
    const ib = m.byName("icebolt").?;
    try testing.expectEqual(@as(u16, 59), ib.id);
    try testing.expectEqual(@as(i32, 12), ib.vel); // Vel=12
    try testing.expectEqual(@as(i32, 50), ib.range); // Range=50
    try testing.expectEqual(@as(i32, 3), ib.collide_type); // CollideType=3 (units+walls)
    try testing.expect(ib.collide_kill); // CollideKill=1
    try testing.expectEqual(@as(u16, 59), m.byId(59).?.id); // and by numeric Id
}

test "create aims velocity toward the target and budgets range" {
    const data = MissileData{ .id = 58, .vel = 20, .range = 50, .collide_type = 3, .collide_kill = true };
    const m = Missile.create(data, 7, 0, 0, 100, 0, 5, 9);
    try testing.expectEqual(@as(i32, 20), m.vx); // straight along +X
    try testing.expectEqual(@as(i32, 0), m.vy);
    try testing.expectEqual(@as(i32, 50 * RANGE_SCALE), m.range_left);
    try testing.expectEqual(@as(u32, 7), m.owner_id);
}

test "zero-length aim defaults to +X (well-formed missile)" {
    const data = MissileData{ .id = 58, .vel = 20, .range = 50 };
    const m = Missile.create(data, 1, 40, 40, 40, 40, 1, 1);
    try testing.expectEqual(@as(i32, 20), m.vx);
    try testing.expectEqual(@as(i32, 0), m.vy);
}

test "step travels and eventually expires; canHit respects owner + radius" {
    const data = MissileData{ .id = 58, .vel = 20, .range = 2, .collide_type = 3, .collide_kill = true };
    var m = Missile.create(data, 1, 0, 0, 1000, 0, 3, 3);
    var owner = Unit.init(.player);
    owner.unit_id = 1;
    owner.x = 0;
    owner.y = 0;
    owner.setLife(100);
    try testing.expect(!m.canHit(&owner)); // never hits its owner
    var mob = Unit.init(.monster);
    mob.unit_id = 2;
    mob.x = 5;
    mob.y = 0;
    mob.setLife(50);
    try testing.expect(m.canHit(&mob)); // within collide radius
    // Travel until the budget (2*RANGE_SCALE=32 subtiles, 20/tick) runs out.
    var ticks: usize = 0;
    while (!m.expired() and ticks < 100) : (ticks += 1) m.step();
    try testing.expect(m.expired());
    try testing.expect(m.x > 0);
}
