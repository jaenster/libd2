//! Unit motion — how a unit actually travels between subtiles.
//!
//! A D2 unit does not teleport from cell to cell. It carries a dynamic path: a list of waypoints,
//! a scalar velocity, and a 16.16 fixed-point position that something advances once per game
//! frame. Everything visible about movement — how fast a character crosses a room, when it counts
//! as arrived, which of the 64 facings it shows — falls out of that stepping.
//!
//! This matters clientless. A real client runs this same simulation locally, which is why it can
//! issue a command from a position it KNOWS rather than one it was last told. A client that only
//! reacts to position packets is blind between them, and re-aims from a stale cell; the server's
//! movement is silent until it chooses to speak.
//!
//! Ported from `DRLGPATH_AdvanceAlongPathPoints` (0x64fe40) and `DRLGPATH_CalcDirectionVector`
//! (0x64fc60), with the direction table lifted verbatim from `gaPathCalcDirectionVectorX` /
//! `gnDrlgPathDirectionX` (0x6eb7e0, 128 rows of three int32).

const std = @import("std");

/// Positions are 16.16 fixed point: the low word is the fraction of a subtile.
pub const ONE: i32 = 0x10000;
/// A waypoint names a CELL, and a unit walks to that cell's CENTRE — hence the half.
pub const HALF: i32 = 0x8000;

/// Direction vectors are scaled by 1<<12, so a cardinal component is 4096 and a diagonal 2896.
pub const VEC_ONE: i32 = 4096;

/// What one subtile per frame costs in `velocity`.
///
/// The per-frame displacement is `velocity * vec >> 8`, and a cardinal `vec` is `VEC_ONE`, so the
/// displacement in 16.16 is `velocity * 16`. A whole subtile is `ONE`, hence this. Useful mostly
/// as a sanity anchor: a character running about thirteen subtiles a second at 25 frames is a
/// velocity somewhere near half of it, not thirteen of anything.
pub const VELOCITY_PER_SUBTILE: i32 = ONE / (VEC_ONE / 256);

pub fn centreOf(cell: i32) i32 {
    return cell *% ONE +% HALF;
}

pub fn cellOf(fp: i32) i32 {
    return @bitCast(@as(u32, @bitCast(fp)) >> 16);
}

pub const Point = struct { x: i32, y: i32 };

/// One row of the engine's direction table: the two vector components and the base facing.
const Row = struct { major: i32, minor: i32, dir: i32 };

const TABLE = [128]Row{
    .{ .major = 0, .minor = 4096, .dir = 0 },
    .{ .major = 32, .minor = 4095, .dir = 0 },
    .{ .major = 64, .minor = 4095, .dir = 0 },
    .{ .major = 96, .minor = 4094, .dir = 0 },
    .{ .major = 128, .minor = 4093, .dir = 0 },
    .{ .major = 161, .minor = 4092, .dir = 0 },
    .{ .major = 193, .minor = 4091, .dir = 0 },
    .{ .major = 225, .minor = 4089, .dir = 0 },
    .{ .major = 257, .minor = 4087, .dir = 0 },
    .{ .major = 289, .minor = 4085, .dir = 0 },
    .{ .major = 321, .minor = 4083, .dir = 0 },
    .{ .major = 353, .minor = 4080, .dir = 0 },
    .{ .major = 385, .minor = 4077, .dir = 0 },
    .{ .major = 417, .minor = 4074, .dir = 1 },
    .{ .major = 448, .minor = 4071, .dir = 1 },
    .{ .major = 480, .minor = 4067, .dir = 1 },
    .{ .major = 511, .minor = 4063, .dir = 1 },
    .{ .major = 543, .minor = 4059, .dir = 1 },
    .{ .major = 574, .minor = 4055, .dir = 1 },
    .{ .major = 606, .minor = 4050, .dir = 1 },
    .{ .major = 637, .minor = 4046, .dir = 1 },
    .{ .major = 668, .minor = 4041, .dir = 1 },
    .{ .major = 699, .minor = 4035, .dir = 1 },
    .{ .major = 729, .minor = 4030, .dir = 1 },
    .{ .major = 760, .minor = 4024, .dir = 1 },
    .{ .major = 791, .minor = 4018, .dir = 1 },
    .{ .major = 821, .minor = 4012, .dir = 2 },
    .{ .major = 851, .minor = 4006, .dir = 2 },
    .{ .major = 881, .minor = 3999, .dir = 2 },
    .{ .major = 911, .minor = 3993, .dir = 2 },
    .{ .major = 941, .minor = 3986, .dir = 2 },
    .{ .major = 971, .minor = 3979, .dir = 2 },
    .{ .major = 1000, .minor = 3971, .dir = 2 },
    .{ .major = 1030, .minor = 3964, .dir = 2 },
    .{ .major = 1059, .minor = 3956, .dir = 2 },
    .{ .major = 1088, .minor = 3948, .dir = 2 },
    .{ .major = 1117, .minor = 3940, .dir = 2 },
    .{ .major = 1145, .minor = 3932, .dir = 2 },
    .{ .major = 1174, .minor = 3924, .dir = 2 },
    .{ .major = 1202, .minor = 3915, .dir = 3 },
    .{ .major = 1230, .minor = 3906, .dir = 3 },
    .{ .major = 1258, .minor = 3897, .dir = 3 },
    .{ .major = 1286, .minor = 3888, .dir = 3 },
    .{ .major = 1313, .minor = 3879, .dir = 3 },
    .{ .major = 1340, .minor = 3870, .dir = 3 },
    .{ .major = 1368, .minor = 3860, .dir = 3 },
    .{ .major = 1394, .minor = 3851, .dir = 3 },
    .{ .major = 1421, .minor = 3841, .dir = 3 },
    .{ .major = 1448, .minor = 3831, .dir = 3 },
    .{ .major = 1474, .minor = 3821, .dir = 3 },
    .{ .major = 1500, .minor = 3811, .dir = 3 },
    .{ .major = 1526, .minor = 3800, .dir = 3 },
    .{ .major = 1552, .minor = 3790, .dir = 3 },
    .{ .major = 1577, .minor = 3780, .dir = 4 },
    .{ .major = 1602, .minor = 3769, .dir = 4 },
    .{ .major = 1627, .minor = 3758, .dir = 4 },
    .{ .major = 1652, .minor = 3747, .dir = 4 },
    .{ .major = 1677, .minor = 3736, .dir = 4 },
    .{ .major = 1701, .minor = 3725, .dir = 4 },
    .{ .major = 1725, .minor = 3714, .dir = 4 },
    .{ .major = 1749, .minor = 3703, .dir = 4 },
    .{ .major = 1773, .minor = 3692, .dir = 4 },
    .{ .major = 1796, .minor = 3680, .dir = 4 },
    .{ .major = 1820, .minor = 3669, .dir = 4 },
    .{ .major = 1843, .minor = 3657, .dir = 4 },
    .{ .major = 1866, .minor = 3646, .dir = 4 },
    .{ .major = 1888, .minor = 3634, .dir = 4 },
    .{ .major = 1911, .minor = 3622, .dir = 4 },
    .{ .major = 1933, .minor = 3610, .dir = 5 },
    .{ .major = 1955, .minor = 3599, .dir = 5 },
    .{ .major = 1977, .minor = 3587, .dir = 5 },
    .{ .major = 1998, .minor = 3575, .dir = 5 },
    .{ .major = 2020, .minor = 3563, .dir = 5 },
    .{ .major = 2041, .minor = 3551, .dir = 5 },
    .{ .major = 2062, .minor = 3539, .dir = 5 },
    .{ .major = 2082, .minor = 3526, .dir = 5 },
    .{ .major = 2103, .minor = 3514, .dir = 5 },
    .{ .major = 2123, .minor = 3502, .dir = 5 },
    .{ .major = 2143, .minor = 3490, .dir = 5 },
    .{ .major = 2163, .minor = 3478, .dir = 5 },
    .{ .major = 2183, .minor = 3465, .dir = 5 },
    .{ .major = 2202, .minor = 3453, .dir = 5 },
    .{ .major = 2221, .minor = 3441, .dir = 5 },
    .{ .major = 2240, .minor = 3428, .dir = 5 },
    .{ .major = 2259, .minor = 3416, .dir = 5 },
    .{ .major = 2278, .minor = 3403, .dir = 6 },
    .{ .major = 2296, .minor = 3391, .dir = 6 },
    .{ .major = 2314, .minor = 3379, .dir = 6 },
    .{ .major = 2332, .minor = 3366, .dir = 6 },
    .{ .major = 2350, .minor = 3354, .dir = 6 },
    .{ .major = 2368, .minor = 3341, .dir = 6 },
    .{ .major = 2385, .minor = 3329, .dir = 6 },
    .{ .major = 2402, .minor = 3317, .dir = 6 },
    .{ .major = 2419, .minor = 3304, .dir = 6 },
    .{ .major = 2436, .minor = 3292, .dir = 6 },
    .{ .major = 2453, .minor = 3279, .dir = 6 },
    .{ .major = 2469, .minor = 3267, .dir = 6 },
    .{ .major = 2486, .minor = 3255, .dir = 6 },
    .{ .major = 2502, .minor = 3242, .dir = 6 },
    .{ .major = 2518, .minor = 3230, .dir = 6 },
    .{ .major = 2533, .minor = 3218, .dir = 6 },
    .{ .major = 2549, .minor = 3205, .dir = 6 },
    .{ .major = 2564, .minor = 3193, .dir = 6 },
    .{ .major = 2580, .minor = 3181, .dir = 6 },
    .{ .major = 2595, .minor = 3169, .dir = 6 },
    .{ .major = 2609, .minor = 3156, .dir = 7 },
    .{ .major = 2624, .minor = 3144, .dir = 7 },
    .{ .major = 2639, .minor = 3132, .dir = 7 },
    .{ .major = 2653, .minor = 3120, .dir = 7 },
    .{ .major = 2667, .minor = 3108, .dir = 7 },
    .{ .major = 2681, .minor = 3096, .dir = 7 },
    .{ .major = 2695, .minor = 3084, .dir = 7 },
    .{ .major = 2709, .minor = 3072, .dir = 7 },
    .{ .major = 2722, .minor = 3060, .dir = 7 },
    .{ .major = 2736, .minor = 3048, .dir = 7 },
    .{ .major = 2749, .minor = 3036, .dir = 7 },
    .{ .major = 2762, .minor = 3024, .dir = 7 },
    .{ .major = 2775, .minor = 3012, .dir = 7 },
    .{ .major = 2788, .minor = 3000, .dir = 7 },
    .{ .major = 2800, .minor = 2988, .dir = 7 },
    .{ .major = 2813, .minor = 2977, .dir = 7 },
    .{ .major = 2825, .minor = 2965, .dir = 7 },
    .{ .major = 2837, .minor = 2953, .dir = 7 },
    .{ .major = 2849, .minor = 2942, .dir = 7 },
    .{ .major = 2861, .minor = 2930, .dir = 7 },
    .{ .major = 2873, .minor = 2919, .dir = 7 },
    .{ .major = 2884, .minor = 2907, .dir = 7 },
    .{ .major = 2896, .minor = 2896, .dir = 7 },
};

pub const Direction = struct {
    /// Unit vector scaled by `VEC_ONE`.
    vec: Point,
    /// 0..63, the facing the engine sends on the wire.
    index: u8,
};

/// `DRLGPATH_CalcDirectionVector` — the direction from one 16.16 point to another.
///
/// Works on the dominant axis: the minor/major ratio picks a row of the table, and the octant is
/// restored afterwards by swapping the components and negating. The index arithmetic below is the
/// engine's, masks and all — the `-x - 1` forms are how it mirrors a facing rather than negating
/// it, and rewriting them as arithmetic that "looks right" changes the answer.
pub fn directionTo(from_x: i32, from_y: i32, to_x: i32, to_y: i32) Direction {
    var min_x: u32 = @bitCast(from_x);
    var max_x: u32 = @bitCast(to_x);
    const swapped_x = max_x < min_x;
    if (swapped_x) {
        min_x = @bitCast(to_x);
        max_x = @bitCast(from_x);
    }

    var max_y: u32 = @bitCast(from_y);
    var min_y: u32 = @bitCast(to_y);
    if (@as(u32, @bitCast(to_y)) >= @as(u32, @bitCast(from_y))) {
        max_y = @bitCast(to_y);
        min_y = @bitCast(from_y);
    }

    const major_is_y = @as(i32, @bitCast(max_x -% min_x)) <= @as(i32, @bitCast(max_y -% min_y));
    var major_max = max_y;
    var minor_min = min_y;
    var span_hi = max_x;
    var span_lo = min_x;
    if (major_is_y) {
        major_max = max_x;
        span_hi = max_y;
        minor_min = min_x;
        span_lo = min_y;
    }

    const span = span_hi -% span_lo;
    const ratio: usize = if (span == 0)
        0
    else
        @intCast(@divTrunc(@as(i32, @bitCast((major_max -% minor_min) *% 0x7f)), @as(i32, @bitCast(span))));
    const row = TABLE[@min(ratio, TABLE.len - 1)];

    var vec: Point = undefined;
    var dir: i32 = row.dir;
    if (major_is_y) {
        vec.x = row.major;
        vec.y = row.minor;
    } else {
        vec.y = row.major;
        vec.x = row.minor;
        dir = -dir - 1 & 0xf;
    }
    if (@as(u32, @bitCast(to_y)) < @as(u32, @bitCast(from_y))) {
        vec.y = -vec.y;
        dir = -dir - 1 & 0x1f;
    }
    if (swapped_x) {
        vec.x = -vec.x;
        dir = dir + 8 & 0x3f;
    } else {
        dir = (-dir - 1 & 0x3f) + 8 & 0x3f;
    }
    return .{ .vec = vec, .index = @intCast(dir & 0x3f) };
}

/// A unit in motion along a list of waypoints.
///
/// `velocity` is the engine's `dwVelocity`; the per-frame displacement is `velocity * vec >> 8`.
pub const Motion = struct {
    /// Waypoints, in CELLS. The unit walks to each one's centre in turn.
    points: []const Point,
    /// Which waypoint we are heading for. Equal to `points.len` once the walk is finished.
    index: usize = 0,
    /// Where the unit is, 16.16.
    x: i32,
    y: i32,
    velocity: i32,
    vel_x: i32 = 0,
    vel_y: i32 = 0,
    dir: Point = .{ .x = 0, .y = 0 },
    facing: u8 = 0,
    /// `nFlags & 0x200` — walking backwards, which rotates the facing by half a turn.
    reversed: bool = false,

    pub fn done(self: *const Motion) bool {
        return self.index >= self.points.len;
    }

    /// Advance one frame. Returns true when the unit lands on the waypoint it was heading for —
    /// which for the LAST waypoint means the walk is over and velocity has been zeroed.
    pub fn advance(self: *Motion) bool {
        if (self.points.len == 0) return true;
        if (self.index >= self.points.len) return true;

        var target_x = centreOf(self.points[self.index].x);
        var target_y = centreOf(self.points[self.index].y);

        // Already standing on this waypoint: walk the list forward until one is somewhere else.
        while (target_x == self.x and target_y == self.y) {
            if (self.index + 1 >= self.points.len) {
                self.dir = .{ .x = 0, .y = 0 };
                self.vel_x = 0;
                self.vel_y = 0;
                self.velocity = 0;
                self.index = self.points.len;
                return true;
            }
            self.index += 1;
            target_x = centreOf(self.points[self.index].x);
            target_y = centreOf(self.points[self.index].y);
        }

        const d = directionTo(self.x, self.y, target_x, target_y);
        self.dir = d.vec;
        self.facing = if (self.reversed) @intCast((@as(i32, d.index) - 0x20) & 0x3f) else d.index;

        self.vel_x = @intCast(@divTrunc(@as(i64, self.velocity) * d.vec.x, 256));
        self.vel_y = @intCast(@divTrunc(@as(i64, self.velocity) * d.vec.y, 256));

        // "Reached" is a question about CELLS, not exact equality: the step lands inside the
        // waypoint's subtile. The engine compares the high words, and so do we.
        const reached = cellOf(target_x) == cellOf(self.x +% self.vel_x) and
            cellOf(target_y) == cellOf(self.y +% self.vel_y);

        self.x +%= self.vel_x;
        self.y +%= self.vel_y;
        if (reached) {
            self.x = target_x;
            self.y = target_y;
            if (self.index + 1 >= self.points.len) {
                self.index = self.points.len;
                self.vel_x = 0;
                self.vel_y = 0;
            } else {
                self.index += 1;
            }
        }
        return reached;
    }
};

const testing = std.testing;

test "a waypoint is the centre of its cell, and a cell is the high word back" {
    try testing.expectEqual(@as(i32, 0x8000), centreOf(0));
    try testing.expectEqual(@as(i32, 0x18000), centreOf(1));
    try testing.expectEqual(@as(i32, 5), cellOf(centreOf(5)));
}

test "the direction table is the engine's: axis-aligned is 4096, diagonal is 4096/sqrt2" {
    try testing.expectEqual(@as(i32, 0), TABLE[0].major);
    try testing.expectEqual(@as(i32, VEC_ONE), TABLE[0].minor);
    // 4096/sqrt(2) = 2896.3 — the engine rounds to 2896 on both components.
    try testing.expectEqual(@as(i32, 2896), TABLE[127].major);
    try testing.expectEqual(@as(i32, 2896), TABLE[127].minor);
}

test "a direction vector is a unit vector, whichever way it points" {
    const from_x = centreOf(100);
    const from_y = centreOf(100);
    for ([_][2]i32{
        .{ 120, 100 }, .{ 80, 100 }, .{ 100, 120 }, .{ 100, 80 },
        .{ 120, 120 }, .{ 80, 80 },  .{ 120, 80 },  .{ 80, 120 },
    }) |to| {
        const d = directionTo(from_x, from_y, centreOf(to[0]), centreOf(to[1]));
        const len = std.math.sqrt(@as(f64, @floatFromInt(d.vec.x * d.vec.x + d.vec.y * d.vec.y)));
        try testing.expect(@abs(len - @as(f64, VEC_ONE)) < 2.0);
        // Every one of the eight points to a different facing.
        try testing.expect(d.index < 64);
    }
}

test "walking a straight line advances by the velocity and lands on the waypoint" {
    const points = [_]Point{.{ .x = 10, .y = 5 }};
    var m = Motion{
        .points = &points,
        .x = centreOf(0),
        .y = centreOf(5),
        .velocity = @divTrunc(VELOCITY_PER_SUBTILE, 2), // half a subtile a frame
    };
    var frames: usize = 0;
    while (!m.advance()) : (frames += 1) {
        try testing.expect(frames < 100); // it has to converge
    }
    try testing.expect(m.done());
    try testing.expectEqual(@as(i32, 10), cellOf(m.x));
    try testing.expectEqual(@as(i32, 5), cellOf(m.y));
    // Ten subtiles at half a subtile a frame: about twenty, not two and not two hundred.
    try testing.expect(frames >= 18 and frames <= 22);
}

test "arriving zeroes the velocity, so a finished walk stays finished" {
    const points = [_]Point{.{ .x = 1, .y = 0 }};
    var m = Motion{ .points = &points, .x = centreOf(0), .y = centreOf(0), .velocity = VELOCITY_PER_SUBTILE };
    try testing.expect(m.advance());
    try testing.expect(m.done());
    try testing.expectEqual(@as(i32, 0), m.vel_x);
    try testing.expectEqual(@as(i32, 0), m.vel_y);
    // Advancing a finished motion is a no-op, not a step past the end.
    try testing.expect(m.advance());
    try testing.expectEqual(@as(i32, 1), cellOf(m.x));
}

test "one subtile a frame is VELOCITY_PER_SUBTILE, which is what makes the rest legible" {
    const points = [_]Point{.{ .x = 40, .y = 0 }};
    var m = Motion{ .points = &points, .x = centreOf(0), .y = centreOf(0), .velocity = VELOCITY_PER_SUBTILE };
    _ = m.advance();
    try testing.expectEqual(@as(i32, ONE), m.vel_x);
    try testing.expectEqual(@as(i32, 0), m.vel_y);
    try testing.expectEqual(@as(i32, 1), cellOf(m.x));
}

test "a multi-leg path is walked leg by leg, in order" {
    const points = [_]Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 5 }, .{ .x = 0, .y = 5 } };
    var m = Motion{ .points = &points, .x = centreOf(0), .y = centreOf(0), .velocity = @divTrunc(VELOCITY_PER_SUBTILE, 2) };
    var frames: usize = 0;
    while (!m.done() and frames < 400) : (frames += 1) _ = m.advance();
    try testing.expect(m.done());
    try testing.expectEqual(@as(i32, 0), cellOf(m.x));
    try testing.expectEqual(@as(i32, 5), cellOf(m.y));
}

test "the stepper does not handle overshoot, because the engine does not either" {
    // A step bigger than a cell can jump straight over the waypoint, and the reached-test — which
    // compares CELLS — never fires. That is faithful: real velocities are a fraction of a subtile
    // per frame, so the engine never meets the case. Pinned so nobody "fixes" it into divergence.
    const points = [_]Point{.{ .x = 1, .y = 0 }};
    var m = Motion{ .points = &points, .x = centreOf(0), .y = centreOf(0), .velocity = VELOCITY_PER_SUBTILE * 8 };
    try testing.expect(!m.advance());
    try testing.expect(cellOf(m.x) > 1);
}
