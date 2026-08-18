//! The baked DT1 subtile-flag blob (collision), embedded from the committed file
//! under ../blobs/. Flags only, so no raw Blizzard art ships here. It is checked in
//! pre-baked; the tool that bakes it needs the game assets and so lives outside this
//! repository.
pub const bytes = @embedFile("blobs/dt1_blob.bin");
