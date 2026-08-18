//! The one baked DS1-structure blob: only the fields the generator reads, so the
//! committed file under ../blobs/ carries level structure and no raw Blizzard art.
//! It is checked in pre-baked; the tool that bakes it needs the game assets and so
//! lives outside this repository.
pub const bytes = @embedFile("blobs/ds1_blob.bin");
