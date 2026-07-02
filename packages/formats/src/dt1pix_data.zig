//! The baked DT1 PIXEL blob (raw DT1 bytes for Act1 dungeon/interior tilesets),
//! used by the iso tile renderer to materialize real game tile art. Embedded from
//! the committed, pre-baked blob under ../blobs/ (baked by tools/sync.sh).
pub const bytes = @embedFile("blobs/dt1pix_blob.bin");
