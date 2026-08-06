//! Routing: from anywhere to anywhere across a loaded `d2-world`.
//!
//! The world says what the map IS; this says how to get across it. A `Router` borrows a
//! `world.World`, keeps the search caches for the levels it touches (see nav.zig), and answers one
//! question: give me the moves.
//!
//! Three things it gets right that a generic grid A* does not — see lib.zig.

const std = @import("std");
const wd = @import("d2-world");
const drlg = @import("d2-drlg");
const collision = @import("d2-core").collision;

const grid = @import("grid.zig");
const nav_mod = @import("nav.zig");
const astar = @import("astar.zig");
const teleport = @import("teleport.zig");

pub const World = wd.World;
pub const Level = wd.Level;
pub const Exit = wd.Exit;
pub const Door = wd.Door;
pub const Point = wd.Point;
pub const Nav = nav_mod.Nav;
const rooms_mod = wd.rooms;
const level_mod = wd.level;
const portals = wd.portals;

pub const Pos = struct {
    level: i32,
    x: i32,
    y: i32,
};

pub const Move = struct {
    x: i32,
    y: i32,
    kind: Kind,

    pub const Kind = enum {
        walk,
        teleport,
        /// Arrived by stepping on a teleport pad. `x`/`y` is where you COME OUT; the previous move
        /// is the pad you stepped on. See `level.Pad`.
        pad,
    };
};

/// A door a route passes: which leg, which waypoint it is nearest, and the door itself.
pub const RouteDoor = struct {
    leg: usize,
    move: usize,
    door: Door,
};

/// A chosen way out of a level: which link, and the reachable subtile that stands for it.
pub const Crossing = struct {
    exit: Exit,
    at: Point,
};

/// A single teleport cast that crosses a level boundary: where you cast from, and where you land
/// on the other side. Both in their own level's local subtiles.
pub const LevelCast = struct {
    at: Point,
    land: Point,
};

/// One level's worth of a route.
///
/// `moves` starts where you enter the level and ends where you leave it; `exit` says how you leave,
/// and is null on the last leg. A transition therefore always runs from this leg's LAST move to the
/// next leg's FIRST move — true for a staircase, a border and a teleport cast alike — so a consumer
/// never has to special-case where the far side is.
pub const Leg = struct {
    level: i32,
    moves: []Move,
    exit: ?Exit,
};

pub const Route = struct {
    alloc: std.mem.Allocator,
    legs: []Leg,

    pub fn deinit(self: *Route) void {
        for (self.legs) |l| self.alloc.free(l.moves);
        self.alloc.free(self.legs);
        self.* = undefined;
    }

    /// Total moves across every leg — a cheap way to compare two routes.
    pub fn moveCount(self: *const Route) usize {
        var n: usize = 0;
        for (self.legs) |l| n += l.moves.len;
        return n;
    }
};

pub const Options = struct {
    /// Movement collision model. The default is what a walking player uses; hand it
    /// `Colmask.monster_path` for a monster or `Colmask.missile_flight` to trace a projectile.
    mask: u16 = collision.Colmask.player_path,
    /// Teleport instead of walking wherever the level permits it. Levels that forbid teleport
    /// (Levels.txt Teleport = 0) fall back to walking automatically.
    teleport: bool = false,
    /// Cross a level boundary with a single teleport cast where the engine allows one (an actual
    /// cross-level near-room link, and both cells inside the cast gate). Requires `teleport`.
    ///
    /// Off by default because it depends on the destination room being LOADED server-side: the
    /// runtime adjacent list is activation-filtered (`GetRealRoomsNearCount` 0x66bd00), so a
    /// planned cast into a room the server has not allocated silently does nothing. Turn it on
    /// when the whole act is resident — which is the normal case for a server that eager-loads.
    teleport_across_levels: bool = false,
    /// Maximum CHEBYSHEV cast distance in subtiles (`max(|dx|,|dy|)`), the metric the packet
    /// handler's anti-exploit gate `CheckIfCoordsAreInRange` (0x548ef0) applies with nRange = 0x32.
    /// Defaults to that 50; lower it for margin against server/client position lag. Null drops the
    /// distance gate and leaves only the adjacent-room rule. See teleport.zig.
    teleport_max_cast: ?i32 = teleport.ENGINE_MAX_CAST,
    /// Shape of the cast limit. `.chebyshev` is the engine's own per-axis test; `.euclidean` models
    /// the radial cap conventional bots apply, which is strictly more conservative.
    teleport_metric: teleport.Metric = .chebyshev,
    /// Accept a passable cell this far from a blocked start or goal. Kept tight: the caller named
    /// a specific spot, so wandering far from it is not helpful.
    snap_radius: i32 = 8,
    /// The same, for a level-transition tile. Deliberately much larger, because map generation
    /// reports a warp adjacency at its ROOM'S CENTRE rather than on the doorway subtile itself
    /// (`collectLevelAdjacents`), and a room centre is frequently solid wall. One standard room is
    /// 40 subtiles across, so this reaches the doorway from anywhere inside the room.
    exit_snap_radius: i32 = 48,
    /// Collapse straight runs into waypoints.
    compress: bool = true,
    /// Cap on the distance between consecutive emitted waypoints, Chebyshev. Anything past the
    /// engine's command gate is refused by the packet handler and desyncs the client; the default
    /// sits under it with margin, because the gate is measured from the server's lagging view of
    /// where you are. See `grid.SAFE_COMMAND_STEP`.
    max_step: ?i32 = grid.SAFE_COMMAND_STEP,
    /// Keep walked paths off the walls. Walking only — teleport lands where it is aimed, so it has
    /// nothing to snag on. See `astar.WallAversion`.
    wall_aversion: astar.WallAversion = .{},
    max_nodes: u32 = 4_000_000,
};

pub const Error = error{
    UnknownLevel,
    NoLevelRoute,
} || astar.Error || teleport.Error;


/// Routing over a world, plus the caches that make it fast. Borrows the world; does not own it,
/// because a running game owns its world and merely asks this for directions.
pub const Router = struct {
    alloc: std.mem.Allocator,
    world: *World,
    /// Per-level search caches, created on first use. By pointer: a `PassMap` handed out of one
    /// stays valid while other levels are loaded.
    navs: std.AutoHashMapUnmanaged(i32, *Nav) = .empty,
    /// Reused A* scratch, sized to the largest level searched.
    pather: astar.Pather,

    pub fn init(alloc: std.mem.Allocator, world: *World) Router {
        return .{ .alloc = alloc, .world = world, .pather = astar.Pather.init(alloc) };
    }

    pub fn deinit(self: *Router) void {
        var it = self.navs.valueIterator();
        while (it.next()) |n| {
            n.*.deinit();
            self.alloc.destroy(n.*);
        }
        self.navs.deinit(self.alloc);
        self.pather.deinit();
        self.* = undefined;
    }

    /// The search caches for a level, created on first use.
    pub fn nav(self: *Router, id: i32) !*Nav {
        if (self.navs.get(id)) |n| return n;
        const lv = self.world.level(id) orelse return error.UnknownLevel;
        return self.navFor(lv);
    }

    pub fn navFor(self: *Router, lv: *Level) !*Nav {
        if (self.navs.get(lv.id)) |n| return n;
        const n = try self.alloc.create(Nav);
        errdefer self.alloc.destroy(n);
        n.* = Nav.init(self.alloc, lv);
        try self.navs.put(self.alloc, lv.id, n);
        return n;
    }

    pub fn level(self: *Router, id: i32) ?*Level {
        return self.world.level(id);
    }

    pub fn levelRoute(self: *Router, from: i32, to: i32, out: *std.ArrayListUnmanaged(i32)) !void {
        return self.world.levelRoute(from, to, out);
    }

    pub fn doorsAlong(self: *Router, r: *const Route, radius: i32, out: *std.ArrayListUnmanaged(RouteDoor)) !void {
        var scratch: std.ArrayListUnmanaged(Door) = .empty;
        defer scratch.deinit(self.alloc);
        for (r.legs, 0..) |leg, li| {
            scratch.clearRetainingCapacity();
            self.world.doorsOn(leg.level, &scratch) catch continue;
            for (scratch.items) |d| {
                var best: ?usize = null;
                var best_d: i64 = std.math.maxInt(i64);
                for (leg.moves, 0..) |m, mi| {
                    const dx: i64 = m.x - d.x;
                    const dy: i64 = m.y - d.y;
                    const dist = dx * dx + dy * dy;
                    if (dist < best_d) {
                        best_d = dist;
                        best = mi;
                    }
                }
                const mi = best orelse continue;
                if (best_d > @as(i64, radius) * @as(i64, radius)) continue;
                try out.append(self.alloc, .{ .leg = li, .move = mi, .door = d });
            }
        }
    }

    /// Every level reachable in one step from `id`, including the runtime portals map generation
    /// cannot see. The portal entries carry no coordinates — quest code decides where the portal
    /// stands — so their `x`/`y` are -1 and a caller that needs the exact tile locates the portal
    /// object itself.
    pub fn route(self: *Router, from: Pos, to: Pos, opts: Options) Error!Route {
        var chain: std.ArrayListUnmanaged(i32) = .empty;
        defer chain.deinit(self.alloc);
        try self.levelRoute(from.level, to.level, &chain);

        var legs: std.ArrayListUnmanaged(Leg) = .empty;
        errdefer {
            for (legs.items) |l| self.alloc.free(l.moves);
            legs.deinit(self.alloc);
        }

        var entry = Point{ .x = from.x, .y = from.y };
        for (chain.items, 0..) |level_id, i| {
            const lv = self.level(level_id) orelse return error.UnknownLevel;
            const last = i + 1 == chain.items.len;

            // The two ends of a leg are different kinds of thing and get different snaps: a
            // position the caller named is exact, a level-transition tile is approximate.
            const snap_from: i32 = if (i == 0) opts.snap_radius else opts.exit_snap_radius;
            const snap_to: i32 = if (last) opts.snap_radius else opts.exit_snap_radius;

            var exit: ?Exit = null;
            // Set when this leg leaves by casting into the next level rather than walking out.
            var cast_arrival: ?Point = null;
            var moves: std.ArrayListUnmanaged(Move) = .empty;
            errdefer moves.deinit(self.alloc);

            if (last) {
                try self.pathWithin(lv, entry, .{ .x = to.x, .y = to.y }, opts, snap_from, snap_to, &moves);
            } else {
                const next = chain.items[i + 1];

                // Two ways out can exist: walk to the staircase/border, or cast straight across
                // where the engine permits it. Casting is usually the shorter one — it skips the
                // whole walk to the exit — but not always: the link room may be further away than
                // the exit is. So build BOTH legs and keep the cheaper, rather than assuming.
                const walk_out: ?Crossing = try self.chooseExit(lv, next, entry, opts);
                const cast_out: ?LevelCast = if (opts.teleport and opts.teleport_across_levels)
                    if (self.level(next)) |nlv| try self.crossLevelCast(lv, nlv, opts) else null
                else
                    null;

                if (walk_out == null and cast_out == null) {
                    // A portal edge: quest code places it, so there is no tile to walk to. End the
                    // leg where we stand and let the caller drive the portal.
                    exit = .{ .to_level = next, .x = -1, .y = -1, .kind = .portal };
                    try self.pathWithin(lv, entry, entry, opts, snap_from, snap_to, &moves);
                } else {
                    if (walk_out) |wc| {
                        try self.pathWithin(lv, entry, wc.at, opts, snap_from, snap_to, &moves);
                        exit = wc.exit;
                    }
                    if (cast_out) |cc| skip: {
                        // Searching the alternative costs as much as the leg we already have, so
                        // first ask whether it could possibly win. In teleport mode a leg's cost is
                        // its cast count, and no route to `cc.at` can use fewer than
                        // ceil(distance / max_cast) of them — an admissible bound, so if even that
                        // plus the boundary cast cannot beat what we have, the search is pointless.
                        if (walk_out != null and opts.teleport) {
                            if (opts.teleport_max_cast) |m| {
                                const d: i32 = @intCast(opts.teleport_metric.distance(entry.x, entry.y, cc.at.x, cc.at.y));
                                const floor_casts = std.math.divCeil(i32, d, m) catch 0;
                                // +1 start move, +1 for the boundary cast itself.
                                if (floor_casts + 2 > @as(i32, @intCast(moves.items.len))) break :skip;
                            }
                        }

                        var alt: std.ArrayListUnmanaged(Move) = .empty;
                        defer alt.deinit(self.alloc);
                        try self.pathWithin(lv, entry, cc.at, opts, snap_from, snap_to, &alt);
                        // +1 for the cast itself, which the leg's moves do not contain.
                        if (walk_out == null or alt.items.len + 1 <= moves.items.len) {
                            moves.clearRetainingCapacity();
                            try moves.appendSlice(self.alloc, alt.items);
                            exit = .{ .to_level = next, .x = cc.at.x, .y = cc.at.y, .kind = .teleport };
                            cast_arrival = cc.land;
                        }
                    }
                }
            }

            const leg_end: Point = if (moves.items.len != 0)
                .{ .x = moves.items[moves.items.len - 1].x, .y = moves.items[moves.items.len - 1].y }
            else
                entry;

            try legs.append(self.alloc, .{
                .level = level_id,
                .moves = try moves.toOwnedSlice(self.alloc),
                .exit = exit,
            });

            // Entering the next level, we arrive at its own side of the link.
            if (!last) {
                const next = chain.items[i + 1];
                entry = cast_arrival orelse try self.arrivalOn(next, lv, leg_end, exit, opts);
            }
        }

        return .{ .alloc = self.alloc, .legs = try legs.toOwnedSlice(self.alloc) };
    }

    /// Can we leave `from` for `to` with a single teleport cast, and if so between which cells?
    ///
    /// Both of the engine's gates have to hold, and the interesting part is that they pull in
    /// opposite directions:
    ///
    ///   * TOPOLOGY says yes only where a cross-level near-room link exists. Those come from
    ///     `DRLGROOMEX_LinkNearRoomsByVis` (0x66c220) following a vis slot, so they connect a room
    ///     to a room of the level its warp leads to — regardless of where that level sits.
    ///   * DISTANCE says yes only within 50 subtiles, Chebyshev. Levels of an act share one world
    ///     frame, and a warp destination is usually placed far away in it, so most linked pairs
    ///     are thousands of subtiles apart and fail here.
    ///
    /// The two therefore agree only where a linked pair also happens to be physically adjacent —
    /// which is precisely the case worth taking, and the check has to run in WORLD coordinates
    /// because the two cells live in different level-local frames.
    ///
    /// Picks the pair with the shortest cast among all candidate links.
    pub fn crossLevelCast(self: *Router, from: *Level, to: *Level, opts: Options) !?LevelCast {
        const max_cast = opts.teleport_max_cast orelse return null;
        // The Levels.txt rule that applies is the CASTER'S — `Skills_SrvDoFunc_027_Teleport` reads
        // it from `GetRoom(pUnit)`, the room you are standing in — so `from` decides both whether
        // the cast happens at all and what extra mask the DESTINATION is tested with. The
        // destination level's own rule is irrelevant to this cast.
        if (from.teleport == .forbidden) return null;

        const from_pm = try (try self.navFor(from)).passMap(opts.mask);
        const to_pm = try (try self.navFor(to)).passMap(from.teleport.destinationMask(opts.mask));

        var best: ?LevelCast = null;
        var best_cost: i32 = std.math.maxInt(i32);

        for (from.links) |link| {
            if (link.to_level != to.id) continue;
            if (link.from_room >= from.rooms.rooms.len or link.to_room >= to.rooms.rooms.len) continue;
            const src_box = from.rooms.rooms[link.from_room];
            const dst_box = to.rooms.rooms[link.to_room];

            // Cheap exact prune FIRST. Snapping a candidate costs two ring searches out to
            // `exit_snap_radius`, and a level can carry hundreds of links of which almost none are
            // physically close — a warp destination is usually placed far away in the shared world
            // frame. The closest any cell of one room can be to any cell of the other is a
            // subtraction on the boxes, so reject on that before touching the grid.
            if (boxGap(from, src_box, to, dst_box) > max_cast) continue;

            // Aim each room at the other, in world coordinates, then snap to real ground.
            const src_c = from.toWorld(roomCentre(src_box));
            const dst_c = to.toWorld(roomCentre(dst_box));
            const at = grid.nearestPassable(from_pm, from.fromWorld(dst_c).x, from.fromWorld(dst_c).y, opts.exit_snap_radius) orelse continue;
            const land = grid.nearestPassable(to_pm, to.fromWorld(src_c).x, to.fromWorld(src_c).y, opts.exit_snap_radius) orelse continue;

            // BOTH ends must really be in the linked rooms. The engine's rule is that the
            // destination lies in the CASTER'S room or one adjacent to it, so the link only
            // authorises this cast when we are standing in `from_room` and land in `to_room`;
            // snapping can easily have pulled either cell into a neighbouring room instead.
            if (from.rooms.atSubtile(at.x, at.y) != @as(?u16, @intCast(link.from_room))) continue;
            if (to.rooms.atSubtile(land.x, land.y) != @as(?u16, @intCast(link.to_room))) continue;

            const a = from.toWorld(at);
            const b = to.toWorld(land);
            if (!opts.teleport_metric.within(a.x, a.y, b.x, b.y, max_cast)) continue;
            const cost: i32 = @intCast(opts.teleport_metric.distance(a.x, a.y, b.x, b.y));
            if (cost < best_cost) {
                best_cost = cost;
                best = .{ .at = at, .land = land };
            }
        }
        return best;
    }

    /// The crossing to take out of `lv` towards `dest`, and the reachable subtile that stands for
    /// it.
    ///
    /// A level typically offers SEVERAL ways into its neighbour — one seam bridge per bordering
    /// room along an outdoor border — and map generation reports each at its room's CENTRE rather
    /// than on the crossable ground itself. A room centre is often solid, and on a border room it
    /// can be void. So taking the first candidate and hoping it is walkable fails on perfectly
    /// ordinary routes.
    ///
    /// Instead: snap every candidate to real ground, discard the ones that have none nearby, and
    /// among the rest prefer one in the same connected region as where we are standing (a crossing
    /// on the far side of a wall is no use), then the closest. Warps still win over seams — a
    /// staircase is a specific doorway, a seam is a wide border.
    fn chooseExit(self: *Router, lv: *Level, dest: i32, from: Point, opts: Options) !?Crossing {
        const pm = try (try self.navFor(lv)).passMap(opts.mask);
        const comp = try pm.components(self.alloc);
        const from_comp: u32 = if (pm.passable(from.x, from.y)) comp[pm.index(from.x, from.y)] else 0;

        var best: ?Crossing = null;
        var best_rank: u32 = std.math.maxInt(u32);
        var best_dist: i64 = std.math.maxInt(i64);

        for (lv.exits) |e| {
            if (e.to_level != dest or e.x < 0) continue;
            const at = grid.nearestPassable(pm, e.x, e.y, opts.exit_snap_radius) orelse continue;
            const same_region = from_comp != 0 and comp[pm.index(at.x, at.y)] == from_comp;
            // 0 = reachable warp, 1 = reachable seam, 2 = warp we may not reach, 3 = seam likewise.
            const rank: u32 = (@as(u32, if (same_region) 0 else 2)) + @intFromBool(e.kind != .warp);
            const dx: i64 = at.x - from.x;
            const dy: i64 = at.y - from.y;
            const dist = dx * dx + dy * dy;
            if (rank < best_rank or (rank == best_rank and dist < best_dist)) {
                best_rank = rank;
                best_dist = dist;
                best = .{ .exit = e, .at = at };
            }
        }
        return best;
    }

    /// Where you stand after crossing from `from_lv` into level `next`, in `next`'s local frame.
    ///
    /// A SEAM and a WARP need opposite answers, and getting them the wrong way round produces a
    /// leg that starts on the far side of a wall from where it needs to go.
    ///
    /// A seam is a shared border, not a doorway: you come out exactly where you walked in. Levels
    /// of one act live in a single world frame, so translating the departure point through the two
    /// origins gives that spot precisely.
    ///
    /// A warp is a doorway with a distinct tile at each end, and the far tile is only known to the
    /// far level — so ask it, via the same reachability-aware pick used on the way out.
    ///
    /// Anything else (a quest portal, whose position quest code decides) has no knowable tile;
    /// the level's centre at least gives the next leg somewhere real to start.
    fn arrivalOn(
        self: *Router,
        next: i32,
        from_lv: *const Level,
        leaving_at: Point,
        via: ?Exit,
        opts: Options,
    ) Error!Point {
        const nlv = self.level(next) orelse return error.UnknownLevel;
        const pm = try (try self.navFor(nlv)).passMap(opts.mask);

        const translated = nlv.fromWorld(from_lv.toWorld(leaving_at));
        if (via != null and via.?.kind == .seam and nlv.inBounds(translated.x, translated.y)) {
            if (grid.nearestPassable(pm, translated.x, translated.y, opts.exit_snap_radius)) |p| return p;
        }

        const anchor: Point = if (nlv.inBounds(translated.x, translated.y))
            translated
        else
            .{ .x = @divTrunc(nlv.w, 2), .y = @divTrunc(nlv.h, 2) };

        if (try self.chooseExit(nlv, from_lv.id, anchor, opts)) |back| return back.at;
        if (grid.nearestPassable(pm, anchor.x, anchor.y, @max(nlv.w, nlv.h))) |p| return p;
        return anchor;
    }

    /// A path inside one level, walking or teleporting per `opts`.
    fn pathWithin(
        self: *Router,
        lv: *Level,
        from: Point,
        to: Point,
        opts: Options,
        snap_from: i32,
        snap_to: i32,
        out: *std.ArrayListUnmanaged(Move),
    ) Error!void {
        if (opts.teleport and lv.teleport != .forbidden) {
            var hops: std.ArrayListUnmanaged(Point) = .empty;
            defer hops.deinit(self.alloc);
            teleport.find(self.alloc, try self.navFor(lv), from.x, from.y, to.x, to.y, .{
                .max_cast = opts.teleport_max_cast,
                .metric = opts.teleport_metric,
                .landing_mask = opts.mask,
                .snap_radius = snap_from,
                .goal_snap_radius = snap_to,
            }, &hops) catch |err| switch (err) {
                // Teleport cannot always finish the job — a goal in a room chain the caster cannot
                // reach, or a level that refuses the skill. Walking is always the fallback.
                error.Forbidden, error.Unreachable, error.OutsideAnyRoom, error.NodeLimit => {
                    return self.walkWithin(lv, from, to, opts, snap_from, snap_to, out);
                },
                else => return err,
            };
            for (hops.items, 0..) |h, i| {
                try out.append(self.alloc, .{ .x = h.x, .y = h.y, .kind = if (i == 0) .walk else .teleport });
            }
            return;
        }
        return self.walkWithin(lv, from, to, opts, snap_from, snap_to, out);
    }

    /// Pair this level's teleport pads the way `OBJOP_RevealAutomapArea` (0x581bf0) does: for each
    /// pad, another object of the SAME class id, preferring one in its own room and otherwise
    /// taking one in an adjacent room.
    ///
    /// The engine walks a room's live unit list and takes the first match, an order we cannot
    /// reproduce from preset data. It does not matter: every (room, class id) group in the Arcane
    /// Sanctuary holds exactly two pads across every seed tested, so there is never a choice to
    /// make. If that ever stops holding, this picks the first in DS1 order and the route may take
    /// a different pad than the server would.
    fn padRoute(
        self: *Router,
        lv: *Level,
        pm: *grid.PassMap,
        from: Point,
        to: Point,
        opts: Options,
        snap_from: i32,
        snap_to: i32,
        out: *std.ArrayListUnmanaged(Move),
    ) Error!bool {
        const comp = try pm.components(self.alloc);
        const start = grid.nearestPassable(pm, from.x, from.y, snap_from) orelse return false;
        const goal = grid.nearestPassable(pm, to.x, to.y, snap_to) orelse return false;
        const start_c = comp[pm.index(start.x, start.y)];
        const goal_c = comp[pm.index(goal.x, goal.y)];
        if (start_c == goal_c or start_c == grid.PassMap.NO_COMPONENT) return false;

        // Region each end of each pad lands in. A pad whose either end has no reachable ground
        // nearby is unusable, and is dropped rather than left to fail mid-route.
        const Hop = struct { pad: level_mod.Pad, from_c: u32, to_c: u32, land: Point };
        var hops: std.ArrayListUnmanaged(Hop) = .empty;
        defer hops.deinit(self.alloc);
        for (lv.pads) |pad| {
            const a = grid.nearestPassable(pm, pad.at.x, pad.at.y, 8) orelse continue;
            const b = grid.nearestPassable(pm, pad.to.x, pad.to.y, 8) orelse continue;
            try hops.append(self.alloc, .{
                .pad = pad,
                .from_c = comp[pm.index(a.x, a.y)],
                .to_c = comp[pm.index(b.x, b.y)],
                .land = b,
            });
        }

        // Breadth-first over regions; prev[i] is the hop that first reached hops[i].to_c.
        var queue: std.ArrayListUnmanaged(u32) = .empty;
        defer queue.deinit(self.alloc);
        var seen: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer seen.deinit(self.alloc);
        try queue.append(self.alloc, start_c);
        try seen.put(self.alloc, start_c, std.math.maxInt(usize));

        var head: usize = 0;
        var reached: ?usize = null;
        while (head < queue.items.len and reached == null) : (head += 1) {
            const cur = queue.items[head];
            for (hops.items, 0..) |h, hi| {
                if (h.from_c != cur or seen.contains(h.to_c)) continue;
                try seen.put(self.alloc, h.to_c, hi);
                if (h.to_c == goal_c) {
                    reached = hi;
                    break;
                }
                try queue.append(self.alloc, h.to_c);
            }
        }
        const last = reached orelse return false;

        // Unwind to a forward-ordered chain of hops.
        var chain: std.ArrayListUnmanaged(usize) = .empty;
        defer chain.deinit(self.alloc);
        var walk_hi = last;
        while (true) {
            try chain.append(self.alloc, walk_hi);
            const prev = seen.get(hops.items[walk_hi].from_c) orelse break;
            if (prev == std.math.maxInt(usize)) break;
            walk_hi = prev;
        }
        std.mem.reverse(usize, chain.items);

        // Materialise: ground to the pad, the hop itself, ground on from where it drops you.
        var cur_from = from;
        var cur_snap = snap_from;
        for (chain.items) |hi| {
            const h = hops.items[hi];
            try self.walkPlain(lv, pm, cur_from, h.pad.at, opts, cur_snap, 8, out);
            try out.append(self.alloc, .{ .x = h.land.x, .y = h.land.y, .kind = .pad });
            cur_from = h.land;
            cur_snap = 0;
        }
        try self.walkPlain(lv, pm, cur_from, to, opts, cur_snap, snap_to, out);
        return true;
    }

    fn walkPlain(
        self: *Router,
        lv: *Level,
        pm: *grid.PassMap,
        from: Point,
        to: Point,
        opts: Options,
        snap_from: i32,
        snap_to: i32,
        out: *std.ArrayListUnmanaged(Move),
    ) Error!void {
        _ = lv;
        var pts: std.ArrayListUnmanaged(Point) = .empty;
        defer pts.deinit(self.alloc);
        try self.pather.find(pm, from.x, from.y, to.x, to.y, .{
            .snap_radius = snap_from,
            .goal_snap_radius = snap_to,
            .compress = opts.compress,
            .max_step = opts.max_step,
            .wall_aversion = opts.wall_aversion,
            .max_nodes = opts.max_nodes,
        }, &pts);
        for (pts.items) |p| try out.append(self.alloc, .{ .x = p.x, .y = p.y, .kind = .walk });
    }

    fn walkWithin(
        self: *Router,
        lv: *Level,
        from: Point,
        to: Point,
        opts: Options,
        snap_from: i32,
        snap_to: i32,
        out: *std.ArrayListUnmanaged(Move),
    ) Error!void {
        const pm = try (try self.navFor(lv)).passMap(opts.mask);
        if (lv.pads.len != 0) {
            const mark = out.items.len;
            if (self.padRoute(lv, pm, from, to, opts, snap_from, snap_to, out)) |used| {
                if (used) return;
            } else |e| {
                out.shrinkRetainingCapacity(mark);
                return e;
            }
            out.shrinkRetainingCapacity(mark);
        }
        try self.walkPlain(lv, pm, from, to, opts, snap_from, snap_to, out);
    }
};

fn boxGap(la: *const Level, a: rooms_mod.Room, lb: *const Level, b: rooms_mod.Room) i32 {
    const S = grid.SUBTILES_PER_TILE;
    const ax0 = (la.origin_x + a.x) * S;
    const ay0 = (la.origin_y + a.y) * S;
    const ax1 = ax0 + a.w * S;
    const ay1 = ay0 + a.h * S;
    const bx0 = (lb.origin_x + b.x) * S;
    const by0 = (lb.origin_y + b.y) * S;
    const bx1 = bx0 + b.w * S;
    const by1 = by0 + b.h * S;

    const gap_x = @max(@as(i32, 0), @max(ax0 - bx1, bx0 - ax1));
    const gap_y = @max(@as(i32, 0), @max(ay0 - by1, by0 - ay1));
    return @max(gap_x, gap_y);
}

fn roomCentre(box: rooms_mod.Room) Point {
    return .{
        .x = (box.x + @divTrunc(box.w, 2)) * grid.SUBTILES_PER_TILE,
        .y = (box.y + @divTrunc(box.h, 2)) * grid.SUBTILES_PER_TILE,
    };
}

/// The bridge tile on `lv` that leads to `dest`, preferring a warp door over a seam: a warp is a
/// real doorway you step into, a seam is a wide border you can cross anywhere, so the warp is the
/// more precise target when both exist. Coordinates only — no passability check; `chooseExit` is
/// the one that picks a crossing you can actually reach.
fn pickExit(lv: *const Level, dest: i32) ?Exit {
    var seam: ?Exit = null;
    for (lv.exits) |e| {
        if (e.to_level != dest) continue;
        if (e.kind == .warp) return e;
        if (seam == null) seam = e;
    }
    return seam;
}
