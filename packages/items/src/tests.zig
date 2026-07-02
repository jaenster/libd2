//! Aggregate test root — `zig build test` pulls every module in so all unit
//! tests run together. Add new modules here as they land.

test {
    _ = @import("rng.zig");
    _ = @import("txt.zig");
    _ = @import("tables.zig");
    _ = @import("model.zig");
    _ = @import("itemtype.zig");
    _ = @import("quality.zig");
    _ = @import("treasure.zig");
    _ = @import("affix.zig");
    _ = @import("sockets.zig");
    _ = @import("item.zig");
    _ = @import("dc6.zig");
    _ = @import("png.zig");
    _ = @import("graphic.zig");
    _ = @import("render.zig");
    _ = @import("verify.zig");
    _ = @import("lib.zig");
}
