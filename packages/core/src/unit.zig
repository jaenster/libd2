//! Unit model — the combat-relevant slice of D2UnitStrc.
//!
//! D2UnitStrc is the universal game-object record (players, monsters, missiles,
//! objects, items, tiles all share it, discriminated by dwUnitType). This is a
//! clean-room Zig-native subset holding exactly what the combat core reads:
//! type/id, position, owner, the stat list, and a weapon damage source.

const std = @import("std");
const stat = @import("stat.zig");
const collision = @import("collision.zig");
const wire = @import("wire/item.zig");

/// `eD2UnitType` (1.14d), `D2UnitStrc.eUnitType` at offset 0. One record type serves every game
/// object and this field discriminates it; `nClassId` at offset 4 then indexes the txt that owns
/// the kind — PlrClass, MonStats, Objects, Missiles, Items or LvlWarps respectively.
///
/// The combat core distinguishes player vs monster for the attack-rating path (monsters fold
/// dexterity*5 + tohit differently); `Collision` below distinguishes all six.
pub const UnitType = enum(u8) {
    player = 0,
    monster = 1,
    object = 2,
    missile = 3,
    item = 4,
    /// `UNIT_ROOMTILE` — the level transition: a staircase, a town portal's destination side, an
    /// act warp. The name is Blizzard's own, read off the D2R debug build's `eUnitType` name table
    /// at 0x1456ad6e8, which spells all six in order. Third-party headers call this one WARP or
    /// TILE; neither is what the game calls it.
    roomtile = 5,
    _,
};

/// What a unit writes into the collision grid while it is standing somewhere: which cells
/// (`stamp`), with which bit (`flag`), and what it is itself blocked by when it moves
/// (`path_mask`). The engine keeps all three on the unit — `D2DynamicPathStrc.nUnitWidth` (0x48),
/// `.nCollisionFlag` (0x4C) and `.nCollisionPattern` (0x50) — assigned once when the path is
/// allocated, which is what the constructors below reproduce.
///
/// The kind of stamp is decided by unit type and nothing else (`PATH_AddUnitCollision`, 0x649390):
/// players and monsters get a `Shape` because they claim ground; objects get a rectangle out of
/// Objects.txt; items, room tiles and missiles get a bare footprint.
pub const Collision = struct {
    stamp: collision.Stamp = .{ .shape = .none },
    flag: u16 = 0,
    path_mask: u16 = 0,

    /// `AllocDynamicPath` (0x6486a0) for a player: `nCollisionFlag = 0x80`,
    /// `nCollisionPattern = 0x1c09`. `size_x` is the unit's `GetUnitSizeX`.
    pub fn player(size_x: i32) Collision {
        return .{
            .stamp = .{ .shape = collisionShape(.player, size_x, false) },
            .flag = collision.Colbit.player,
            .path_mask = collision.Colmask.player_path,
        };
    }

    /// A player who is dead or dying. `Player.cpp` sets `SetUnitWidth(pUnit, 5)` and
    /// `PATH_SetCollisionPattern(path, 0)` at that point: the corpse still marks the ground it lies
    /// on so a search can find it, but it claims nothing and blocks nobody.
    pub fn corpse() Collision {
        return .{ .stamp = .{ .shape = .small_none }, .flag = collision.Colbit.player, .path_mask = 0 };
    }

    /// `AllocDynamicPath` for a monster: `nCollisionFlag = 0x100`, and the path mask comes from
    /// MonStats via `monsterPathMask`.
    ///
    /// `pet_like` is the engine's promotion test, which decides whether the monster claims ground
    /// with `pet` instead of `nopath` — see `collisionShape`.
    pub fn monster(size_x: i32, pet_like: bool, opts: MonsterOpts) Collision {
        return .{
            .stamp = .{ .shape = collisionShape(.monster, size_x, pet_like) },
            .flag = collision.Colbit.monster,
            .path_mask = monsterPathMask(opts),
        };
    }

    /// `GetCollisionType` (0x6209d0) for an object, which reads Objects.txt rather than the path,
    /// over the `SizeX x SizeY` rectangle `PATH_AddUnitCollision` hands `AddCollision_Vector`.
    pub fn object(size_x: i32, size_y: i32, txt: ObjectFlags) Collision {
        return .{
            .stamp = .{ .box = .{ .w = size_x, .h = size_y } },
            .flag = objectFlag(txt),
            .path_mask = 0,
        };
    }

    /// An item on the ground: `COLLIDE_ITEM` over its bare footprint, and nothing paths around it.
    pub fn item(size_x: i32) Collision {
        return .{ .stamp = .{ .width = sizeOf(size_x) }, .flag = collision.Colbit.item, .path_mask = 0 };
    }

    /// A missile in flight carries NO collision flag at all — `AllocDynamicPath` sets both
    /// `nCollisionFlag` and `nCollisionPattern` to 0 and the caller overwrites the mask from
    /// `Missiles.txt CollideType` (`PATH_SetCollisionPattern`, Missiles.cpp:348). Missiles are not
    /// in the grid; they are traced against it.
    pub fn missile(collide_mask: u16) Collision {
        return .{ .stamp = .{ .shape = .none }, .flag = 0, .path_mask = collide_mask };
    }

    /// A level transition. `GetCollisionType` returns `COLLIDE_BLOCK_PLAYER`, which is 0x01 —
    /// `wall` in the corrected bit vocabulary. A room tile is solid.
    pub fn roomtile(size_x: i32) Collision {
        return .{ .stamp = .{ .width = sizeOf(size_x) }, .flag = collision.Colbit.wall, .path_mask = 0 };
    }
};

/// `GetUnitSizeX`'s 0..3 result as the enum. Out of range is the engine's own fallback in
/// `AddCollision_Width`, which does nothing for a size it does not recognise.
pub fn sizeOf(size_x: i32) collision.Size {
    return switch (size_x) {
        1 => .point,
        2 => .small,
        3 => .big,
        else => .none,
    };
}

/// The MonStats columns `monsterPathMask` reads. Kept as plain inputs rather than a table lookup so
/// core stays free of txt parsing — the host already has the row in hand when it spawns the monster.
pub const MonsterOpts = struct {
    /// MonStats `flying`: the monster ignores ground entirely.
    flying: bool = false,
    /// MonStats `opendoors`: doors do not stop it, so `door` (0x800) leaves its mask.
    opendoors: bool = false,
};

/// The Objects.txt columns `objectFlag` reads.
pub const ObjectFlags = struct {
    is_door: bool = false,
    blocks_vis: bool = false,
    block_missile: bool = false,
    /// Objects.txt `SubClass` bit 2 (value 4) marks a corpse-like object.
    is_corpse: bool = false,
};

/// `PATH_GetCollisionPatternFromMonStats` (0x648450): what a monster is blocked BY.
///
///     if (!flying) return 0x3c01 - (opendoors ? 0x800 : 0);
///     return 0x1804;
///
/// So a walking monster gets `monster_path` (pet|nopath|door|object|wall), minus `door` if it can
/// open them; a flying one gets nopath|door|missile_barrier, which is why it crosses water and
/// chasms a walker cannot.
pub fn monsterPathMask(opts: MonsterOpts) u16 {
    if (opts.flying) return collision.Colbit.nopath | collision.Colbit.door | collision.Colbit.missile_barrier;
    const base = collision.Colmask.monster_path;
    return if (opts.opendoors) base & ~collision.Colbit.door else base;
}

/// `GetCollisionType` (0x6209d0)'s object branch.
pub fn objectFlag(txt: ObjectFlags) u16 {
    if (!txt.is_door) {
        if (txt.is_corpse) return collision.Colbit.dead;
        return collision.Colbit.object | (if (txt.block_missile) collision.Colbit.missile_barrier else 0);
    }
    if (txt.blocks_vis) return collision.Colbit.door | collision.Colbit.missile_barrier | collision.Colbit.visible;
    return if (txt.block_missile)
        collision.Colbit.door | collision.Colbit.missile_barrier
    else
        collision.Colbit.object;
}

/// `GetInteractSize` (0x648580): `GetUnitSizeX` -> the stamp shape.
///
///     gaUnitTypeInteractSizes[4] @0x6eb3dc = { none, small_unit, small_unit, big_unit }
///     SizeX > 3                            -> small_unit
///
/// and then one promotion, at 0x6485be: a MONSTER that is a boss or champion (0x63e860) and does
/// NOT carry the MonStats `interact` flag has `small_unit` promoted to `small_pet` and `big_unit`
/// to `big_pet`. Same shape, different presence bit — so it stops blocking players (whose mask has
/// no `pet`) while still blocking other monsters. `pet_like` is that test; it is always false for
/// anything that is not a monster.
pub fn collisionShape(unit_type: UnitType, size_x: i32, pet_like: bool) collision.Shape {
    const base: collision.Shape = switch (size_x) {
        0 => .none,
        1, 2 => .small_unit,
        3 => .big_unit,
        else => .small_unit,
    };
    if (unit_type != .monster or !pet_like) return base;
    return switch (base) {
        .small_unit => .small_pet,
        .big_unit => .big_pet,
        else => base,
    };
}

/// Base physical weapon damage source. In the engine these come from the equipped
/// weapon's Items.txt row (mindam/maxdam, StrBonus, DexBonus); a bare-handed unit
/// falls back to the mindamage(21)/maxdamage(22) stats. Values are whole (not the
/// engine's <<8 fixed-point) — the damage calc scales to <<8 internally.
pub const Weapon = struct {
    min_damage: i32 = 0,
    max_damage: i32 = 0,
    /// Items.txt StrBonus: percent damage per point of strength / 100.
    str_bonus: i32 = 0,
    /// Items.txt DexBonus: percent damage per point of dexterity / 100.
    dex_bonus: i32 = 0,
};

/// Sentinel `owner_id` meaning "no owner" — a hostile, un-summoned unit. A minion/pet carries its
/// summoner's unit_id here instead, which is how targeting/collision tell friend from foe.
pub const NO_OWNER: u32 = 0xFFFFFFFF;

/// Clean-room unit for combat resolution.
pub const Unit = struct {
    unit_type: UnitType = .monster,
    unit_id: u32 = 0,
    class_id: u32 = 0, // char class (player) or monster type id
    x: i32 = 0,
    y: i32 = 0,
    owner_id: u32 = NO_OWNER, // owner unit id (missiles/minions); none = NO_OWNER
    /// True while a burrowing monster (SandRaider / SandMaggot) is UNDERGROUND: it cannot be targeted
    /// or hit until it surfaces (the server-side stand-in for its invulnerable submerged phase).
    submerged: bool = false,
    stats: stat.StatList = .{},
    weapon: Weapon = .{},

    pub fn init(unit_type: UnitType) Unit {
        return .{ .unit_type = unit_type };
    }

    /// A summoned minion (skeleton / golem / valkyrie / …): a monster carrying a summoner's owner_id.
    pub fn isPet(self: *const Unit) bool {
        return self.unit_type == .monster and self.owner_id != NO_OWNER;
    }

    pub fn get(self: *const Unit, s: stat.Stat) i32 {
        return self.stats.get(s);
    }

    pub fn set(self: *Unit, s: stat.Stat, v: i32) void {
        self.stats.set(s, v);
    }

    pub fn level(self: *const Unit) i32 {
        return self.stats.get(.level);
    }

    /// Current life (whole). Engine stores hitpoints(6) as fixed-point <<8; this
    /// model keeps it whole for clarity — combat subtracts whole damage.
    pub fn life(self: *const Unit) i32 {
        return self.stats.get(.hitpoints);
    }

    pub fn setLife(self: *Unit, v: i32) void {
        self.stats.set(.hitpoints, v);
    }

    pub fn isAlive(self: *const Unit) bool {
        return self.life() > 0;
    }

    /// Advance the unit one tick toward (tx,ty) by up to `step` world units, snapping onto
    /// the target when within a single step. Returns true once arrived. Pure movement
    /// kinematics — the host does any wall routing (pathfinding) and calls this to walk the
    /// unit toward the next waypoint.
    pub fn stepToward(self: *Unit, tx: i32, ty: i32, step: i32) bool {
        const dx = tx - self.x;
        const dy = ty - self.y;
        const dist2 = dx * dx + dy * dy;
        if (dist2 <= step * step) {
            self.x = tx;
            self.y = ty;
            return true;
        }
        const dist = std.math.sqrt(@as(f64, @floatFromInt(dist2)));
        const fx = @as(f64, @floatFromInt(dx)) / dist;
        const fy = @as(f64, @floatFromInt(dy)) / dist;
        self.x += @intFromFloat(@round(fx * @as(f64, @floatFromInt(step))));
        self.y += @intFromFloat(@round(fy * @as(f64, @floatFromInt(step))));
        return false;
    }
};

/// Fold a decoded save/wire item's stats onto a unit's StatList, ACCUMULATING (items stack).
/// The ItemStatCost id and the `Stat` enum share ONE id space (both are the 1.14d
/// ItemStatCost.txt row indices — see stat.zig / wire/itemstatcost.zig), so the id -> Stat map is
/// the identity `@enumFromInt(id)`; no hand table. Ids past the backed stat range (NUM_STATS) are
/// silently dropped by StatList.add. Read the summed totals back off `unit.stats` afterward
/// (e.g. defense = get(.armorclass), fire = get(.fireresist), +skills = get(.allskills) +
/// get(.addclassskills)). The host owns any downstream difficulty penalty / quest reward / clamp.
pub fn applyItemStats(unit: *Unit, item: *const wire.Item) void {
    for (item.stats[0..item.n_stats]) |s| {
        unit.stats.add(@enumFromInt(s.id), s.value);
    }
}

test "applyItemStats accumulates decoded item stats by shared id space" {
    const testing = std.testing;
    var u = Unit.init(.player);
    var it = wire.Item{};
    it.stats[0] = .{ .id = 39, .value = 30 }; // fireresist
    it.stats[1] = .{ .id = 43, .value = 20 }; // coldresist
    it.n_stats = 2;
    u.set(.fireresist, 5); // pre-existing value proves ADD (not overwrite)
    applyItemStats(&u, &it);
    try testing.expectEqual(@as(i32, 35), u.get(.fireresist));
    try testing.expectEqual(@as(i32, 20), u.get(.coldresist));
}

test "unit basics" {
    const testing = std.testing;
    var u = Unit.init(.player);
    u.set(.level, 30);
    u.setLife(500);
    try testing.expectEqual(@as(i32, 30), u.level());
    try testing.expect(u.isAlive());
    u.setLife(0);
    try testing.expect(!u.isAlive());
}

test "stepToward advances by the step then snaps onto the target" {
    const testing = std.testing;
    var u = Unit.init(.monster);
    u.x = 0;
    u.y = 0;
    // Target far to the +X axis: one 10-unit step lands exactly at x=10, not reached.
    try testing.expect(!u.stepToward(100, 0, 10));
    try testing.expectEqual(@as(i32, 10), u.x);
    try testing.expectEqual(@as(i32, 0), u.y);
    // Diagonal step advances both axes and stays short of the target (not reached).
    u.x = 0;
    u.y = 0;
    try testing.expect(!u.stepToward(100, 100, 10));
    try testing.expect(u.x > 0 and u.x < 100 and u.y > 0 and u.y < 100);
    // Within one step of the target -> snap exactly onto it and report reached.
    u.x = 95;
    u.y = 0;
    try testing.expect(u.stepToward(100, 0, 10));
    try testing.expectEqual(@as(i32, 100), u.x);
    try testing.expectEqual(@as(i32, 0), u.y);
}
