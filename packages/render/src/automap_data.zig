//! The baked automap sprite blob (palette + per-act DC6 sheets). Embedded from
//! the committed, pre-baked blob under ../blobs/ (baked by tools/sync.sh from the
//! private source repo's assets/automap/).
pub const bytes = @embedFile("blobs/automap_blob.bin");
