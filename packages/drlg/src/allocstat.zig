//! `d2-drlg allocstat` — where an act generation's memory actually goes.
//!
//! Two numbers decide whether a footprint problem is the generator's or its allocator's, and
//! neither is visible from process RSS (what `memcheck` reads):
//!
//!   * the TRUE peak — the most bytes simultaneously live, i.e. the floor any allocator must pay;
//!   * what a POWER-OF-TWO SIZE-CLASS allocator would charge for the same request stream.
//!
//! The second is `std.heap.BrkAllocator`, which is what wasm32-freestanding gets from
//! `std.heap.page_allocator` and what libd2 deliberately does NOT use (`d2-core`'s heap.zig
//! replaces it with a coalescing free list). It rounds every request up to the next power of two of
//! `max(len + @sizeOf(usize), alignment)` and keeps one free list PER SIZE CLASS that never
//! coalesces and never returns a page, so its footprint is the SUM OF PER-CLASS PEAKS rather than
//! the peak of the sum. Requests >= 64 KB go to the big-page classes, rounded to a power of two of
//! 64 KB pages, and are modelled the same way. Keeping the model here — over the real request
//! stream, on the host, with no wasm runtime in the loop — is what makes the gap a number: it is
//! the reason the wasm heap exists, and the thing to re-read if anyone proposes going back.
//!
//! The histogram is by size class rather than by call site on purpose: what the size-class model
//! costs is decided by which classes carry the peak, not by who allocated.

const std = @import("std");
const lib = @import("lib.zig");
const memcheck = @import("memcheck.zig");

/// Mirrors BrkAllocator's constants (std/heap/BrkAllocator.zig) for the model below.
const bigpage_size: usize = 64 * 1024;
const min_class: usize = std.math.log2(std.math.ceilPowerOfTwoAssert(usize, 1 + @sizeOf(usize)));
const size_class_count: usize = std.math.log2(bigpage_size) - min_class;
const big_class_count: usize = 24; // enough for 64 KB << 24; a single request never nears it

/// A pass-through allocator that accounts every request three ways.
const Stat = struct {
    child: std.mem.Allocator,

    live: usize = 0,
    peak: usize = 0,
    total: usize = 0,
    count: usize = 0,

    /// Per-size-class live/peak under BrkAllocator's rules.
    class_live: [size_class_count]usize = @splat(0),
    class_peak: [size_class_count]usize = @splat(0),
    class_count: [size_class_count]usize = @splat(0),
    big_live: [big_class_count]usize = @splat(0),
    big_peak: [big_class_count]usize = @splat(0),
    big_count: [big_class_count]usize = @splat(0),

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator(self: *Stat) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// BrkAllocator's slot size for one request: the power of two that holds the payload plus the
    /// free-list link it stores in-band, or the alignment if that is larger.
    fn slotSize(len: usize, alignment: std.mem.Alignment) usize {
        const actual = @max(len +| @sizeOf(usize), alignment.toByteUnits());
        return std.math.ceilPowerOfTwo(usize, actual) catch actual;
    }

    fn note(self: *Stat, len: usize, alignment: std.mem.Alignment, comptime add: bool) void {
        const slot = slotSize(len, alignment);
        if (slot < bigpage_size) {
            const c = std.math.log2(slot) - min_class;
            if (add) {
                self.class_live[c] += slot;
                self.class_count[c] += 1;
                self.class_peak[c] = @max(self.class_peak[c], self.class_live[c]);
            } else self.class_live[c] -= slot;
        } else {
            const pages = std.math.ceilPowerOfTwo(usize, (slot + bigpage_size - 1) / bigpage_size) catch 1;
            const c = @min(big_class_count - 1, std.math.log2(pages));
            const bytes = pages * bigpage_size;
            if (add) {
                self.big_live[c] += bytes;
                self.big_count[c] += 1;
                self.big_peak[c] = @max(self.big_peak[c], self.big_live[c]);
            } else self.big_live[c] -= bytes;
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Stat = @ptrCast(@alignCast(ctx));
        const p = self.child.vtable.alloc(self.child.ptr, len, alignment, ra) orelse return null;
        self.live += len;
        self.total += len;
        self.count += 1;
        self.peak = @max(self.peak, self.live);
        self.note(len, alignment, true);
        return p;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Stat = @ptrCast(@alignCast(ctx));
        // Only accept in-place growth the wasm allocator would also accept, so the model sees the
        // same request stream a wasm run would: a class change there becomes alloc+copy+free.
        if (slotSize(buf.len, alignment) != slotSize(new_len, alignment)) return false;
        if (!self.child.vtable.resize(self.child.ptr, buf, alignment, new_len, ra)) return false;
        self.live = self.live + new_len - buf.len;
        if (new_len > buf.len) self.total += new_len - buf.len;
        self.peak = @max(self.peak, self.live);
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Stat = @ptrCast(@alignCast(ctx));
        if (slotSize(buf.len, alignment) != slotSize(new_len, alignment)) return null;
        const p = self.child.vtable.remap(self.child.ptr, buf, alignment, new_len, ra) orelse return null;
        self.live = self.live + new_len - buf.len;
        if (new_len > buf.len) self.total += new_len - buf.len;
        self.peak = @max(self.peak, self.live);
        return p;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Stat = @ptrCast(@alignCast(ctx));
        self.live -= buf.len;
        self.note(buf.len, alignment, false);
        self.child.vtable.free(self.child.ptr, buf, alignment, ra);
    }

    /// Sum of per-class peaks: what BrkAllocator's linear memory grows to for this stream.
    fn modelledFootprint(self: *const Stat) usize {
        var t: usize = 0;
        for (self.class_peak) |v| t += v;
        for (self.big_peak) |v| t += v;
        return t;
    }
};

fn mb(v: usize) f64 {
    return @as(f64, @floatFromInt(v)) / (1024.0 * 1024.0);
}

pub fn run(gpa: std.mem.Allocator, acts: usize, live_handles: usize) u8 {
    var stat: Stat = .{ .child = gpa };
    const a = stat.allocator();

    {
        // The six raw DRLG .txt tables on their own, so the line below can be read as "the typed
        // rows LvlTables builds, plus the raw tables it keeps" — they are now parsed once and
        // shared (`Ctx.act`), which this is here to keep true.
        var src = @import("tables.zig").Tables.load(a) catch {
            std.debug.print("allocstat: table load failed\n", .{});
            return 1;
        };
        std.debug.print("one copy of the six .txt tables: {d:.1} MB live\n", .{mb(stat.live)});
        src.deinit();
    }
    var ctx = lib.Ctx.init(a) catch |err| {
        std.debug.print("allocstat: ctx init failed: {t}\n", .{err});
        return 1;
    };
    defer ctx.deinit();
    std.debug.print("ctx (tables, retained for the ctx's life): {d:.1} MB live\n", .{mb(stat.live)});

    const idle_after_ctx = stat.live;
    // A ring of live handles, so the shape matches a server holding one generated act per session
    // while it churns through others. `live_handles == 1` is the plain one-at-a-time shape.
    const ring = a.alloc(?std.heap.ArenaAllocator, @max(1, live_handles)) catch return 1;
    defer a.free(ring);
    @memset(ring, null);

    var seed: u32 = 0x12345678;
    var act_no: i32 = 0;
    var first_gen_retained: usize = 0;
    for (0..acts) |i| {
        const slot = i % ring.len;
        if (ring[slot]) |*old_handle| {
            old_handle.deinit();
            ring[slot] = null;
        }
        // Mirrors d2drlg_gen_act exactly: the handle's fields go in a per-act arena torn down
        // wholesale, the generation core allocates from ctx.gpa. An arena's `free` is a no-op, so
        // measuring against a plain allocator would hide anything the generator strands in it.
        var handle = std.heap.ArenaAllocator.init(a);
        var res = lib.generateActFull(&ctx, handle.allocator(), act_no, seed, .nightmare, .{ .walk = true }) catch |err| {
            std.debug.print("allocstat: act {d} failed: {t}\n", .{ act_no + 1, err });
            return 1;
        };
        _ = &res;
        ring[slot] = handle;
        if (i == 0) first_gen_retained = stat.live - idle_after_ctx;
        if (i % 20 == 19 or i == acts - 1) {
            var held: usize = 0;
            for (ring) |m| if (m != null) {
                held += 1;
            };
            std.debug.print("  cycle {d:>3}: {d:>2} handles live | {d:.1} MB live | peak so far {d:.1} MB\n", .{
                i + 1, held, mb(stat.live), mb(stat.peak),
            });
        }
        act_no += 1;
        if (act_no > 4) {
            act_no = 0;
            seed += 1;
        }
    }
    var still_held: usize = 0;
    for (ring) |m| if (m != null) {
        still_held += 1;
    };
    const with_handles = stat.live;
    for (ring) |*m| if (m.*) |*h| {
        h.deinit();
        m.* = null;
    };
    const after_free = stat.live;
    std.debug.print(
        \\
        \\{d} handles live cost {d:.1} MB => {d:.1} MB each
        \\after freeing them: {d:.1} MB live, vs {d:.1} MB right after ctx_create
        \\  ({d:.1} MB of that is one-time state the FIRST generation initialises; a leak would
        \\   instead scale with the {d} cycles)
        \\
    , .{
        still_held,        mb(with_handles - after_free),
        mb(if (still_held == 0) 0 else (with_handles - after_free) / still_held),
        mb(after_free),    mb(idle_after_ctx),
        mb(after_free - idle_after_ctx), acts,
    });

    std.debug.print(
        \\
        \\true peak live      {d:.1} MB   <- the floor any allocator must pay
        \\size-class model    {d:.1} MB   <- what std's power-of-two wasm allocator would charge
        \\total ever alloc'd  {d:.1} MB in {d} requests
        \\process peak RSS    {d:.1} MB   <- what the OS saw, incl. this binary and smp_allocator slack
        \\
        \\ size class     requests   class peak   (share of model)
        \\
    , .{
        mb(stat.peak),                 mb(stat.modelledFootprint()),
        mb(stat.total),                stat.count,
        mb(memcheck.peakRssBytes() orelse 0),
    });

    const model = stat.modelledFootprint();
    for (stat.class_peak, stat.class_count, 0..) |pk, n, i| {
        if (pk == 0) continue;
        const slot = @as(usize, 1) << @intCast(i + min_class);
        std.debug.print("  {d:>9} B  {d:>9}   {d:>8.1} MB   {d:>5.1}%\n", .{
            slot, n, mb(pk), 100.0 * mb(pk) / mb(model),
        });
    }
    for (stat.big_peak, stat.big_count, 0..) |pk, n, i| {
        if (pk == 0) continue;
        std.debug.print("  {d:>7} KB  {d:>9}   {d:>8.1} MB   {d:>5.1}%\n", .{
            (bigpage_size << @intCast(i)) / 1024, n, mb(pk), 100.0 * mb(pk) / mb(model),
        });
    }
    return 0;
}
