//! Fog::Memory — Diablo II 1.14d segregated-slab pool allocator, reimplemented
//! faithfully in idiomatic Zig (behaviour-faithful, not byte-layout-faithful).
//!
//! The engine's Fog::Memory::Alloc (Game.exe 0x40a080) is a slab allocator: a
//! pool manager owns N size classes, each class a chain of large blocks carved
//! into fixed-size slots tracked by a bitmap. Requests larger than the biggest
//! class go to individually-allocated "overflow" nodes. Destroying the manager
//! releases every block at once — the whole-pool teardown we want for per-scope
//! (per-level / per-act / per-game) memory.
//!
//! This replica keeps that observable model but backs blocks with a
//! `std.mem.Allocator` (default: page_allocator, matching VirtualAlloc's
//! zeroed pages) instead of raw VirtualAlloc, and drops the CRITICAL_SECTIONs /
//! exact struct offsets. The allocator does NOT consume RNG, so swapping it in
//! under the DRLG is byte-exact-neutral (the seed never sees pointer values).
//!
//! Size classes (k = 0..14): slot size S(k) = 16 << k, covering
//! (2^(k+3), 2^(k+4)]. Region size + slots-per-block per class come straight
//! from InitializePoolSystem's three regimes (see `classRegion`).

const std = @import("std");
const Alignment = std.mem.Alignment;

pub const NUM_CLASSES = 15;
const MIN_SLOT = 16;

/// ComputeSizeClassIndex (0x4091b0): size ≤ 16 → class 0; else floor_log2(size-1) - 3.
/// Returns null when size exceeds the largest class (→ overflow path).
fn classIndex(size: usize) ?usize {
    if (size <= MIN_SLOT) return 0;
    const high_bit: usize = 63 - @clz(@as(u64, size - 1)); // index of top set bit
    const k = high_bit - 3;
    if (k >= NUM_CLASSES) return null;
    return k;
}

fn slotSize(k: usize) usize {
    return @as(usize, MIN_SLOT) << @intCast(k);
}

/// InitializePoolSystem region regime: for slot size S, pick the VirtualAlloc
/// region byte size, from which slots-per-block = region / S.
fn classRegion(slot: usize) usize {
    const q = slot * 256;
    if (q < 0x10000) return 0x10000; // small slots: 64KB blocks
    if (q < 0x40000) return q; // mid slots: exactly 256 slots
    return 0x80000; // large slots: 512KB blocks
}

/// One slab block: a region carved into `pool.slots` fixed slots, plus a bitmap
/// (bit set = slot in use). Blocks are chained per size class.
const Block = struct {
    region: []u8,
    bitmap: []u32,
    used: usize,
    next: ?*Block,

    fn findFreeSlot(self: *Block, slots: usize) ?usize {
        for (self.bitmap, 0..) |word, wi| {
            if (word == 0xffff_ffff) continue;
            const bit = @ctz(~word);
            const slot = wi * 32 + bit;
            if (slot >= slots) return null;
            return slot;
        }
        return null;
    }

    inline fn setBit(self: *Block, slot: usize) void {
        self.bitmap[slot >> 5] |= @as(u32, 1) << @intCast(slot & 31);
    }
    inline fn clearBit(self: *Block, slot: usize) void {
        self.bitmap[slot >> 5] &= ~(@as(u32, 1) << @intCast(slot & 31));
    }
    inline fn contains(self: *Block, ptr: [*]u8) bool {
        const base = @intFromPtr(self.region.ptr);
        const p = @intFromPtr(ptr);
        return p >= base and p < base + self.region.len;
    }
};

const PoolClass = struct {
    slot_size: usize,
    slots: usize,
    region_size: usize,
    blocks: ?*Block = null,
};

/// An oversize / over-aligned allocation, tracked so free + teardown can release
/// it with the exact alignment it was created with.
const Overflow = struct {
    mem: []u8,
    alignment: Alignment,
    next: ?*Overflow,
};

/// A pool manager: the unit that grows on demand and is freed wholesale via
/// `deinit`. Mirrors a Fog::Memory pool manager (one per scope in the engine:
/// per act, per game, ...).
pub const PoolManager = struct {
    backing: std.mem.Allocator,
    classes: [NUM_CLASSES]PoolClass,
    overflow: ?*Overflow = null,

    pub fn init(backing: std.mem.Allocator) PoolManager {
        var classes: [NUM_CLASSES]PoolClass = undefined;
        for (&classes, 0..) |*c, k| {
            const s = slotSize(k);
            const region = classRegion(s);
            c.* = .{ .slot_size = s, .slots = region / s, .region_size = region };
        }
        return .{ .backing = backing, .classes = classes };
    }

    /// FreeMemoryPool (0x409c80): release every block of every class and every
    /// overflow node in one shot. After this the manager is empty and reusable.
    pub fn deinit(self: *PoolManager) void {
        for (&self.classes) |*c| {
            const region_align = Alignment.fromByteUnits(c.slot_size);
            var b = c.blocks;
            while (b) |blk| {
                const next = blk.next;
                self.rawFree(blk.region, region_align);
                self.backing.free(blk.bitmap);
                self.backing.destroy(blk);
                b = next;
            }
            c.blocks = null;
        }
        var o = self.overflow;
        while (o) |node| {
            const next = node.next;
            self.rawFree(node.mem, node.alignment);
            self.backing.destroy(node);
            o = next;
        }
        self.overflow = null;
    }

    pub fn allocator(self: *PoolManager) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // Runtime-aligned backing alloc/free (the public Allocator API only takes a
    // comptime alignment; regions/overflow need a runtime one).
    fn rawAlloc(self: *PoolManager, len: usize, alignment: Alignment) ?[]u8 {
        const p = self.backing.vtable.alloc(self.backing.ptr, len, alignment, @returnAddress()) orelse return null;
        return p[0..len];
    }
    fn rawFree(self: *PoolManager, memory: []u8, alignment: Alignment) void {
        self.backing.vtable.free(self.backing.ptr, memory, alignment, @returnAddress());
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = vRemap,
        .free = vFree,
    };

    // AllocatePoolBlock (0x4095e0): grab a fresh region aligned to the class's
    // slot size (so every slot satisfies alignments up to slot_size) + a bitmap,
    // push to the class's block chain.
    fn growBlock(self: *PoolManager, c: *PoolClass) ?*Block {
        const blk = self.backing.create(Block) catch return null;
        const region_align = Alignment.fromByteUnits(c.slot_size);
        const region = self.rawAlloc(c.region_size, region_align) orelse {
            self.backing.destroy(blk);
            return null;
        };
        const words = (c.slots + 31) >> 5;
        const bitmap = self.backing.alloc(u32, words) catch {
            self.rawFree(region, region_align);
            self.backing.destroy(blk);
            return null;
        };
        @memset(region, 0); // VirtualAlloc(MEM_COMMIT) hands back zeroed pages
        @memset(bitmap, 0);
        blk.* = .{ .region = region, .bitmap = bitmap, .used = 0, .next = c.blocks };
        c.blocks = blk;
        return blk;
    }

    /// True when a request of `len`/`alignment` cannot be served from a slab slot
    /// (too big, or needs more alignment than its class's slot provides) and must
    /// go to an overflow node.
    fn isOverflow(self: *const PoolManager, len: usize, align_bytes: usize) bool {
        const ci = classIndex(len) orelse return true;
        return align_bytes > self.classes[ci].slot_size;
    }

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *PoolManager = @ptrCast(@alignCast(ctx));
        const want = if (len == 0) 1 else len;
        const align_bytes = alignment.toByteUnits();

        if (self.isOverflow(want, align_bytes)) {
            const node = self.backing.create(Overflow) catch return null;
            const mem = self.rawAlloc(want, alignment) orelse {
                self.backing.destroy(node);
                return null;
            };
            node.* = .{ .mem = mem, .alignment = alignment, .next = self.overflow };
            self.overflow = node;
            return mem.ptr;
        }

        const c = &self.classes[classIndex(want).?];
        // FindOrCreateBlockWithFreeSlots (0x409700): first block with a free slot.
        var b = c.blocks;
        while (b) |blk| : (b = blk.next) {
            if (blk.used < c.slots) {
                if (blk.findFreeSlot(c.slots)) |slot| {
                    blk.setBit(slot);
                    blk.used += 1;
                    return blk.region.ptr + slot * c.slot_size;
                }
            }
        }
        const blk = self.growBlock(c) orelse return null;
        blk.setBit(0);
        blk.used = 1;
        return blk.region.ptr;
    }

    fn vFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = ret_addr;
        const self: *PoolManager = @ptrCast(@alignCast(ctx));
        const len = if (memory.len == 0) 1 else memory.len;
        const align_bytes = alignment.toByteUnits();

        if (self.isOverflow(len, align_bytes)) {
            self.freeOverflow(memory.ptr);
            return;
        }
        const c = &self.classes[classIndex(len).?];
        var b = c.blocks;
        while (b) |blk| : (b = blk.next) {
            if (blk.contains(memory.ptr)) {
                const slot = (@intFromPtr(memory.ptr) - @intFromPtr(blk.region.ptr)) / c.slot_size;
                blk.clearBit(slot);
                blk.used -= 1;
                return;
            }
        }
        // Fell through — treat as overflow (defensive; shouldn't happen).
        self.freeOverflow(memory.ptr);
    }

    fn freeOverflow(self: *PoolManager, ptr: [*]u8) void {
        var pp = &self.overflow;
        while (pp.*) |node| {
            if (node.mem.ptr == ptr) {
                pp.* = node.next;
                self.rawFree(node.mem, node.alignment);
                self.backing.destroy(node);
                return;
            }
            pp = &node.next;
        }
    }

    fn vResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        const self: *PoolManager = @ptrCast(@alignCast(ctx));
        const align_bytes = alignment.toByteUnits();
        const old_len = if (memory.len == 0) 1 else memory.len;
        const new = if (new_len == 0) 1 else new_len;
        // Overflow allocations can't grow/shrink in place here.
        if (self.isOverflow(old_len, align_bytes) or self.isOverflow(new, align_bytes)) return false;
        // In-place only while the slot still fits (same size class).
        return classIndex(old_len).? == classIndex(new).?;
    }

    fn vRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        // No move-in-place; when it fits the same slot keep the pointer, else let
        // the caller fall back to alloc+copy+free.
        if (vResize(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
        return null;
    }
};

// tests

const testing = std.testing;

/// Region/slots per class, straight from InitializePoolSystem's three regimes.
const class_table = [NUM_CLASSES][3]usize{
    // slot,   region,  slots
    .{ 16, 0x10000, 4096 }, .{ 32, 0x10000, 2048 }, .{ 64, 0x10000, 1024 },
    .{ 128, 0x10000, 512 }, .{ 256, 0x10000, 256 },  .{ 512, 0x20000, 256 },
    .{ 1024, 0x80000, 512 }, .{ 2048, 0x80000, 256 }, .{ 4096, 0x80000, 128 },
    .{ 8192, 0x80000, 64 },  .{ 0x4000, 0x80000, 32 }, .{ 0x8000, 0x80000, 16 },
    .{ 0x10000, 0x80000, 8 }, .{ 0x20000, 0x80000, 4 }, .{ 0x40000, 0x80000, 2 },
};

test "size-class mapping matches the engine boundaries" {
    try testing.expectEqual(@as(?usize, 0), classIndex(1));
    try testing.expectEqual(@as(?usize, 0), classIndex(16));
    try testing.expectEqual(@as(?usize, 1), classIndex(17));
    try testing.expectEqual(@as(?usize, 1), classIndex(32));
    try testing.expectEqual(@as(?usize, 2), classIndex(33));
    // Every class boundary: 2^(k+4) maps to k, 2^(k+4)+1 maps to k+1.
    for (0..NUM_CLASSES) |k| {
        try testing.expectEqual(@as(?usize, k), classIndex(slotSize(k)));
        if (k > 0) try testing.expectEqual(@as(?usize, k), classIndex(slotSize(k - 1) + 1));
    }
    try testing.expectEqual(@as(?usize, 14), classIndex(0x40000));
    try testing.expectEqual(@as(?usize, null), classIndex(0x40001)); // overflow
}

test "region/slots table matches InitializePoolSystem for all 15 classes" {
    for (class_table, 0..) |e, k| {
        const s = slotSize(k);
        try testing.expectEqual(e[0], s);
        try testing.expectEqual(e[1], classRegion(s));
        try testing.expectEqual(e[2], classRegion(s) / s);
    }
}

test "alloc/free reuses slots and teardown frees everything" {
    var pm = PoolManager.init(testing.allocator);
    defer pm.deinit();
    const a = pm.allocator();

    const p0 = try a.alloc(u8, 16);
    const p1 = try a.alloc(u8, 16);
    try testing.expect(p0.ptr != p1.ptr);

    a.free(p0);
    const p2 = try a.alloc(u8, 16); // reuses p0's freed slot
    try testing.expectEqual(p0.ptr, p2.ptr);

    a.free(p1);
    a.free(p2);
}

fn countBlocks(c: *const PoolClass) usize {
    var n: usize = 0;
    var b = c.blocks;
    while (b) |blk| : (b = blk.next) n += 1;
    return n;
}

test "a class grows a second block once the first is full" {
    var pm = PoolManager.init(testing.allocator);
    defer pm.deinit();
    const a = pm.allocator();

    const slots = pm.classes[0].slots; // 4096 for class 0
    var ptrs = try testing.allocator.alloc([]u8, slots + 1);
    defer testing.allocator.free(ptrs);
    for (ptrs) |*p| p.* = try a.alloc(u8, 1);

    try testing.expectEqual(@as(usize, 2), countBlocks(&pm.classes[0]));
    // Every slot distinct (no aliasing across the two blocks).
    for (ptrs, 0..) |pa, i| for (ptrs[i + 1 ..]) |pb| try testing.expect(pa.ptr != pb.ptr);

    for (ptrs) |p| a.free(p);
}

test "oversize goes through the overflow path and frees" {
    var pm = PoolManager.init(testing.allocator);
    defer pm.deinit();
    const a = pm.allocator();
    const big = try a.alloc(u8, 0x50000); // > largest class
    try testing.expect(pm.overflow != null);
    big[0] = 0xab;
    big[big.len - 1] = 0xcd;
    a.free(big);
    try testing.expect(pm.overflow == null);
}

test "alignment is honoured for slab and over-slot (overflow) requests" {
    var pm = PoolManager.init(testing.allocator);
    defer pm.deinit();
    const a = pm.allocator();

    inline for (.{ 16, 64, 256, 4096 }) |al| {
        const p = try a.alignedAlloc(u8, .fromByteUnits(al), 8);
        try testing.expect(std.mem.isAligned(@intFromPtr(p.ptr), al));
        a.free(p);
    }
    // A small request needing more alignment than its slot → overflow, still aligned.
    const q = try a.alignedAlloc(u8, .fromByteUnits(0x2000), 16); // 8KB align, 16B len
    try testing.expect(std.mem.isAligned(@intFromPtr(q.ptr), 0x2000));
    try testing.expect(pm.overflow != null);
    a.free(q);
}

test "no two live allocations overlap (randomised stress) and nothing leaks" {
    var pm = PoolManager.init(testing.allocator);
    defer pm.deinit();
    const a = pm.allocator();

    const Live = struct { mem: []u8, tag: u8 };
    var live: std.ArrayListUnmanaged(Live) = .empty;
    defer live.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x1337c0de);
    const rand = prng.random();
    var tag: u8 = 0;

    var step: usize = 0;
    while (step < 4000) : (step += 1) {
        if (live.items.len > 0 and rand.boolean()) {
            // Free a random live allocation.
            const idx = rand.uintLessThan(usize, live.items.len);
            const it = live.swapRemove(idx);
            for (it.mem) |b| try testing.expectEqual(it.tag, b); // no one stomped it
            a.free(it.mem);
        } else {
            const n = rand.uintLessThan(usize, 2000) + 1;
            const mem = try a.alloc(u8, n);
            const s = @intFromPtr(mem.ptr);
            // Verify disjoint from every currently-live allocation.
            for (live.items) |o| {
                const os = @intFromPtr(o.mem.ptr);
                try testing.expect(s + mem.len <= os or os + o.mem.len <= s);
            }
            tag +%= 1;
            @memset(mem, tag);
            try live.append(testing.allocator, .{ .mem = mem, .tag = tag });
        }
    }
    for (live.items) |it| a.free(it.mem);
}

test "realloc grows across classes copying data, and shrinks in place" {
    var pm = PoolManager.init(testing.allocator);
    defer pm.deinit();
    const a = pm.allocator();

    var buf = try a.alloc(u8, 16);
    @memset(buf, 0x7e);
    buf = try a.realloc(buf, 4096); // crosses classes -> copy
    for (buf[0..16]) |b| try testing.expectEqual(@as(u8, 0x7e), b);
    buf = try a.realloc(buf, 100); // shrink within capacity
    a.free(buf);
}

test "conforms to std.heap allocator test batteries" {
    var pm = PoolManager.init(testing.allocator);
    defer pm.deinit();
    const a = pm.allocator();
    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}
