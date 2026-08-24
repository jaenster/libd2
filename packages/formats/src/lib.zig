//! d2-formats — pure, self-contained parsers for Diablo II 1.14d on-disk map
//! data. No engine state and no assets — each parser turns a byte slice into
//! typed records using a caller-supplied `std.mem.Allocator`.
//!
//!   ds1  — DS1 level-structure files (room/tile/object layout of a preset area).
//!   d2s  — the fixed .d2s character-save header (the sections after it live in d2-save).
//!   dt1  — DT1 tile libraries (per-subtile art + collision flags).
//!   dc6  — DC6 sprite sheets.   dcc — compressed DCC animations.   cof — COF
//!          component/animation layer descriptors.
//!   dt1pix — raw DT1 pixel-art decode.  *_blob / *_data — the baked-blob
//!          container codec + its embedded payload used by the tile pipeline.
//!   mpq  — the archive all of the above ship inside, including the protected
//!          ones whose names have been stripped, and `mpq.Set`, several of them
//!          searched in a real install's order.  pkware — the implode codec an
//!          MPQ member is packed with.  huffman / adpcm — the other two, which
//!          a `.wav` member stacks on top of each other.  ptc — the PrePatch
//!          delta a patch installer carries instead of a whole file.
//!   palette — pal.dat, the 256-entry B,G,R table sprite indices refer to.
//!   canvas — an RGBA surface and the index-0-is-a-hole compositing that turns
//!          those indices back into a picture, including the block grid a
//!          full-screen background is stored as.

pub const ds1 = @import("ds1.zig");
pub const d2s = @import("d2s.zig");
pub const dt1 = @import("dt1.zig");
pub const dcc = @import("dcc.zig");
pub const dc6 = @import("dc6.zig");
pub const cof = @import("cof.zig");
pub const ds1_blob = @import("ds1_blob.zig");
pub const dt1_blob = @import("dt1_blob.zig");
pub const dt1_data = @import("dt1_data.zig");
pub const dt1pix = @import("dt1pix.zig");
pub const dt1pix_data = @import("dt1pix_data.zig");
pub const mpq = @import("mpq.zig");
pub const palette = @import("palette.zig");
pub const canvas = @import("canvas.zig");
pub const font = @import("font.zig");
pub const pl2 = @import("pl2.zig");
pub const strtbl = @import("strtbl.zig");
pub const pkware = @import("pkware.zig");
pub const huffman = @import("huffman.zig");
pub const adpcm = @import("adpcm.zig");
pub const ptc = @import("ptc.zig");

test {
    _ = ds1;
    _ = d2s;
    _ = dt1;
    _ = dcc;
    _ = dc6;
    _ = cof;
    _ = ds1_blob;
    _ = dt1_blob;
    _ = dt1_data;
    _ = dt1pix;
    _ = dt1pix_data;
    _ = mpq;
    _ = palette;
    _ = canvas;
    _ = font;
    _ = pl2;
    _ = strtbl;
    _ = pkware;
    _ = huffman;
    _ = adpcm;
    _ = ptc;
}
