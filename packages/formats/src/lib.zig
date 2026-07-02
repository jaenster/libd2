//! d2-formats — pure, self-contained parsers for Diablo II 1.14d on-disk map
//! data. No engine state and no assets — each parser turns a byte slice into
//! typed records using a caller-supplied `std.mem.Allocator`.
//!
//!   ds1 — DS1 level-structure files (room/tile/object layout of a preset area).
//!   dt1 — DT1 tile libraries (per-subtile art + collision flags).

pub const ds1 = @import("ds1.zig");
pub const dt1 = @import("dt1.zig");

test {
    _ = ds1;
    _ = dt1;
}
