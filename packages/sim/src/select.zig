//! Unit selection queries — pure spatial lookups over the host's live unit set.
//!
//! The host owns unit storage (a map or array); these helpers take its iterator plus a
//! predicate and RETURN the chosen unit pointer. Nothing is mutated. Mirrors the lib's
//! "pure decision, host applies" split: the query decides, the host acts on the result.

const std = @import("std");
const unit = @import("unit.zig");
const Unit = unit.Unit;

/// Squared distance between two points (world subtiles). i64 avoids the i32 overflow a
/// far-apart pair would hit.
pub fn dist2(ax: i32, ay: i32, bx: i32, by: i32) i64 {
    const dx: i64 = ax - bx;
    const dy: i64 = ay - by;
    return dx * dx + dy * dy;
}

/// Nearest unit to (x,y) among those `iter` yields for which `accept` is true. `iter` is any
/// pointer exposing `next() ?*Unit` (e.g. an AutoHashMap ValueIterator); it is consumed.
/// Returns the winning `*Unit` (the host may then target/mutate it), or null.
pub fn nearestMatching(iter: anytype, x: i32, y: i32, accept: *const fn (*const Unit) bool) ?*Unit {
    var best: ?*Unit = null;
    var best_d2: i64 = std.math.maxInt(i64);
    while (iter.next()) |u| {
        if (!accept(u)) continue;
        const d = dist2(u.x, u.y, x, y);
        if (d < best_d2) {
            best_d2 = d;
            best = u;
        }
    }
    return best;
}

/// Predicate: a live player unit (the monster-AI target filter).
pub fn isLivePlayer(u: *const Unit) bool {
    return u.unit_type == .player and u.isAlive();
}

/// Predicate: a live monster unit.
pub fn isLiveMonster(u: *const Unit) bool {
    return u.unit_type == .monster and u.isAlive();
}

const testing = std.testing;

const SliceIter = struct {
    items: []Unit,
    i: usize = 0,
    fn next(self: *SliceIter) ?*Unit {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return &self.items[self.i];
    }
};

test "nearestMatching returns the closest live player, ignoring monsters + the dead" {
    var units = [_]Unit{ Unit.init(.player), Unit.init(.monster), Unit.init(.player), Unit.init(.player) };
    units[0].x = 100; // live player, far
    units[0].y = 0;
    units[0].setLife(10);
    units[1].x = 3; // monster right next to origin — must be ignored
    units[1].y = 0;
    units[1].setLife(10);
    units[2].x = 20; // closest live player
    units[2].y = 0;
    units[2].setLife(10);
    units[3].x = 5; // dead player — ignored
    units[3].y = 0;
    units[3].setLife(0);

    var it = SliceIter{ .items = &units };
    const got = nearestMatching(&it, 0, 0, isLivePlayer).?;
    try testing.expectEqual(@as(i32, 20), got.x);
}

test "nearestMatching with no match returns null" {
    var units = [_]Unit{Unit.init(.monster)};
    units[0].setLife(10);
    var it = SliceIter{ .items = &units };
    try testing.expectEqual(@as(?*Unit, null), nearestMatching(&it, 0, 0, isLivePlayer));
}

test "dist2 is exact and overflow-safe for large coordinates" {
    try testing.expectEqual(@as(i64, 25), dist2(0, 0, 3, 4));
    try testing.expectEqual(@as(i64, 2_000_000_000), dist2(0, 0, 40000, 20000));
}
