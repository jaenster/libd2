//! The baked DT1 subtile-flag blob (collision). Embedded from the committed,
//! pre-baked blob under ../blobs/ (baked by tools/sync.sh from the private source
//! repo's assets/tiles/). No raw Blizzard art ships here.
pub const bytes = @embedFile("blobs/dt1_blob.bin");
