//! C-ABI shim for the d2-items package: exposes seed-driven drop generation to
//! C/C++/C#/Node and to a freestanding wasm module. NO Zig types cross the
//! boundary — only C primitives, fixed ints, pointers and `extern struct`s.
//!
//! Allocator note: page_allocator only (works native AND wasm32-freestanding
//! without libc). The loaded Tables + TCSet live on a persistent arena stored in
//! the opaque Ctx; each roll uses a throwaway arena copied into the caller buffer.

const std = @import("std");
const lib = @import("lib.zig");

/// Mirrors `model.Drop`, flattened to C. Field order/types MUST match d2items.h.
pub const D2ItemsDrop = extern struct {
    kind: u8, // DropKind tag: none=0 gold=1 item=2 quiver=3 bodypart=4
    item_code: [4]u8,
    quality: u8, // Quality enum(u8) tag value
    prefix_id: u16,
    suffix_id: u16,
    rare_prefix_ids: [3]u16,
    rare_suffix_ids: [3]u16,
    sockets: u8,
    quantity: i32,
    item_level: i32,
};

/// Opaque context: the loaded tables + treasure sets, built once. The C side only
/// ever sees `*D2ItemsCtx` (an opaque pointer).
pub const Ctx = struct {
    arena: std.heap.ArenaAllocator,
    tables: lib.Tables,
    set: lib.TCSet,
};

/// Loads tables + treasure sets. Returns null on any failure.
export fn d2items_create() ?*Ctx {
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

export fn d2items_destroy(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    c.arena.deinit();
    std.heap.page_allocator.destroy(c);
}

/// Rolls a drop. Writes up to `cap` drops into `out`, returns the FULL count
/// produced (so a caller can detect truncation) or a negative error code.
export fn d2items_roll(
    ctx: ?*Ctx,
    seed: u32,
    tc_name: [*:0]const u8,
    mlvl: i32,
    mf: i32,
    out: [*]D2ItemsDrop,
    cap: i32,
) i32 {
    const c = ctx orelse return -1;
    if (cap < 0) return -2;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const name: []const u8 = std.mem.span(tc_name);
    var drop_seed = lib.Seed.init(seed, 0x29a);
    const drops = lib.rollDrop(a, &drop_seed, &c.tables, &c.set, name, mlvl, .{
        .magic_find = mf,
        .item_seed_base = seed ^ 0x5eed,
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
            .sockets = d.sockets,
            .quantity = d.quantity,
            .item_level = d.item_level,
        };
    }
    return @intCast(drops.len);
}

export fn d2items_abi_version() u32 {
    return 1;
}
