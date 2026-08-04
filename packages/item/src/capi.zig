//! C-ABI shim for the d2-item package: exposes seed-driven drop generation to
//! C/C++/C#/Node and to a freestanding wasm module. NO Zig types cross the
//! boundary — only C primitives, fixed ints, pointers and `extern struct`s.
//!
//! Allocator note: page_allocator only (works native AND wasm32-freestanding
//! without libc). The loaded Tables + TCSet live on a persistent arena stored in
//! the opaque Ctx; each roll uses a throwaway arena copied into the caller buffer.

const std = @import("std");
const lib = @import("lib.zig");

/// Mirrors `model.Drop`, flattened to C. Field order/types MUST match d2item.h.
pub const D2ItemDrop = extern struct {
    kind: u8, // DropKind tag: none=0 gold=1 item=2 quiver=3 bodypart=4
    item_code: [4]u8,
    quality: u8, // Quality enum(u8) tag value
    prefix_id: u16,
    suffix_id: u16,
    rare_prefix_ids: [3]u16,
    rare_suffix_ids: [3]u16,
    rare_prefix_name: u16,
    rare_suffix_name: u16,
    unique_id: u16,
    set_id: u16,
    quality_id: u16,
    low_quality_id: u16,
    auto_prefix_id: u16,
    sockets: u8,
    ethereal: u8,
    quantity: i32,
    item_level: i32,
    item_seed: u32,
};

// The layout d2item.h and the npm shims hard-code. Any field added or reordered above must move
// these numbers too, so pin them here rather than discovering the mismatch at a call site.
comptime {
    const eq = std.debug.assert;
    eq(@sizeOf(D2ItemDrop) == 52);
    eq(@offsetOf(D2ItemDrop, "rare_prefix_ids") == 10);
    eq(@offsetOf(D2ItemDrop, "rare_suffix_ids") == 16);
    eq(@offsetOf(D2ItemDrop, "rare_prefix_name") == 22);
    eq(@offsetOf(D2ItemDrop, "unique_id") == 26);
    eq(@offsetOf(D2ItemDrop, "low_quality_id") == 32);
    eq(@offsetOf(D2ItemDrop, "sockets") == 36);
    eq(@offsetOf(D2ItemDrop, "ethereal") == 37);
    eq(@offsetOf(D2ItemDrop, "quantity") == 40);
    eq(@offsetOf(D2ItemDrop, "item_seed") == 48);
}

/// Opaque context: the loaded tables + treasure sets, built once. The C side only
/// ever sees `*D2ItemCtx` (an opaque pointer).
pub const Ctx = struct {
    arena: std.heap.ArenaAllocator,
    tables: lib.Tables,
    set: lib.TCSet,
};

/// Loads tables + treasure sets. Returns null on any failure.
export fn d2item_create() ?*Ctx {
    const pa = std.heap.page_allocator;
    const ctx = pa.create(Ctx) catch return null;
    ctx.arena = std.heap.ArenaAllocator.init(pa);
    const a = ctx.arena.allocator();

    ctx.tables = lib.Tables.load(a) catch {
        ctx.arena.deinit();
        pa.destroy(ctx);
        return null;
    };
    ctx.set = lib.treasure.build(a, &ctx.tables) catch {
        ctx.arena.deinit();
        pa.destroy(ctx);
        return null;
    };
    return ctx;
}

export fn d2item_destroy(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    c.arena.deinit();
    std.heap.page_allocator.destroy(c);
}

/// Rolls a drop. Writes up to `cap` drops into `out`, returns the FULL count
/// produced (so a caller can detect truncation) or a negative error code.
export fn d2item_roll(
    ctx: ?*Ctx,
    seed: u32,
    tc_name: [*:0]const u8,
    mlvl: i32,
    mf: i32,
    out: [*]D2ItemDrop,
    cap: i32,
) i32 {
    const c = ctx orelse return -1;
    if (cap < 0) return -2;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const name: []const u8 = std.mem.span(tc_name);
    var drop_seed = lib.Seed.init(seed, 0x29a);
    var game_seed = lib.Seed.init(seed ^ 0x5eed, 0x29a);
    const drops = lib.rollDrop(a, &drop_seed, &game_seed, &c.tables, &c.set, name, mlvl, .{
        .magic_find = mf,
    }) catch return -3;

    const cap_us: usize = @intCast(cap);
    const n = @min(drops.len, cap_us);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const d = drops[i];
        out[i] = .{
            .kind = @intFromEnum(d.kind),
            .item_code = d.item_code,
            .quality = @intFromEnum(d.quality),
            .prefix_id = d.prefix_id,
            .suffix_id = d.suffix_id,
            .rare_prefix_ids = d.rare_prefix_ids,
            .rare_suffix_ids = d.rare_suffix_ids,
            .rare_prefix_name = d.rare_prefix_name,
            .rare_suffix_name = d.rare_suffix_name,
            .unique_id = d.unique_id,
            .set_id = d.set_id,
            .quality_id = d.quality_id,
            .low_quality_id = d.low_quality_id,
            .auto_prefix_id = d.auto_prefix_id,
            .sockets = d.sockets,
            .ethereal = @intFromBool(d.ethereal),
            .quantity = d.quantity,
            .item_level = d.item_level,
            .item_seed = d.item_seed,
        };
    }
    return @intCast(drops.len);
}

export fn d2item_abi_version() u32 {
    return 2;
}
