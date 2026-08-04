//! Coarse phase timers for the render path. Off unless a host installs `clock`, so the
//! wasm/freestanding builds (which have no clock at all) and every normal caller pay only a
//! null-pointer test per phase.
//!
//! The library deliberately does NOT reach for a clock itself: `packages/drlg` links no libc,
//! and this std's `Timer` is stripped in that configuration. The host that already has a
//! monotonic clock (drlg-server has `clock_gettime`) hands it in.

const std = @import("std");
const builtin = @import("builtin");

/// wasm32 has no 64-bit atomics, and a single-threaded target cannot race anyway. Those
/// builds never install a clock (they have none), so the plain adds are dead code there.
const atomic_totals = !builtin.single_threaded and @bitSizeOf(usize) >= 64;

pub const Phase = enum {
    /// DRLG proper: InitLevel (room layout, presets, tile placement).
    generate,
    /// Per-room collision grids: DT1 lookup + stamping. Sum of the three below plus setup.
    materialize,
    /// Materialize each of the level's own rooms to its placed tile list (DS1 unpack + tilegen).
    mat_rooms,
    /// Parse one room's preset DS1 out of the embedded blob.
    mat_ds1_unpack,
    /// Place a preset room's DS1 layers into collision tiles.
    mat_ds1_build,
    /// …of which: DS1 cell layers → windowed i32 grids.
    ds1_grids,
    /// …of which: count the room's tiles and allocate its tile arrays.
    ds1_count,
    /// …of which: InitRoomTiles per layer.
    ds1_init,
    /// …of which: blit the placed tiles into the room's subtile grid.
    ds1_blit,
    /// Place an outdoor (wilderness/maze) room's tiles.
    mat_outdoor,
    /// Same, for rooms in OTHER levels that this level's rooms gather collision from.
    mat_foreign,
    /// AllocRoomCollisionGrid: stamp every reaching tile into every room's grid.
    mat_stamp,
    /// Blank.dt1 fill of every subtile whose tile-cell no floor tile covered.
    mat_voidfill,
    /// Per-room grids OR'd into one level-sized u16 CollMap.
    composite,
    /// zlib of the CollMap.
    deflate,
    /// Walk grid derive + zlib (only when `?walk=`).
    walk,
    /// Rooms / presets / adjacents extraction.
    collect,
    /// DBM JSON text + base64.
    serialize,
};

const n_phases = @typeInfo(Phase).@"enum".fields.len;

/// Monotonic nanoseconds. Null = profiling off (the default).
pub var clock: ?*const fn () i64 = null;

var totals: [n_phases]u64 = @splat(0);

pub inline fn begin() i64 {
    const c = clock orelse return 0;
    return c();
}

pub inline fn end(p: Phase, t0: i64) void {
    const c = clock orelse return;
    const dt: u64 = @intCast(@max(0, c() - t0));
    const slot = &totals[@intFromEnum(p)];
    if (atomic_totals) _ = @atomicRmw(u64, slot, .Add, dt, .monotonic) else slot.* += dt;
}

pub fn reset() void {
    for (&totals) |*t| {
        if (atomic_totals) @atomicStore(u64, t, 0, .monotonic) else t.* = 0;
    }
}

pub fn get(p: Phase) u64 {
    const slot = &totals[@intFromEnum(p)];
    return if (atomic_totals) @atomicLoad(u64, slot, .monotonic) else slot.*;
}
