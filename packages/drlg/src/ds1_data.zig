//! The one baked DS1-structure blob. In this public mirror it is embedded from
//! the committed, pre-baked blob under ../blobs/ (baked by tools/sync.sh from the
//! private source repo's assets/tiles/). No raw Blizzard art ships here.
pub const bytes = @embedFile("blobs/ds1_blob.bin");
