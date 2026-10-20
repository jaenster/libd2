//! d2-gfx: a scene drawn as the game's renderer draws it, on the CPU, with no GPU and no Windows.
//!
//! `scene` reads what the client hands the renderer for a level (tiles in the drawing order, their
//! DT1s, the palette, the light map, the units' layers); `view` draws a frame of it; `compare`
//! judges two frames of one view block by block. `light`, `tiles`, `tilepal`, `raster` and `gamma`
//! are the parts `view` is made of. See docs/render.md.
pub const scene = @import("scene.zig");
pub const tiles = @import("tiles.zig");
pub const tilepal = @import("tilepal.zig");
pub const light = @import("light.zig");
pub const raster = @import("raster.zig");
pub const view = @import("view.zig");
pub const compare = @import("compare.zig");
pub const gamma = @import("gamma.zig");

test {
    _ = scene;
    _ = tiles;
    _ = tilepal;
    _ = light;
    _ = raster;
    _ = view;
    _ = compare;
    _ = gamma;
}
