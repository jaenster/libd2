//! Aggregate test root for d2-render — `zig build test` pulls every module in so
//! all unit tests (automap sprite lookup, ASCII render, objgfx, tile-art API) run.

test {
    _ = @import("lib.zig");
    _ = @import("automap.zig");
    _ = @import("automap_blob.zig");
    _ = @import("automap_data.zig");
    _ = @import("render.zig");
    _ = @import("objgfx.zig");
}
