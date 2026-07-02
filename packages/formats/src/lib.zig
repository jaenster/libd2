//! d2-formats — pure, self-contained parsers for Diablo II 1.14d on-disk map
//! data. No engine state and no assets — each parser turns a byte slice into
//! typed records using a caller-supplied `std.mem.Allocator`.
//!
//!   ds1  — DS1 level-structure files (room/tile/object layout of a preset area).
//!   dt1  — DT1 tile libraries (per-subtile art + collision flags).
//!   dc6  — DC6 sprite sheets.   dcc — compressed DCC animations.   cof — COF
//!          component/animation layer descriptors.
//!   dt1pix — raw DT1 pixel-art decode.  *_blob / *_data — the baked-blob
//!          container codec + its embedded payload used by the tile pipeline.

pub const ds1 = @import("ds1.zig");
pub const dt1 = @import("dt1.zig");
pub const dcc = @import("dcc.zig");
pub const dc6 = @import("dc6.zig");
pub const cof = @import("cof.zig");
pub const ds1_blob = @import("ds1_blob.zig");
pub const dt1_blob = @import("dt1_blob.zig");
pub const dt1_data = @import("dt1_data.zig");
pub const dt1pix = @import("dt1pix.zig");
pub const dt1pix_data = @import("dt1pix_data.zig");

test {
    _ = ds1;
    _ = dt1;
    _ = dcc;
    _ = dc6;
    _ = cof;
    _ = ds1_blob;
    _ = dt1_blob;
    _ = dt1_data;
    _ = dt1pix;
    _ = dt1pix_data;
}
