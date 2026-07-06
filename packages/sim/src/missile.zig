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
const txt = @import("txt.zig");

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
};

/// Loaded Missiles.txt, indexed by the lowercase "Missile" name (skills reference it
/// via srvmissile) and by numeric Id.
pub const Missiles = struct {
    table: txt.Table,

    pub const EMBEDDED = @embedFile("excel/Missiles.txt");

    pub fn load(gpa: std.mem.Allocator) !Missiles {
        return .{ .table = try txt.Table.parse(gpa, EMBEDDED) };
    }
    pub fn parse(gpa: std.mem.Allocator, src: []const u8) !Missiles {
        return .{ .table = try txt.Table.parse(gpa, src) };
    }
    pub fn deinit(self: *Missiles) void {
        self.table.deinit();
    }

    fn rowData(self: *const Missiles, row: usize) MissileData {
        const t = &self.table;
        const ct = t.int(row, "CollideType");
        return .{
            .id = @intCast(t.int(row, "Id")),
            .vel = @intCast(t.int(row, "Vel")),
            .range = @intCast(t.int(row, "Range")),
            .collide_type = @intCast(ct),
            .collide_kill = t.int(row, "CollideKill") != 0,
            .min_damage = @intCast(t.int(row, "MinDamage")),
            .max_damage = @intCast(t.int(row, "MaxDamage")),
        };
    }

    /// Look up a missile by its Missiles.txt "Missile" name (skill srvmissile ref).
    pub fn byName(self: *const Missiles, name: []const u8) ?MissileData {
        const row = self.table.findByStr("Missile", name) orelse return null;
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
    range_left: i32 = 0,
    collide_radius: i32 = MIN_COLLIDE,
    collide_type: i32 = 0,
    collide_kill: bool = true,
    dmg_min: i32 = 0,
    dmg_max: i32 = 0,

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
            .range_left = @max(1, data.range) * RANGE_SCALE,
            .collide_radius = @max(MIN_COLLIDE, vel),
            .collide_type = data.collide_type,
            .collide_kill = data.collide_kill,
            .dmg_min = dmg_min,
            .dmg_max = dmg_max,
        };
    }

    /// Advance one tick: translate by velocity and spend the distance budget.
    pub fn step(self: *Missile) void {
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
        if (u.unit_id == self.owner_id) return false;
        const dx = u.x - self.x;
        const dy = u.y - self.y;
        return dx * dx + dy * dy <= self.collide_radius * self.collide_radius;
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

/// Advance every missile one tick over the host's slice. For each missile, `ctx.target(m)`
/// returns the unit it collides with (the host owns unit storage AND the target policy — e.g.
/// "monsters only"); the rolled damage is applied to that victim's life, then the missile
/// steps + expiry-checks. Retired missiles (killed on collision or out of range) are compacted
/// out of the FRONT of the slice, preserving order; the surviving count is returned so the
/// host can shrink its ArrayList. The host keeps the collection; the lib only rewrites the
/// slice window and mutates victim life (same contract as combat.attackAndApply).
pub fn stepAll(missiles: []Missile, seed: *Seed, ctx: anytype) usize {
    var w: usize = 0;
    for (missiles) |src| {
        var m = src;
        var retire = false;
        if (ctx.target(&m)) |victim| {
            const dmg = m.rollDamage(seed);
            combat.applyToLife(victim, dmg);
            if (m.collide_kill) retire = true;
        }
        if (!retire) {
            m.step();
            if (m.expired()) retire = true;
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
