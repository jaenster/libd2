//! The 1.14d collision-map vocabulary: the per-subtile flag bits and the named masks the
//! engine tests them with.
//!
//! This lives in core because it is the shared language of three otherwise unrelated layers —
//! d2-drlg produces collision grids, d2-pathfinding searches them, and a runtime host ORs the
//! unit-occupancy bits into them every frame. One definition, so a mask cannot drift between
//! the producer and the consumer.
//!
//! The names are Blizzard's, read off the D2R debug build's collision overlay (Ghidra session
//! eb3458d4, FUN_1403361c0), which switches on a single collision value and prints its
//! identifier — so the value/name binding is exact rather than inferred:
//!
//!     0x01 COLBIT_WALL      0x02 COLBIT_VISIBLE   0x04 COLBIT_MISSILE_BARRIER
//!     0x08 COLBIT_NOPLAYER  0x10 COLBIT_PRESET    0x40 COLBIT_MISSILE
//!     0x80 COLBIT_PLAYER    0x100 COLBIT_MONSTER  0x200 COLBIT_ITEM
//!     0x400 COLBIT_OBJECT   0x800 COLBIT_DOOR     0x1000 COLBIT_NOPATH
//!     0x8000 COLBIT_DEAD
//!
//! and the same switch names the composite masks below. These CORRECT the widely-copied d2bs
//! `LevelMap::CollisionFlag` labels, which shift the low four: d2bs calls 0x01 "BlockWalk" and
//! 0x04 "Wall", but 0x01 is WALL (and it is the bit that blocks walking) while 0x04 is the
//! missile barrier. Only the labels were ever wrong — the values match bit for bit, so grids
//! and goldens built against the old names are unaffected.

/// Per-subtile flag bits. The low bits are static terrain, baked into each DT1 tile's subtile
/// flag byte at map generation; the rest is runtime unit occupancy a live host maintains.
pub const Colbit = struct {
    /// Blocks walking. The primary terrain bit.
    pub const wall: u16 = 0x01;
    /// Blocks line of sight.
    pub const visible: u16 = 0x02;
    /// Blocks missiles, but not walking.
    pub const missile_barrier: u16 = 0x04;
    /// Blocks players only — monsters path straight through it, which is why
    /// `Colmask.monster_path` omits it. Town borders and similar soft fences use it.
    pub const noplayer: u16 = 0x08;
    /// Preset-tile marker (d2bs calls it "AlternateTile"). Not a movement blocker.
    pub const preset: u16 = 0x10;
    /// Carried by real terrain in the engine's own CollMap, and used by the render path as a
    /// "no floor tile here" marker. Not a movement blocker.
    pub const blank: u16 = 0x20;
    pub const missile: u16 = 0x40;
    pub const player: u16 = 0x80;
    pub const monster: u16 = 0x100;
    pub const item: u16 = 0x200;
    pub const object: u16 = 0x400;
    /// A door. Closed doors block; a host clears the bit when one opens.
    pub const door: u16 = 0x800;
    pub const nopath: u16 = 0x1000;
    pub const pet: u16 = 0x2000;
    /// Unnamed in the D2R overlay switch; present in `Colmask.placement` 0x3f11.
    pub const unk_4000: u16 = 0x4000;
    pub const dead: u16 = 0x8000;
};

/// Out-of-level fill: a subtile inside the level rectangle that no room covers. Map generation
/// emits 0xFFFF there, which is also `Colmask.any` — so every mask rejects it and void is
/// impassable for free, with no second "is this covered" array to carry around.
pub const VOID: u16 = 0xFFFF;

/// Collision bit combinations the engine names as masks (same D2R overlay switch as `Colbit`).
///
/// Where the engine reaches for them (1.14d Game.exe, Ghidra session 62fbfe69):
///   * `player_path` — `SUNIT_RelocateUnit` (0x554ea0), the server side of teleport, snaps the
///     landing cell with nopath|door|object|noplayer|wall, i.e. exactly 0x1c09.
///   * `missile_flight` — `SKILL_CheckMissileCollisionAtTarget` (0x4c7b20) tests a missile's
///     cell with missile_barrier|wall. Missiles ignore noplayer/object/door, which is why they
///     must not be traced with the player mask.
///   * `player_flying` — what `Skills_SrvDoFunc_027_Teleport` (0x5ca360) tests the destination
///     with on a `Levels.txt Teleport == 2` level: `PUSH 0x804` at 0x5ca3a6 into
///     `TestCollisionByCoordinates`. A teleporting player is stopped by doors and missile
///     barriers, and nothing else.
///
/// There is deliberately NO "line of sight" mask here. `SKILLS_HasLineOfSight` (0x645910) is a
/// thin wrapper over `Collision::TestCollision` that takes the mask from its CALLER, and the
/// call sites do not agree on one — so naming a canonical LOS mask would be inventing a
/// constant the game does not have.
pub const Colmask = struct {
    pub const monster_missile: u16 = 0x101;
    pub const misplaymoster: u16 = 0x1c0;
    pub const monster_path: u16 = 0x3c01;
    pub const player_flying: u16 = 0x804;
    pub const radial_barrier: u16 = 0x805;
    pub const player_path: u16 = 0x1c09;
    pub const spawn: u16 = 0x3e01;
    pub const placement: u16 = 0x3f11;
    pub const blocks_door: u16 = 0x8180;
    pub const any: u16 = 0xffff;

    /// Spelled inline by the engine rather than named in the overlay table:
    /// `SKILL_CheckMissileCollisionAtTarget` (0x4c7b20) passes `COLBIT_MISSILE_BARRIER|COLBIT_WALL`.
    pub const missile_flight: u16 = Colbit.missile_barrier | Colbit.wall;
};

/// True when a unit whose collision model is `mask` may occupy `cell`. `VOID` fails for every
/// mask because it has every bit set. This one line is the whole movement model: a walking
/// player, a walking monster and a flying missile are the same test with three different masks.
pub inline fn passable(cell: u16, mask: u16) bool {
    return cell & mask == 0;
}

/// Walkable for a normal player: blocked by wall (0x01), noplayer (0x08) or object (0x400).
/// The terrain half of `Colmask.player_path` — that mask adds the runtime door/nopath bits,
/// which a generated (unoccupied) grid never carries.
pub inline fn walkable(v: u16) bool {
    return (v & (Colbit.wall | Colbit.noplayer | Colbit.object)) == 0 and v != VOID;
}

/// `eD2CollisionUnitSize` — how much of the grid a unit's shape covers. Values are the engine's,
/// so a host that already carries `D2DynamicPathStrc.nUnitSize` casts it straight across.
pub const Size = enum(u8) {
    none = 0,
    /// The cell alone.
    point = 1,
    /// The cell plus its four cardinal neighbours — `CheckCollision_Cross` (0x64d100).
    small = 2,
    /// `[x-1, x+1] x [y-1, y+1]` — `CheckCollision_BoundingBox1` (0x64d4a0).
    big = 3,
};

/// `eD2CollisionShapeType` — the whole stamp a unit writes into the grid: a footprint painted with
/// the unit's class flag, and one rank inside it a PRESENCE bit. Read off the jump table of
/// `AddCollision_Type` (0x64ea90); `RemoveCollision_Type` (0x64ec10) undoes exactly the same.
///
/// The presence bit is what makes units block each other, and it is the reason `Colmask.player_path`
/// (0x1c09) contains neither `player` nor `monster`. Units collide through `nopath` (0x1000) — or
/// `pet` (0x2000), which only `Colmask.monster_path` tests, so a player walks through his own
/// minions and a monster does not. The class bits exist so that ASKING what is on a cell is one
/// array read, not so that movement can test them.
pub const Shape = enum(u8) {
    /// `COLLISION_PATTERN_NONE`: writes nothing. What a unit with `SizeX` 0 gets.
    none = 0,
    small_unit = 1,
    big_unit = 2,
    small_pet = 3,
    big_pet = 4,
    /// A small unit that claims no ground: the cross gets the class flag and no presence bit, so
    /// nothing paths around it. Items, and a player's corpse (`SetUnitWidth(pUnit, 5)` in
    /// `Player.cpp` when the death animation starts).
    small_none = 5,

    /// The footprint the class flag is painted over.
    pub fn footprint(self: Shape) Size {
        return switch (self) {
            .none => .none,
            .small_unit, .small_pet, .small_none => .small,
            .big_unit, .big_pet => .big,
        };
    }

    /// The presence bit and the footprint it is painted over — always one rank smaller than the
    /// class footprint. Null where the shape claims no ground.
    pub fn presence(self: Shape) ?struct { bit: u16, over: Size } {
        return switch (self) {
            .none, .small_none => null,
            .small_unit => .{ .bit = Colbit.nopath, .over = .point },
            .big_unit => .{ .bit = Colbit.nopath, .over = .small },
            .small_pet => .{ .bit = Colbit.pet, .over = .point },
            .big_pet => .{ .bit = Colbit.pet, .over = .small },
        };
    }
};

/// The bits every ground-claiming shape writes. Drop them from a path mask to get that mask's
/// TERRAIN-only answer, which is how a caller asks for a route that ignores who is standing where.
pub const PRESENCE_BITS: u16 = Colbit.nopath | Colbit.pet;

/// What a unit paints into the grid, and how. `PATH_AddUnitCollision` (0x649390) picks one of
/// exactly three, on unit type alone — everything else about the stamp is the flag it carries.
pub const Stamp = union(enum) {
    /// `AddCollision_Type` (0x64ea90). Players and monsters: a footprint plus a presence bit.
    shape: Shape,
    /// `AddCollision_Width` (0x64ea00). Missiles, items and warps: a bare footprint, no presence
    /// bit, so nothing paths around them.
    width: Size,
    /// `AddCollision_Vector` (0x64de30). Objects, whose extent is a `w x h` rectangle out of
    /// Objects.txt rather than one of the three unit footprints:
    ///
    ///     left = x - w/2   right = left + w - 1
    ///     bottom = y - h/2 top   = bottom + h - 1
    ///
    /// which is biased toward -x/-y on an even size, and degenerates to the single cell at 1x1.
    box: struct { w: i32, h: i32 },
};

/// The cells a `Size` covers, relative to its centre.
pub fn cellsOf(size: Size) []const [2]i32 {
    const point = [_][2]i32{.{ 0, 0 }};
    const small = [_][2]i32{ .{ 0, 0 }, .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    const big = [_][2]i32{
        .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
        .{ -1, 0 },  .{ 0, 0 },  .{ 1, 0 },
        .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
    };
    return switch (size) {
        .none => &.{},
        .point => &point,
        .small => &small,
        .big => &big,
    };
}

const std = @import("std");
const testing = std.testing;

test "walkable(): the player mask over the raw u16 CollMap" {
    try testing.expect(!walkable(Colbit.wall));
    try testing.expect(!walkable(Colbit.noplayer));
    try testing.expect(!walkable(Colbit.object));
    try testing.expect(!walkable(Colbit.wall | Colbit.missile_barrier)); // solid rock 0x05
    try testing.expect(walkable(0));
    try testing.expect(walkable(Colbit.visible));
    try testing.expect(walkable(Colbit.missile_barrier)); // 0x04 alone blocks missiles, not walk
    try testing.expect(walkable(Colbit.preset));
    try testing.expect(walkable(Colbit.blank));
    try testing.expect(walkable(Colbit.missile));
    try testing.expect(walkable(Colbit.player));
    try testing.expect(!walkable(VOID));
}

test "bit values are the DBM-verified layout" {
    try testing.expectEqual(@as(u16, 0x01), Colbit.wall);
    try testing.expectEqual(@as(u16, 0x04), Colbit.missile_barrier);
    try testing.expectEqual(@as(u16, 0x08), Colbit.noplayer);
    try testing.expectEqual(@as(u16, 0x20), Colbit.blank);
    try testing.expectEqual(@as(u16, 0x400), Colbit.object);
}

test "the named masks decompose into the bits the D2R overlay prints" {
    try testing.expectEqual(
        Colmask.player_path,
        Colbit.nopath | Colbit.door | Colbit.object | Colbit.noplayer | Colbit.wall,
    );
    // A monster ignores NOPLAYER (that is the whole point of the bit) and adds PET.
    try testing.expectEqual(
        Colmask.monster_path,
        Colbit.pet | Colbit.nopath | Colbit.door | Colbit.object | Colbit.wall,
    );
    try testing.expectEqual(Colmask.monster_missile, Colbit.monster | Colbit.wall);
    try testing.expectEqual(@as(u16, 0x05), Colmask.missile_flight);
}

test "a missile passes cells a player cannot, and vice versa" {
    // An object blocks the player but not a missile in flight.
    try testing.expect(!passable(Colbit.object, Colmask.player_path));
    try testing.expect(passable(Colbit.object, Colmask.missile_flight));
    // A missile barrier stops the missile and lets the player walk through.
    try testing.expect(passable(Colbit.missile_barrier, Colmask.player_path));
    try testing.expect(!passable(Colbit.missile_barrier, Colmask.missile_flight));
    // Void stops everything.
    try testing.expect(!passable(VOID, Colmask.player_path));
    try testing.expect(!passable(VOID, Colmask.missile_flight));
}
