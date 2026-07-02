//! Aggregate test root — `zig build test` pulls every module in so all unit
//! tests run together. Add new modules here as they land.

test {
    _ = @import("rng.zig");
    _ = @import("txt.zig");
    _ = @import("tables.zig");
    _ = @import("d2-formats").ds1;
    _ = @import("d2-formats").dt1;
    _ = @import("d2-formats").dt1pix;
    _ = @import("d2-fog").memory;
    _ = @import("collision.zig");
    _ = @import("oracle.zig");
    _ = @import("verify.zig");
    _ = @import("lib.zig");
    _ = @import("path.zig");
    _ = @import("serial.zig");
    _ = @import("act.zig");
    _ = @import("d2-formats").dc6;
    _ = @import("objects.zig");

    // DRLG closure — leaf support (src/drlg/*)
    _ = @import("drlg/structs.zig");
    _ = @import("drlg/rng.zig");
    _ = @import("drlg/pool.zig");
    _ = @import("drlg/tables.zig");
    _ = @import("drlg/enums.zig");

    // DRLG closure — core (src/drlg/*)
    _ = @import("drlg/forward.zig");
    _ = @import("drlg/Transform.zig");
    _ = @import("drlg/DrlgGrid.zig");
    _ = @import("drlg/DrlgVer.zig");
    _ = @import("drlg/DrlgWarp.zig");
    _ = @import("drlg/TileSub.zig");
    _ = @import("drlg/outdoors/OutSub.zig");
    _ = @import("drlg/DrlgLogic.zig");
    _ = @import("drlg/RoomTile.zig");
    _ = @import("drlg/tilegen.zig");
    _ = @import("drlg/materialize.zig");
    _ = @import("drlg/DrlgRoom.zig");

    // DRLG closure — maze (src/drlg/maze/*)
    _ = @import("drlg/preset.zig");
    _ = @import("drlg/maze/deps.zig");
    _ = @import("drlg/maze/Maze.zig");
    _ = @import("drlg/maze/Act2Sewer.zig");
    _ = @import("drlg/maze/Act1.zig");
    _ = @import("drlg/maze/Act2.zig");
    _ = @import("drlg/maze/Act3.zig");
    _ = @import("drlg/maze/Act5.zig");

    // DRLG closure — top orchestration (src/drlg/drlg.zig)
    _ = @import("drlg/drlg.zig");

    // Seeded object population (src/drlg/objpop.zig)
    _ = @import("drlg/objpop.zig");

    // Seeded monster population (src/drlg/monpop.zig)
    _ = @import("drlg/monpop.zig");
}
