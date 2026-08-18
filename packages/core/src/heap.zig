//! The process-lifetime general allocator, and a WebAssembly heap worth using.
//!
//! Every libd2 package that needs memory outside a caller's allocator — process-lifetime caches,
//! the DRLG pool's backing store, the C ABI's handles — takes it from `default` here, so the
//! choice is made once instead of per package.
//!
//! ## Why wasm needs its own
//!
//! On wasm32-freestanding `std.heap.page_allocator` is `std.heap.BrkAllocator`, which rounds every
//! request up to the next power of two of `max(len + @sizeOf(usize), alignment)` and keeps one
//! free list PER SIZE CLASS that never coalesces and never returns a page. Two consequences, both
//! expensive for a workload whose allocations are large and varied:
//!
//!   * the `+ @sizeOf(usize)` pushes an exactly-power-of-two request into the NEXT class, so a
//!     1 MB collision grid occupies 2 MB;
//!   * because classes never share, the footprint is the SUM OF PER-CLASS PEAKS rather than the
//!     peak of the sum — and wasm linear memory never shrinks (`memory.grow` is one-way), so that
//!     sum is permanent.
//!
//! Measured on a five-act DRLG generation whose true peak is 14.8 MB simultaneously live: the
//! per-class peaks summed to 36.2 MB, of which 33.5 MB sat in the 128 KB - 8 MB classes alone.
//! `d2-drlg allocstat` is that measurement, and re-runs it.
//!
//! ## What this does instead
//!
//! A single address-ordered free list of spans, coalescing on free, best-fit on allocate. That is
//! deliberately the classic design and not something cleverer:
//!
//!   * `std.mem.Allocator` hands the length back on `free`, so with every size rounded to
//!     `granularity` there is no header and no per-allocation overhead at all — which is the
//!     reason a power-of-two allocator is the wrong shape here in the first place.
//!   * coalescing means one size's freed span serves the next request whatever its size, and that
//!     is precisely what the sum-of-peaks behaviour above costs.
//!   * best-fit rather than first-fit because the request stream mixes 128 KB and 4 MB blocks;
//!     first-fit carves the big spans up and strands the remainders.
//!
//! Cost: allocate and free are O(number of free spans). That suits libd2's shape — the interior of
//! a generation runs on the Fog pool (`memory.zig`) or an arena, so what reaches this heap is
//! thousands of large blocks over an act, not millions of small ones. A workload that does hammer
//! it with small allocations wants a slab in front of this, not a different free list.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;

/// The general allocator for process-lifetime and C-ABI-handle memory.
///
/// Native multi-threaded builds get `smp_allocator` (thread-safe, libc-free). Freestanding wasm
/// gets `wasm_heap`. Any other single-threaded target keeps `page_allocator`, which is correct
/// everywhere even if it is coarse.
pub const default: Allocator = if (is_wasm)
    wasm_heap
else if (builtin.single_threaded)
    std.heap.page_allocator
else
    std.heap.smp_allocator;

const is_wasm = builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding;

/// What a heap is holding. `obtained` never falls (on wasm it cannot: `memory.grow` is one-way),
/// so `obtained` is the footprint and `live` is how much of it is doing any work. A large
/// `free_bytes` spread over many `spans` with a small `largest_free` is fragmentation.
pub const Usage = struct {
    obtained: usize,
    live: usize,
    free_bytes: usize,
    /// Number of free spans — how far a search walks, and how fragmented the heap is.
    spans: usize,
    largest_free: usize,
};

/// `default`'s state, where it can be known. Only the wasm heap tracks itself; std's allocators
/// expose nothing, so every field is 0 on other targets rather than a number that looks real.
pub fn usage() Usage {
    if (!is_wasm) return .{ .obtained = 0, .live = 0, .free_bytes = 0, .spans = 0, .largest_free = 0 };
    return WasmHeap.usage();
}

/// wasm's page size, and the unit `memory.grow` works in.
pub const page_size = 64 * 1024;

/// The one heap over this module's linear memory. Not instantiable off wasm — `default` selects it
/// only there — but the free-list machinery below is target-independent and tested on the host.
pub const WasmHeap = FreeListHeap(WasmPages);

/// A `WasmHeap` as a `std.mem.Allocator`. There is only ever one: it owns all of linear memory
/// above the static data and shadow stack.
pub const wasm_heap: Allocator = .{ .ptr = undefined, .vtable = &WasmHeap.vtable };

/// Growth source for `WasmHeap`: `memory.grow`, which hands back page-aligned pages that are
/// never returned.
const WasmPages = struct {
    fn obtain(pages: usize) ?usize {
        const prev = @wasmMemoryGrow(0, pages);
        if (prev < 0) return null;
        return @as(usize, @intCast(prev)) * page_size;
    }
};

/// An address-ordered, coalescing, best-fit free-list allocator over whole pages obtained from
/// `Pages.obtain(pages) ?usize` (the address of `pages * page_size` fresh, page-aligned bytes, or
/// null when no more can be had). Growth is one-way: nothing is ever handed back.
///
/// State is per instantiation rather than per instance — one linear memory means one heap, and a
/// global keeps the `Allocator.ptr` unused so `wasm_heap` can be a plain `const`.
pub fn FreeListHeap(comptime Pages: type) type {
    return struct {
        /// Every span start and length is a multiple of this, which is what removes the need for a
        /// header (a free span always has room for its own list node) and satisfies any alignment
        /// up to it for free.
        pub const granularity = 16;

        /// A free span, stored IN the span it describes. `len` counts these bytes too.
        const Span = struct {
            len: usize,
            next: ?*Span,
        };

        comptime {
            assert(@sizeOf(Span) <= granularity);
        }

        /// Head of the address-ordered free list.
        var free_list: ?*Span = null;
        /// Total bytes ever obtained from `Pages`. Only reported, never used to decide anything —
        /// `insert` coalesces adjacent growths on its own.
        var obtained: usize = 0;

        const Self = @This();

        pub const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        pub fn allocator() Allocator {
            return .{ .ptr = undefined, .vtable = &vtable };
        }

        fn roundUp(n: usize, to: usize) usize {
            return (n + to - 1) & ~(to - 1);
        }

        /// Bytes a request of `len` actually occupies.
        fn spanLen(len: usize) usize {
            return roundUp(@max(len, granularity), granularity);
        }

        fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
            const want = spanLen(len);
            const want_align = @max(alignment.toByteUnits(), granularity);
            // Growth is page-aligned, so any alignment up to a page is reachable; a stricter one
            // would need an over-allocate-and-trim path no libd2 caller asks for.
            if (want_align > page_size) return null;

            if (take(want, want_align)) |p| return p;
            // Worst case the fresh span needs padding to reach an aligned start. It never does
            // (growth is page-aligned) unless a foreign grow has shifted the boundary, but sizing
            // for it costs nothing and removes the failure mode.
            if (!grow(want + want_align - granularity)) return null;
            return take(want, want_align);
        }

        /// Best-fit search: the span leaving the smallest remainder wins. Splits off any head (for
        /// alignment) and tail; both are multiples of `granularity`, so both are valid spans.
        fn take(want: usize, want_align: usize) ?[*]u8 {
            var best: ?*Span = null;
            var best_prev: ?*Span = null;
            var best_pad: usize = 0;
            var best_waste: usize = std.math.maxInt(usize);

            var prev: ?*Span = null;
            var it = free_list;
            while (it) |s| {
                const start = @intFromPtr(s);
                const pad = roundUp(start, want_align) - start;
                if (s.len >= pad + want) {
                    const waste = s.len - pad - want;
                    if (waste < best_waste) {
                        best = s;
                        best_prev = prev;
                        best_pad = pad;
                        best_waste = waste;
                        if (waste == 0 and pad == 0) break; // exact fit; nothing can beat it
                    }
                }
                prev = s;
                it = s.next;
            }

            const s = best orelse return null;
            const start = @intFromPtr(s);
            const total = s.len;
            const next = s.next;

            // Unlink first, then hand the leftovers back through the ordinary coalescing insert so
            // the list stays address-ordered whichever pieces exist.
            if (best_prev) |p| p.next = next else free_list = next;

            const body = start + best_pad;
            if (best_pad != 0) insert(start, best_pad);
            const tail = total - best_pad - want;
            if (tail != 0) insert(body + want, tail);
            return @ptrFromInt(body);
        }

        /// Insert `[addr, addr+len)` into the address-ordered list, merging with the neighbour on
        /// either side when they touch. Coalescing here is the whole point of the design: it is
        /// what lets a freed 4 MB grid satisfy the next 128 KB request.
        fn insert(addr: usize, len: usize) void {
            assert(len >= granularity and len % granularity == 0);
            var prev: ?*Span = null;
            var it = free_list;
            while (it) |s| {
                if (@intFromPtr(s) > addr) break;
                prev = s;
                it = s.next;
            }

            if (prev) |p| {
                const p_end = @intFromPtr(p) + p.len;
                assert(p_end <= addr); // an overlap means a double free
                if (p_end == addr) {
                    p.len += len;
                    if (it) |n| {
                        if (@intFromPtr(p) + p.len == @intFromPtr(n)) {
                            p.len += n.len;
                            p.next = n.next;
                        }
                    }
                    return;
                }
            }

            const s: *Span = @ptrFromInt(addr);
            s.* = .{ .len = len, .next = it };
            if (it) |n| {
                if (addr + len == @intFromPtr(n)) {
                    s.len += n.len;
                    s.next = n.next;
                }
            }
            if (prev) |p| p.next = s else free_list = s;
        }

        /// Add at least `min` bytes of fresh memory to the free list.
        fn grow(min: usize) bool {
            const pages = @max(1, roundUp(min, page_size) / page_size);
            const addr = Pages.obtain(pages) orelse return false;
            const len = pages * page_size;
            obtained += len;
            insert(addr, len);
            return true;
        }

        fn free(_: *anyopaque, buf: []u8, _: Alignment, _: usize) void {
            insert(@intFromPtr(buf.ptr), spanLen(buf.len));
        }

        fn resize(_: *anyopaque, buf: []u8, _: Alignment, new_len: usize, _: usize) bool {
            const old = spanLen(buf.len);
            const new = spanLen(new_len);
            if (new == old) return true;
            const start = @intFromPtr(buf.ptr);
            if (new < old) {
                insert(start + new, old - new);
                return true;
            }
            // Grow in place only by absorbing the free span that begins exactly where this one
            // ends. Anything else is a move, which is the caller's alloc+copy+free.
            const need = new - old;
            const end = start + old;
            var prev: ?*Span = null;
            var it = free_list;
            while (it) |s| {
                const a = @intFromPtr(s);
                if (a == end) break;
                if (a > end) return false;
                prev = s;
                it = s.next;
            }
            const s = it orelse return false;
            if (s.len < need) return false;
            const rest = s.len - need;
            const next = s.next;
            if (rest != 0) {
                const moved: *Span = @ptrFromInt(end + need);
                moved.* = .{ .len = rest, .next = next };
                if (prev) |p| p.next = moved else free_list = moved;
            } else if (prev) |p| {
                p.next = next;
            } else {
                free_list = next;
            }
            return true;
        }

        fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
            // No relocation: a move is the caller's alloc+copy+free fallback, and doing it here
            // would only duplicate that.
            return if (resize(ctx, buf, alignment, new_len, ra)) buf.ptr else null;
        }

        /// Snapshot for a host that wants to report or assert on the heap. Walks the free list.
        pub fn usage() Usage {
            var u: Usage = .{ .obtained = obtained, .live = obtained, .free_bytes = 0, .spans = 0, .largest_free = 0 };
            var it = free_list;
            while (it) |s| {
                u.free_bytes += s.len;
                u.spans += 1;
                u.largest_free = @max(u.largest_free, s.len);
                it = s.next;
            }
            u.live = obtained - u.free_bytes;
            return u;
        }

        /// Assert the free list is well formed: strictly address-ordered, no span touching its
        /// successor (anything adjacent must already have coalesced), sizes aligned. Tests call
        /// this after every operation; it is the invariant a corrupt heap breaks first.
        pub fn checkInvariants() !void {
            var it = free_list;
            var last_end: usize = 0;
            while (it) |s| {
                const a = @intFromPtr(s);
                if (a % granularity != 0) return error.MisalignedSpan;
                if (s.len < granularity or s.len % granularity != 0) return error.BadSpanLen;
                if (a < last_end) return error.OutOfOrder;
                if (a == last_end and last_end != 0) return error.UncoalescedSpan;
                last_end = a + s.len;
                it = s.next;
            }
        }

        /// Drop every span. Only for tests that want a clean slate; the memory is NOT returned.
        pub fn resetForTest() void {
            free_list = null;
            obtained = 0;
        }
    };
}

// ---- tests -----------------------------------------------------------------
//
// The wasm heap cannot be exercised on the host (there is no linear memory to grow), so the tests
// run the exact same `FreeListHeap` over page-aligned chunks from the host page allocator. Only
// the growth source differs, and it is four lines.

const TestPages = struct {
    /// Chunks are leaked on purpose: the heap never returns memory, so neither does its backing,
    /// and a test process exiting is the reclaim.
    fn obtain(pages: usize) ?usize {
        const buf = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(page_size), pages * page_size) catch return null;
        return @intFromPtr(buf.ptr);
    }
};
const TestHeap = FreeListHeap(TestPages);

test "wasm heap: alloc, free and reuse of the same span" {
    TestHeap.resetForTest();
    const a = TestHeap.allocator();

    const p = try a.alloc(u8, 1000);
    try TestHeap.checkInvariants();
    a.free(p);
    try TestHeap.checkInvariants();

    // The freed span is the best fit for an identical request, so it comes straight back.
    const q = try a.alloc(u8, 1000);
    try std.testing.expectEqual(p.ptr, q.ptr);
    a.free(q);
}

test "wasm heap: adjacent frees coalesce back into one span" {
    TestHeap.resetForTest();
    const a = TestHeap.allocator();

    // Three neighbours out of one fresh page, freed in an order that exercises merge-forward,
    // merge-backward and merge-both.
    const x = try a.alloc(u8, 4096);
    const y = try a.alloc(u8, 4096);
    const z = try a.alloc(u8, 4096);
    const before = TestHeap.usage();

    a.free(x);
    try TestHeap.checkInvariants();
    a.free(z);
    try TestHeap.checkInvariants();
    a.free(y);
    try TestHeap.checkInvariants();

    // Everything is free again and, because y bridged x and z, it is a SINGLE span.
    const after = TestHeap.usage();
    try std.testing.expectEqual(before.obtained, after.obtained);
    try std.testing.expectEqual(@as(usize, 1), after.spans);
    try std.testing.expectEqual(after.obtained, after.free_bytes);
}

test "wasm heap: a freed large span serves a smaller request of any size" {
    TestHeap.resetForTest();
    const a = TestHeap.allocator();

    // This is the BrkAllocator behaviour being fixed: there, a freed 4 MB block sits on the 4 MB
    // class's list and a 128 KB request grows memory instead of using it.
    const big = try a.alloc(u8, 4 << 20);
    a.free(big);
    const obtained = TestHeap.usage().obtained;

    var small: [16][]u8 = undefined;
    for (&small) |*s| s.* = try a.alloc(u8, 128 << 10);
    try TestHeap.checkInvariants();
    try std.testing.expectEqual(obtained, TestHeap.usage().obtained); // no growth at all
    for (small) |s| a.free(s);
    try TestHeap.checkInvariants();
    try std.testing.expectEqual(@as(usize, 1), TestHeap.usage().spans);
}

test "wasm heap: exact-power-of-two requests cost exactly their size" {
    TestHeap.resetForTest();
    const a = TestHeap.allocator();

    // The other BrkAllocator behaviour being fixed: `len + @sizeOf(usize)` rounded to the next
    // power of two makes a 1 MB request occupy 2 MB. Sixteen of them fit in 16 MB here.
    var blocks: [16][]u8 = undefined;
    for (&blocks) |*b| b.* = try a.alloc(u8, 1 << 20);
    try std.testing.expectEqual(@as(usize, 16 << 20), TestHeap.usage().obtained);
    for (blocks) |b| a.free(b);
    try std.testing.expectEqual(@as(usize, 16 << 20), TestHeap.usage().free_bytes);
}

test "wasm heap: alignment up to a page is honoured" {
    TestHeap.resetForTest();
    const a = TestHeap.allocator();

    inline for (.{ 16, 64, 512, 4096, page_size }) |al| {
        const p = try a.alignedAlloc(u8, .fromByteUnits(al), 300);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p.ptr) % al);
        try TestHeap.checkInvariants();
        a.free(p);
        try TestHeap.checkInvariants();
    }
}

test "wasm heap: shrink returns the tail, grow absorbs the neighbour" {
    TestHeap.resetForTest();
    const a = TestHeap.allocator();

    var buf = try a.alloc(u8, 8192);
    const start = buf.ptr;
    const obtained = TestHeap.usage().obtained;

    try std.testing.expect(a.resize(buf, 4096));
    buf.len = 4096;
    try TestHeap.checkInvariants();
    // The released half is on the free list, and the block did not move.
    try std.testing.expectEqual(start, buf.ptr);
    try std.testing.expect(TestHeap.usage().free_bytes >= 4096);

    // Growing back consumes exactly the span that was just released, in place.
    try std.testing.expect(a.resize(buf, 8192));
    buf.len = 8192;
    try std.testing.expectEqual(start, buf.ptr);
    try std.testing.expectEqual(obtained, TestHeap.usage().obtained);
    a.free(buf);
}

test "wasm heap: survives a randomised alloc/free workload with the invariants held" {
    TestHeap.resetForTest();
    const a = TestHeap.allocator();

    // Sizes spanning the range the DRLG actually uses (a few bytes to a few MB), with writes to
    // every byte so an overlapping span would corrupt a neighbour and be caught below.
    var prng = std.Random.DefaultPrng.init(0x1eaf1e55);
    const rand = prng.random();
    var live: [64]?[]u8 = @splat(null);
    var tags: [64]u8 = @splat(0);

    for (0..4000) |i| {
        const slot = rand.uintLessThan(usize, live.len);
        if (live[slot]) |b| {
            for (b) |c| try std.testing.expectEqual(tags[slot], c);
            a.free(b);
            live[slot] = null;
        } else {
            const len = switch (rand.uintLessThan(u8, 10)) {
                0...4 => rand.uintLessThan(usize, 512) + 1,
                5...8 => rand.uintLessThan(usize, 256 << 10) + 1,
                else => rand.uintLessThan(usize, 4 << 20) + 1,
            };
            const b = try a.alloc(u8, len);
            tags[slot] = @truncate(i);
            @memset(b, tags[slot]);
            live[slot] = b;
        }
        try TestHeap.checkInvariants();
    }

    for (live, 0..) |maybe, slot| if (maybe) |b| {
        for (b) |c| try std.testing.expectEqual(tags[slot], c);
        a.free(b);
    };
    try TestHeap.checkInvariants();
    // Everything freed: the heap must have coalesced back to one span per backing chunk, not
    // thousands of slivers.
    const u = TestHeap.usage();
    try std.testing.expectEqual(u.obtained, u.free_bytes);
}
