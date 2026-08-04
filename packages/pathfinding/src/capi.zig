//! C-ABI shim for d2-pathfinding: routing over a world d2drlg generated, exposed to C/C++/
//! C#/Node and to a wasm reactor module. NO Zig types cross the boundary — only C primitives,
//! fixed ints, pointers and `extern struct`s. Every export catches all Zig errors and returns
//! a negative status / null; nothing escapes.
//!
//! This shim takes the GENERATION context rather than owning one, so a host that already has a
//! d2drlg context routes over the act it already has. Linked together — as they are in the
//! combined wasm — the two halves share a linear memory and no collision data is copied across
//! the boundary to answer a route.
//!
//! Allocator note: page_allocator for the caller-facing handles, matching d2drlg's shim. Both
//! are libc-free, so no artifact links libc and the wasm build targets wasm32-freestanding.

const std = @import("std");
const pf = @import("lib.zig");
const drlg = @import("d2-drlg");

const pa = std.heap.page_allocator;

/// A position: Levels.txt id + LEVEL-LOCAL subtiles. Must match `D2PfPos` in d2pf.h.
pub const D2PfPos = extern struct { level: i32, x: i32, y: i32 };

/// One step of a route. `kind` is 0 walk, 1 teleport, 2 pad. Must match `D2PfMove` in d2pf.h.
pub const D2PfMove = extern struct { x: i32, y: i32, kind: i32 };

/// Routing options. Must match `D2PfOptions` in d2pf.h, padding included.
pub const D2PfOptions = extern struct {
    mask: u16,
    teleport: i32,
    teleport_across_levels: i32,
    teleport_max_cast: i32,
    teleport_metric: i32,
    snap_radius: i32,
};

/// Opaque routing world. Holds the generation context it was handed, because `loadAct` needs it
/// on every call and a caller should not have to pass it twice.
pub const World = struct {
    inner: pf.World,
    ctx: *drlg.Ctx,
};

/// Opaque computed route.
pub const Route = struct {
    inner: pf.Route,
};

fn diffFromInt(difficulty: i32) ?drlg.Difficulty {
    return switch (difficulty) {
        0 => .normal,
        1 => .nightmare,
        2 => .hell,
        else => null,
    };
}

fn optsFrom(o: ?*const D2PfOptions) pf.Options {
    const c = o orelse return .{};
    return .{
        .mask = c.mask,
        .teleport = c.teleport != 0,
        .teleport_across_levels = c.teleport_across_levels != 0,
        .teleport_max_cast = if (c.teleport_max_cast < 0) null else c.teleport_max_cast,
        .teleport_metric = if (c.teleport_metric == 1) .euclidean else .chebyshev,
        .snap_radius = c.snap_radius,
    };
}

export fn d2pf_options_default(out: ?*D2PfOptions) void {
    const o = out orelse return;
    const d: pf.Options = .{};
    o.* = .{
        .mask = d.mask,
        .teleport = @intFromBool(d.teleport),
        .teleport_across_levels = @intFromBool(d.teleport_across_levels),
        .teleport_max_cast = d.teleport_max_cast orelse -1,
        .teleport_metric = @intFromEnum(d.teleport_metric),
        .snap_radius = d.snap_radius,
    };
}

/// `ctx` is what d2drlg_ctx_core returns: the loaded tables themselves, not d2drlg's own
/// handle wrapper. Going through that accessor rather than casting the handle is what keeps
/// the two shims free to change their wrapper layouts independently.
export fn d2pf_world_create(ctx: ?*anyopaque, seed: u32, difficulty: i32) ?*World {
    const raw = ctx orelse return null;
    const diff = diffFromInt(difficulty) orelse return null;
    const c: *drlg.Ctx = @ptrCast(@alignCast(raw));
    const w = pa.create(World) catch return null;
    w.* = .{ .inner = pf.World.init(pa, seed, diff), .ctx = c };
    return w;
}

export fn d2pf_world_destroy(world: ?*World) void {
    const w = world orelse return;
    w.inner.deinit();
    pa.destroy(w);
}

export fn d2pf_world_load_act(world: ?*World, act_no: i32) i32 {
    const w = world orelse return -1;
    if (act_no < 0 or act_no > 4) return -2;
    w.inner.loadAct(w.ctx, act_no) catch return -3;
    return 0;
}

export fn d2pf_route(world: ?*World, from: D2PfPos, to: D2PfPos, opts: ?*const D2PfOptions) ?*Route {
    const w = world orelse return null;
    const r = w.inner.route(
        .{ .level = from.level, .x = from.x, .y = from.y },
        .{ .level = to.level, .x = to.x, .y = to.y },
        optsFrom(opts),
    ) catch return null;
    const out = pa.create(Route) catch {
        var tmp = r;
        tmp.deinit();
        return null;
    };
    out.* = .{ .inner = r };
    return out;
}

export fn d2pf_route_free(route: ?*Route) void {
    const r = route orelse return;
    r.inner.deinit();
    pa.destroy(r);
}

export fn d2pf_route_leg_count(route: ?*Route) i32 {
    const r = route orelse return -1;
    return @intCast(r.inner.legs.len);
}

export fn d2pf_route_move_count(route: ?*Route) i32 {
    const r = route orelse return -1;
    return @intCast(r.inner.moveCount());
}

export fn d2pf_route_leg_level(route: ?*Route, leg: i32) i32 {
    const r = route orelse return -1;
    if (leg < 0 or leg >= r.inner.legs.len) return -1;
    return r.inner.legs[@intCast(leg)].level;
}

export fn d2pf_route_leg_exit(route: ?*Route, leg: i32) i32 {
    const r = route orelse return -1;
    if (leg < 0 or leg >= r.inner.legs.len) return -1;
    const e = r.inner.legs[@intCast(leg)].exit orelse return -1;
    return e.to_level;
}

export fn d2pf_route_leg_moves(route: ?*Route, leg: i32, out: [*]D2PfMove, cap: i32) i32 {
    const r = route orelse return -1;
    if (cap < 0) return -2;
    if (leg < 0 or leg >= r.inner.legs.len) return -3;
    const moves = r.inner.legs[@intCast(leg)].moves;
    const n = @min(moves.len, @as(usize, @intCast(cap)));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = .{ .x = moves[i].x, .y = moves[i].y, .kind = @intFromEnum(moves[i].kind) };
    }
    return @intCast(moves.len);
}

export fn d2pf_level_route(world: ?*World, from: i32, to: i32, out: [*]i32, cap: i32) i32 {
    const w = world orelse return -1;
    if (cap < 0) return -2;
    var ids: std.ArrayListUnmanaged(i32) = .empty;
    defer ids.deinit(pa);
    w.inner.levelRoute(from, to, &ids) catch return -3;
    const n = @min(ids.items.len, @as(usize, @intCast(cap)));
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = ids.items[i];
    return @intCast(ids.items.len);
}

/// The pass map a walking player uses, or the caller's own mask when non-zero.
fn passMapOf(w: *World, level_id: i32, mask: u16) ?*pf.grid.PassMap {
    const lv = w.inner.level(level_id) orelse return null;
    const m = if (mask == 0) pf.Colmask.player_path else mask;
    return lv.passMap(m) catch null;
}

export fn d2pf_walkable(world: ?*World, level_id: i32, x: i32, y: i32) i32 {
    const w = world orelse return -1;
    const pm = passMapOf(w, level_id, 0) orelse return -2;
    // radius 0 tests the cell itself and nothing around it.
    return if (pf.grid.nearestPassable(pm, x, y, 0) != null) 1 else 0;
}

export fn d2pf_line_of_sight(world: ?*World, level_id: i32, from_x: i32, from_y: i32, to_x: i32, to_y: i32, mask: u16) i32 {
    const w = world orelse return -1;
    const pm = passMapOf(w, level_id, mask) orelse return -2;
    return if (pf.grid.hasLineOfSight(pm, .{ .x = from_x, .y = from_y }, .{ .x = to_x, .y = to_y })) 1 else 0;
}

export fn d2pf_nearest_passable(world: ?*World, level_id: i32, x: i32, y: i32, radius: i32, out_x: ?*i32, out_y: ?*i32) i32 {
    const w = world orelse return -1;
    const pm = passMapOf(w, level_id, 0) orelse return -2;
    const p = pf.grid.nearestPassable(pm, x, y, radius) orelse return 0;
    if (out_x) |px| px.* = p.x;
    if (out_y) |py| py.* = p.y;
    return 1;
}

export fn d2pf_abi_version() u32 {
    return 1;
}
