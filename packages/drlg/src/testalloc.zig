//! Leak-checking allocator for the tests that generate acts in a loop.
//!
//! `std.testing.allocator` cannot be used for those: it captures a 10-frame stack trace on EVERY
//! alloc and every free, and on targets where the frame pointer is not guaranteed usable — which
//! includes aarch64-macOS — that capture unwinds through DWARF CFI. `Dwarf.SelfUnwinder` takes its
//! virtual-machine scratch from `std.debug.getDebugInfoAllocator()`, whose default is a
//! process-global `ArenaAllocator`; an arena's `free` is a no-op, so the unwinder's `deinit`
//! reclaims nothing and every single capture keeps its scratch for the life of the process. One
//! generated act costs a few million allocations, so that lands at roughly 85 MB of permanently
//! mapped memory PER ACT — ~17 GB for a 125-act gate, and unbounded over the whole suite. The hook
//! is only overridable from the root source file, and for a test binary the root is the compiler's
//! test runner, so the package cannot redirect it.
//!
//! This allocator keeps the part that matters — full leak DETECTION — and drops only the per-
//! allocation stack trace, which is what triggers the unwind. A leak still fails the test; it just
//! reports a count instead of a location. To get the location back, temporarily swap the failing
//! test over to `std.testing.allocator` and run it alone.

const std = @import("std");

/// Wrap one of these per test: `var mem: testalloc.Checked = .{}; defer mem.deinit();`
pub const Checked = struct {
    dbg: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init,

    pub fn allocator(self: *Checked) std.mem.Allocator {
        return self.dbg.allocator();
    }

    /// Tears down and fails the run on any surviving allocation.
    pub fn deinit(self: *Checked) void {
        if (self.dbg.deinit() == .leak)
            @panic("d2-drlg test: allocator leak (rerun the test with std.testing.allocator for a stack trace)");
    }
};
