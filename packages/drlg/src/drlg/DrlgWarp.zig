//! Faithful Zig transform of recon/closure/DrlgWarp.cpp
//! (D2Common::Drlg::DrlgWarp).

const s = @import("structs.zig");
const DrlgRoom = @import("DrlgRoom.zig");

const D2DrlgLevelStrc = s.D2DrlgLevelStrc;

/// DrlgWarp.cpp:21 (1.14d 0066af30)
pub fn getWarpDestinationFromArray(pLevel: [*c]D2DrlgLevelStrc, nWarpIndex: u8) i32 {
    const pWarpIdArray = DrlgRoom.getWarpsIdIfExists(pLevel.*.pDrlg, pLevel.*.eD2LevelId);
    return pWarpIdArray[nWarpIndex];
}
