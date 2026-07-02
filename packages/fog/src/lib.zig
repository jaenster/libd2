//! d2-fog — a faithful Zig replica of the Diablo II 1.14d `Fog::Memory`
//! segregated-slab pool allocator: fixed size-classes with bitmap slot reuse, an
//! overflow path for large requests, and wholesale teardown. The DRLG runs every
//! level's generation on one of these pools so that `Level.deinit` is a single
//! bulk free. Exposed as its own package because it is engine-agnostic.

pub const memory = @import("memory.zig");

test {
    _ = memory;
}
