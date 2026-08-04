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

/// Radii are clamped here before anything else — `Units::TestCollision` (0x622920) does the same,
/// so a Baal and a Fallen are treated identically once both are at least this wide.
pub const MAX_UNIT_RADIUS: i32 = 2;

/// Can a unit at `a` of radius `a_size` reach one at `b` of radius `b_size` without the terrain
/// in between stopping it? This is `Units::TestCollision` (0x622920), which backs
/// `TestCollisionBetweenInteractingUnits` (0x622b50) and so `UNITMODE_IsTargetInActionRange` and
/// `PLAYER_InteractWithObject`/`InteractWithUnit`.
///
/// It is not a plain trace between two points. Both radii are clamped to 2; if the MANHATTAN
/// distance is under their sum the units are already close enough that the engine reports no
/// collision at all; otherwise each endpoint is pulled in by its own radius along the dominant
/// axis before the segment is traced — you aim at a monster's edge, not its centre.
pub fn unitsCanReach(pm: *const grid.PassMap, a: Point, a_size: i32, b: Point, b_size: i32) bool {
    const ra = @min(a_size, MAX_UNIT_RADIUS);
    const rb = @min(b_size, MAX_UNIT_RADIUS);
    const dx: i32 = @intCast(@abs(b.x - a.x));
    const dy: i32 = @intCast(@abs(b.y - a.y));
    if (dx + dy < ra + rb) return true;

    var ax = a.x;
    var ay = a.y;
    var bx = b.x;
    var by = b.y;
    if (ra != 0 or rb != 0) {
        var done = false;
        if (dy <= dx) {
            if (a.x < b.x) {
                ax += ra;
                bx -= rb;
            } else {
                ax -= ra;
                bx += rb;
            }
            done = dy < dx;
        }
        // On a perfect diagonal the engine adjusts BOTH axes: the dy <= dx branch falls through.
        if (!done) {
            if (a.y < b.y) {
                ay += ra;
                by -= rb;
            } else {
                ay -= ra;
                by += rb;
            }
        }
    }
    return !grid.trace(pm, .{ .x = ax, .y = ay }, .{ .x = bx, .y = by }).blocked;
}

/// A cell you could stand in and attack from.
pub const Spot = struct {
    at: Point,
    /// Chebyshev distance to the target, which is the axis the range gate measures.
    dist: i32,
    /// Distance to the nearest wall. Higher is roomier — see `ranking` below.
    clearance: u8,
};

pub const AttackOptions = struct {
    /// Closest you are willing to stand. 0 for melee.
    min_range: i32 = 0,
    /// Furthest. Capped by the packet handler's gate for anything cast at a location.
    max_range: i32 = grid.ENGINE_MAX_COMMAND_RANGE,
    /// The mask the skill's line of sight is traced with.
    los: LineOfSight = .barrier,
    /// The shape the attacker occupies while standing there.
    footprint: grid.Footprint = .point,
    /// Radii for the `unitsCanReach` segment shrink.
    self_size: i32 = 1,
    target_size: i32 = 1,
    /// Stop after this many, best first.
    limit: usize = 32,
};

/// Cells within range of `target` that the attacker fits in and can see it from, best first.
///
/// The gates are the engine's: the footprint must fit (`CheckCollision_*_Type`), the range is the
/// packet handler's per-axis Chebyshev, and the sight line is `Units::TestCollision`'s shrunk
/// segment traced target-to-attacker, the direction the server uses.
///
/// The RANKING is ours and not the engine's: roomier first (a cell hugging a wall is where the
/// client and server disagree about where you ended up), then closer. Caller owns the result.
pub fn attackPositions(
    alloc: std.mem.Allocator,
    lv: *Level,
    target: Point,
    opts: AttackOptions,
) ![]Spot {
    var out: std.ArrayListUnmanaged(Spot) = .empty;
    errdefer out.deinit(alloc);

    const mask = opts.los.mask() orelse return out.toOwnedSlice(alloc);
    const sight = try lv.passMapFor(mask, .point);
    const stand = try lv.passMapFor(collision.Colmask.player_path, opts.footprint);
    const clear = stand.clearance();

    var y = target.y - opts.max_range;
    while (y <= target.y + opts.max_range) : (y += 1) {
        var x = target.x - opts.max_range;
        while (x <= target.x + opts.max_range) : (x += 1) {
            const d: i32 = @intCast(@max(@abs(x - target.x), @abs(y - target.y)));
            if (d < opts.min_range or d > opts.max_range) continue;
            if (!stand.passable(x, y)) continue;
            const at = Point{ .x = x, .y = y };
            if (!unitsCanReach(sight, target, opts.target_size, at, opts.self_size)) continue;
            try out.append(alloc, .{
                .at = at,
                .dist = d,
                .clearance = clear[stand.index(x, y)],
            });
        }
    }

    const rank = struct {
        fn lessThan(_: void, a: Spot, b: Spot) bool {
            if (a.clearance != b.clearance) return a.clearance > b.clearance;
            return a.dist < b.dist;
        }
    }.lessThan;
    std.mem.sort(Spot, out.items, {}, rank);
    if (out.items.len > opts.limit) out.shrinkRetainingCapacity(opts.limit);
    return out.toOwnedSlice(alloc);
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
