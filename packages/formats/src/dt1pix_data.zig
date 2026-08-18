//! The baked DT1 PIXEL blob (raw DT1 bytes for Act1 dungeon/interior tilesets),
//! used by the iso tile renderer to materialize real game tile art. Embedded from
//! the committed file under ../blobs/. It is checked in pre-baked; the tool that
//! bakes it needs the game assets and so lives outside this repository.
pub const bytes = @embedFile("blobs/dt1pix_blob.bin");
