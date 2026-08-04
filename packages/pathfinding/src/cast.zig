//! Whether the server would actually let a skill go off at a target.
//!
//! A bot that only asks "can I walk there" casts into walls. `SKILLS_SrvStartSkill` (0x56f701
//! onward) resolves the aim point with `SKILLS_GetTargetOrCursorPos` (0x56d2c0) — the locked
//! target's position, or the caster's own cursor position when there is no target — and then, if
//! that resolved, runs a line-of-sight test. Fail it and the skill is rejected silently: no
//! packet comes back saying why, which is exactly the failure kolbot papers over with retries.

const std = @import("std");
const grid = @import("grid.zig");
const collision = @import("d2-core").collision;
const teleport = @import("teleport.zig");
const Level = @import("level.zig").Level;
const Point = grid.Point;

/// The Skills.txt `lineofsight` column (`D2SkillsTxt` +0x18f), which selects WHICH collision mask
/// the cast is traced with. `SKILLS_SrvStartSkill` switches on `lineofsight - 1` over a five-entry
/// jump table at 0x56f7dc; anything outside 1..5 falls through to the reject path, so a skill that
/// reaches the check with 0 here cannot be cast at all.
pub const LineOfSight = enum(u8) {
    /// Not one of the five table entries. Reaches the check only to be rejected.
    none = 0,
    /// 1 -> 0x004: stopped by a missile barrier alone.
    missile_barrier = 1,
    /// 2 -> 0x1c09: the full walking mask, `Colmask.player_path`.
    player_path = 2,
    /// 3 -> 0x180: other units block it — player 0x80 | monster 0x100.
    units = 3,
    /// 4 -> 0x804: `Colmask.player_flying`, doors and missile barriers.
    flying = 4,
    /// 5 -> 0x805: `Colmask.radial_barrier`, walls, missile barriers and doors. What every
    /// caller other than the table itself passes, and the ordinary case.
    barrier = 5,

    pub fn mask(self: LineOfSight) ?u16 {
        return switch (self) {
            .none => null,
            .missile_barrier => 0x004,
            .player_path => 0x1c09,
            .units => 0x180,
            .flying => 0x804,
            .barrier => 0x805,
        };
    }
};

/// Why a cast would be refused, or `.ok`. Named for the gate that rejects it, because each one
/// wants a different fix: move closer, move to the other side of a wall, pick another target.
pub const Verdict = enum {
    ok,
    /// Beyond `CheckIfCoordsAreInRange` (0x548ef0): Chebyshev, per axis, not a radius.
    out_of_range,
    /// The mask traced from the target back to the caster hit something.
    no_line_of_sight,
    /// The skill's `lineofsight` column is not one of the five the jump table handles.
    no_line_of_sight_rule,
};

/// Would `SKILLS_SrvStartSkill` start this skill, cast from `from` at `to`?
///
/// Two gates, in the order the server applies them. First the packet handler's range check, which
/// is per-axis Chebyshev against 50 subtiles — a (50,50) diagonal is legal even though it spans
/// ~70 subtiles of ground. Then the line-of-sight trace with the mask `los` selects.
///
/// DIRECTION MATTERS. The engine traces from the AIM POINT to the CASTER, not the other way
/// round: `SKILLS_HasLineOfSightToUnit` (0x645950) puts the passed coordinates in `ptSrc` and the
/// unit's own position in `ptDest`. Bresenham visits a different chain of cells depending on which
/// end it starts from, so asking this backwards can disagree with the server about a thin
/// obstacle. `to -> from` here is deliberate.
///
/// Teleport has a third gate this does not cover — the destination must be in the caster's room or
/// one adjacent to it. See `rooms.zig` and `canTeleportTo` below.
pub fn canCastAt(lv: *Level, from: Point, to: Point, los: LineOfSight, max_cast: i32) !Verdict {
    if (@abs(to.x - from.x) > max_cast or @abs(to.y - from.y) > max_cast) return .out_of_range;
    const mask = los.mask() orelse return .no_line_of_sight_rule;
    const pm = try lv.passMapFor(mask, .point);
    if (!grid.hasLineOfSight(pm, to, from)) return .no_line_of_sight;
    return .ok;
}

/// The ordinary case: a skill with `lineofsight = 5` at the engine's own cast range.
pub fn canCast(lv: *Level, from: Point, to: Point) !Verdict {
    return canCastAt(lv, from, to, .barrier, teleport.ENGINE_MAX_CAST);
}

/// Teleport's own three gates: the range check, the room rule (`DRLGROOM_FindBetterNearbyRoom`
/// resolves the destination room from the caster's adjacency list, so landing outside it fails),
/// and a landing cell a player may stand on.
pub fn canTeleportTo(lv: *Level, from: Point, to: Point, max_cast: i32) !bool {
    if (lv.teleport == .forbidden) return false;
    if (@abs(to.x - from.x) > max_cast or @abs(to.y - from.y) > max_cast) return false;
    const from_room = lv.rooms.atSubtile(from.x, from.y) orelse return false;
    const to_room = lv.rooms.atSubtile(to.x, to.y) orelse return false;
    if (!lv.rooms.canTeleportBetween(from_room, to_room)) return false;
    const pm = try lv.passMapFor(lv.teleport.destinationMask(collision.Colmask.player_path), .point);
    return pm.passable(to.x, to.y);
}

const testing = std.testing;

test "the lineofsight column maps to the masks the jump table selects" {
    try testing.expectEqual(@as(?u16, null), LineOfSight.none.mask());
    try testing.expectEqual(@as(?u16, 0x004), LineOfSight.missile_barrier.mask());
    try testing.expectEqual(@as(?u16, 0x1c09), LineOfSight.player_path.mask());
    try testing.expectEqual(@as(?u16, 0x180), LineOfSight.units.mask());
    try testing.expectEqual(@as(?u16, 0x804), LineOfSight.flying.mask());
    try testing.expectEqual(@as(?u16, 0x805), LineOfSight.barrier.mask());
}
