//! Faithful Zig transform of recon/closure/Transform.cpp
//! (D2Common::Drlg::Transform — coordinate-space conversions).
//!
//! Mechanical 1:1 port. C `>>`/`/` semantics preserved:
//!   - C `a - b >> n` == `(a - b) >> n` (additive binds tighter than shift) ->
//!     explicit parens here.
//!   - C signed `/` truncates toward zero -> @divTrunc.
//!   - integer wrap is intentional (engine relies on it) -> wrapping ops.
//! All pointer params are C pointers ([*c]i32), matching the recon's `int32_t*`.

// CoordsRoomToWorld — Transform.cpp:158 (1.14d 00643560)
pub fn CoordsRoomToWorld(pX: [*c]i32, pY: [*c]i32) void {
    pX.* *%= 5;
    pY.* *%= 5;
}

// CoordsMiniMapToScreen — Transform.cpp:40 (1.14d). Isometric tile->screen.
//   *pX = (x - y) * 0x50;  *pY = ((y + x) * 0x50) >> 1;
pub fn CoordsMiniMapToScreen(pX: [*c]i32, pY: [*c]i32) void {
    const x = pX.*;
    const y = pY.*;
    pX.* = (x -% y) *% 0x50;
    pY.* = ((y +% x) *% 0x50) >> 1;
}

test "Transform compiles + basic identities" {
    const std = @import("std");
    var x: i32 = 5;
    var y: i32 = 3;
    CoordsRoomToWorld(&x, &y);
    try std.testing.expectEqual(@as(i32, 25), x);
    try std.testing.expectEqual(@as(i32, 15), y);
}
