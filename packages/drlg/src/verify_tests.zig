//! Golden verification root — the byte-exactness gate every DRLG change has to clear.
//!
//! Separate from tests.zig because these are not unit tests: each one regenerates whole acts and
//! diffs them against collision/monster data captured from the real 1.14d engine, so they are
//! bound by generation throughput rather than by the assertions. The build pins this root to
//! ReleaseFast for that reason — in Debug the same work takes minutes and can exhaust memory.

test {
    _ = @import("verify.zig");
    _ = @import("monpop_verify.zig");
    _ = @import("coll_crc_verify.zig");
    _ = @import("coll_allacts_verify.zig");
    _ = @import("churn_verify.zig");
}
