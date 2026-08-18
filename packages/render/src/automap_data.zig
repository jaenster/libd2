//! The baked automap sprite blob (palette + per-act DC6 sheets). Embedded from
//! the committed file under ../blobs/. It is checked in pre-baked; the tool that
//! bakes it needs the game assets and so lives outside this repository.
pub const bytes = @embedFile("blobs/automap_blob.bin");
