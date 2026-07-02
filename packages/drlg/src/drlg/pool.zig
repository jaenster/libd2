//! DRLG memory pool — mechanical transform of recon/closure/Memory.cpp.
//!
//! The reconstructed 1.14d closure ALREADY bypasses the real pool allocator
//! (VirtualAlloc + CRITICAL_SECTION-guarded free lists) and routes every
//! allocation through a plain calloc/free-style allocator, because the pool
//! internals differ under Wine and — crucially — the pool does NOT consume the
//! DRLG seed, so it has no effect on generated geometry. See Memory.cpp:
//!   AllocClientMemory  (1.14d 0040b3a0, Memory.cpp:1094) -> calloc(1, n)
//!   FreeClientMemory   (1.14d 0040b3c0, Memory.cpp:1101) -> free
//!   ReAllocClientMemory(1.14d 0040b3f0, Memory.cpp:1107) -> realloc
//!   AllocServerMemory  (1.14d 0040b430, Memory.cpp:1119) -> calloc(1, n)
//!   FreeServerMemory   (1.14d 0040b480, Memory.cpp:1126) -> free
//!   ReAllocServerMemory(1.14d 0040b4b0, Memory.cpp:1137) -> realloc
//!
//! This Zig port keeps that same "calloc/free" behaviour but over a configurable
//! `std.mem.Allocator` (so the DRLG transform can run under an arena and have the
//! whole act freed at once). Allocations are length-prefixed so free/realloc work
//! over any allocator without the caller passing the size back (matching the C
//! void* signatures). `calloc` semantics (zeroed memory) are preserved.

const std = @import("std");
const builtin = @import("builtin");
const structs = @import("structs.zig");

/// Default backing allocator for all DRLG allocations: libc-free and works on every
/// target, including wasm freestanding. smp_allocator is thread-safe (needed by the
/// cross-seed verifier fanning out one arena per thread) but asserts multi-threaded,
/// so single-threaded targets (wasm freestanding/wasi) fall back to page_allocator —
/// which is also thread-safe and libc-free. Allocator choice does not affect the
/// seeded generation values.
pub const default_allocator: std.mem.Allocator =
    if (builtin.single_threaded) std.heap.page_allocator else std.heap.smp_allocator;

/// Opaque pool-manager handle the server-side signatures take. The recon ignores
/// it (the bypass calls plain calloc/free), so it is unused here too.
pub const D2PoolManagerStrc = structs.D2PoolManagerStrc;

/// Backing allocator for all DRLG allocations. Defaults to `default_allocator` (see
/// above) so the module works without setup and stays libc-free; the harness may
/// swap in an arena before generating. Thread-local so the cross-seed verifier can
/// fan out one arena per worker thread without races (generation is per-seed indep).
pub threadlocal var allocator: std.mem.Allocator = default_allocator;

// Length-prefix header so a bare `void*`/`?*anyopaque` can be freed/realloced
// without the size. Payload is kept 16-byte aligned (>= max engine alignment).
const payload_align = 16;
const header_size = payload_align; // one aligned slot holds the usize length

// Live-allocation registry. The engine's Fog::Memory pool only frees blocks it
// actually handed out and silently ignores foreign pointers; the DRLG maze relies
// on this — DRLGGRID_FreeGrid frees pCellsRowOffsets, which for a maze room is an
// INT payload overlaid on the grid-pointer field (def/variant), not a real block.
// We mirror the pool: track our own payloads and no-op frees of anything else.
// Thread-local: paired with the thread-local `allocator` above. Each verifier
// worker owns its own arena + registry; within a thread alloc/free are serial.
threadlocal var live: std.AutoHashMapUnmanaged(usize, void) = .empty;
const reg_allocator = default_allocator; // thread-safe, libc-free; independent of the swappable payload allocator

/// Drop the live-allocation registry. Call between independent generations that
/// reuse the process (e.g. the wasm reactor or a multi-seed loop): a wholesale
/// pool teardown frees the backing memory WITHOUT a per-block rawFree, so the
/// freed addresses linger in `live`. When the next generation's allocator reuses
/// one of those addresses, rawFree's foreign-pointer no-op (which distinguishes
/// real blocks from the maze grid-pointer overlay ints by membership in `live`)
/// mis-fires and frees a non-block → heap corruption. Resetting at each
/// generation boundary keeps every run self-contained.
pub fn resetRegistry() void {
    live.clearAndFree(reg_allocator);
}

fn rawAlloc(n: usize) ?*anyopaque {
    if (n == 0) return null;
    const total = header_size + n;
    const buf = allocator.alignedAlloc(u8, .fromByteUnits(payload_align), total) catch return null;
    @memset(buf, 0); // calloc: zero-initialised
    std.mem.writeInt(usize, buf[0..@sizeOf(usize)], n, .little);
    const payload: *anyopaque = @ptrCast(buf.ptr + header_size);
    live.put(reg_allocator, @intFromPtr(payload), {}) catch {};
    return payload;
}

fn basePtr(p: *anyopaque) [*]align(payload_align) u8 {
    const bytes: [*]u8 = @ptrCast(p);
    return @alignCast(bytes - header_size);
}

fn lenOf(p: *anyopaque) usize {
    const base = basePtr(p);
    return std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
}

fn rawFree(p: ?*anyopaque) void {
    const ptr = p orelse return;
    // Pool semantics: only free blocks we allocated; ignore foreign pointers
    // (e.g. the maze grid-pointer overlay ints). Mirrors Fog::Memory.
    if (!live.remove(@intFromPtr(ptr))) return;
    const n = lenOf(ptr);
    const base = basePtr(ptr);
    allocator.free(base[0 .. header_size + n]);
}

fn rawRealloc(p: ?*anyopaque, n: usize) ?*anyopaque {
    const old = p orelse return rawAlloc(n);
    if (n == 0) {
        rawFree(old);
        return null;
    }
    const new = rawAlloc(n) orelse return null;
    const old_len = lenOf(old);
    const copy = @min(old_len, n);
    const src: [*]u8 = @ptrCast(old);
    const dst: [*]u8 = @ptrCast(new);
    @memcpy(dst[0..copy], src[0..copy]);
    rawFree(old);
    return new;
}

// Client-side (Memory.cpp:1094-1115)

/// AllocClientMemory (Memory.cpp:1094): calloc(1, nAllocSize).
pub fn AllocClientMemory(nAllocSize: usize, szFile: ?[*:0]const u8, nLine: i32, nNull: i32) ?*anyopaque {
    _ = .{ szFile, nLine, nNull };
    return rawAlloc(nAllocSize);
}

/// FreeClientMemory (Memory.cpp:1101): free.
pub fn FreeClientMemory(pMemoryToFree: ?*anyopaque, szFile: ?[*:0]const u8, nLine: i32, nNull: i32) void {
    _ = .{ szFile, nLine, nNull };
    rawFree(pMemoryToFree);
}

/// ReAllocClientMemory (Memory.cpp:1107): realloc.
pub fn ReAllocClientMemory(pMemory: ?*anyopaque, nSize: usize, szFile: ?[*:0]const u8, nLine: usize, nUnused: u32) ?*anyopaque {
    _ = .{ szFile, nLine, nUnused };
    return rawRealloc(pMemory, nSize);
}

// Server-side (Memory.cpp:1119-1145)

/// AllocServerMemory (Memory.cpp:1119): calloc(1, nSize). Pool manager ignored.
pub fn AllocServerMemory(pPool: ?*D2PoolManagerStrc, nSize: usize, szFile: ?[*:0]const u8, nLine: i32) ?*anyopaque {
    _ = .{ pPool, szFile, nLine };
    return rawAlloc(nSize);
}

/// FreeServerMemory (Memory.cpp:1126): free. Pool manager ignored.
pub fn FreeServerMemory(pPool: ?*D2PoolManagerStrc, pMemoryToFree: ?*anyopaque, szFile: ?[*:0]const u8, nLine: i32, nNull: i32) void {
    _ = .{ pPool, szFile, nLine, nNull };
    rawFree(pMemoryToFree);
}

/// ReAllocServerMemory (Memory.cpp:1137): realloc. Pool manager ignored.
pub fn ReAllocServerMemory(pPool: ?*D2PoolManagerStrc, pMemory: ?*anyopaque, nNewSize: usize, szFile: ?[*:0]const u8, nLine: i32, nUnused: i32) ?*anyopaque {
    _ = .{ pPool, szFile, nLine, nUnused };
    return rawRealloc(pMemory, nNewSize);
}

const testing = std.testing;

test "alloc returns zeroed memory of the requested size" {
    const p = AllocServerMemory(null, 64, null, 0) orelse return error.OutOfMemory;
    defer FreeServerMemory(null, p, null, 0, 0);
    const bytes: [*]u8 = @ptrCast(p);
    for (0..64) |i| try testing.expectEqual(@as(u8, 0), bytes[i]);
}

test "realloc preserves contents and grows" {
    var p = AllocClientMemory(8, null, 0, 0) orelse return error.OutOfMemory;
    const b0: [*]u8 = @ptrCast(p);
    for (0..8) |i| b0[i] = @intCast(i + 1);
    p = ReAllocClientMemory(p, 32, null, 0, 0) orelse return error.OutOfMemory;
    defer FreeClientMemory(p, null, 0, 0);
    const b1: [*]u8 = @ptrCast(p);
    for (0..8) |i| try testing.expectEqual(@as(u8, @intCast(i + 1)), b1[i]);
    for (8..32) |i| try testing.expectEqual(@as(u8, 0), b1[i]); // grown region zeroed
}

test "alloc of zero returns null, free of null is a no-op" {
    try testing.expect(AllocServerMemory(null, 0, null, 0) == null);
    FreeServerMemory(null, null, null, 0, 0);
}

test "many allocs/frees under an arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const saved = allocator;
    allocator = arena.allocator();
    defer allocator = saved;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const p = AllocServerMemory(null, i % 256 + 1, null, 0);
        try testing.expect(p != null);
    }
}
