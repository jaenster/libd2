//! The loaded world: whole acts of levels, their collision, their rooms, and the graph that
//! connects them — built once, queried many times.
//!
//! "Already loaded" is the point. Generating an act is the expensive part of D2 map work (roughly
//! a second); searching it afterwards is microseconds. So `loadAct` pays that cost once, keeps
//! every level's grid and room index resident, and every later query is pure search. Loading act 1
//! and act 2 into the same `World` also means a route from the Rogue Encampment to the Arcane
//! Sanctuary is a single call — the level graph spans whatever is loaded.
//!
//! One act generation supplies everything: `generateActFull` returns each level's rooms, its warp
//! and seam adjacents, and its composited collision in one pass, so nothing here regenerates.

const std = @import("std");
const drlg = @import("d2-drlg");
const d2data = @import("d2-data");
const collision = @import("d2-core").collision;

const grid = @import("grid.zig");
const rooms_mod = @import("rooms.zig");
const level_mod = @import("level.zig");
const astar = @import("astar.zig");
const teleport = @import("teleport.zig");
const portals = @import("portals.zig");

pub const Level = level_mod.Level;
pub const Exit = level_mod.Exit;
pub const Point = grid.Point;

/// A position: a level plus LEVEL-LOCAL subtile coordinates. Level-local rather than world coords
/// because only levels of the same act share a world frame — this pair is unambiguous everywhere.
/// `Level.toWorld` converts when a caller needs what a game client would report.
pub const Pos = struct {
    level: i32,
    x: i32,
    y: i32,
};

pub const Move = struct {
    x: i32,
    y: i32,
    kind: Kind,

    pub const Kind = enum { walk, teleport };
};

/// A chosen way out of a level: which link, and the reachable subtile that stands for it.
pub const Crossing = struct {
    exit: Exit,
    at: Point,
};

/// One level's worth of a route. `exit` is how you leave for the next leg; null on the last.
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
    /// Maximum CHEBYSHEV cast distance in subtiles (`max(|dx|,|dy|)`), the metric the packet
    /// handler's anti-exploit gate `CheckIfCoordsAreInRange` (0x548ef0) applies with nRange = 0x32.
    /// Defaults to that 50; lower it for margin against server/client position lag. Null drops the
    /// distance gate and leaves only the adjacent-room rule. See teleport.zig.
    teleport_max_cast: ?i32 = teleport.ENGINE_MAX_CAST,
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
    max_nodes: u32 = 4_000_000,
};

pub const Error = error{
    UnknownLevel,
    NoLevelRoute,
} || astar.Error || teleport.Error;

pub const World = struct {
    alloc: std.mem.Allocator,
    seed: u32,
    difficulty: drlg.Difficulty,
    levels: std.ArrayListUnmanaged(Level) = .empty,
    /// Level id -> index into `levels`.
    by_id: std.AutoHashMapUnmanaged(i32, u32) = .empty,
    /// Reused A* scratch, sized to the largest level loaded.
    pather: astar.Pather,
    /// Levels.txt `Teleport` by level id, parsed once at first load.
    teleport_rule: []level_mod.TeleportRule = &.{},

    pub fn init(alloc: std.mem.Allocator, seed: u32, difficulty: drlg.Difficulty) World {
        return .{
            .alloc = alloc,
            .seed = seed,
            .difficulty = difficulty,
            .pather = astar.Pather.init(alloc),
        };
    }

    pub fn deinit(self: *World) void {
        for (self.levels.items) |*l| l.deinit();
        self.levels.deinit(self.alloc);
        self.by_id.deinit(self.alloc);
        self.pather.deinit();
        if (self.teleport_rule.len != 0) self.alloc.free(self.teleport_rule);
        self.* = undefined;
    }

    pub fn level(self: *World, id: i32) ?*Level {
        const idx = self.by_id.get(id) orelse return null;
        return &self.levels.items[idx];
    }

    /// Generate and keep one act (0-based). Safe to call for several acts on the same `World`;
    /// the level graph then spans all of them, so cross-act portals route in one call.
    pub fn loadAct(self: *World, ctx: *drlg.Ctx, act_no: i32) !void {
        if (self.teleport_rule.len == 0) self.teleport_rule = try parseTeleportColumn(self.alloc);

        var full = try drlg.generateActFull(ctx, self.alloc, act_no, self.seed, self.difficulty, null, false);
        defer full.deinit(self.alloc);

        for (full.levels) |lf| {
            if (lf.coll_w <= 0 or lf.coll_h <= 0 or lf.coll_deflated.len == 0) continue;
            try self.addLevel(ctx, lf);
        }
    }

    fn addLevel(self: *World, ctx: *drlg.Ctx, lf: drlg.LevelFull) !void {
        _ = ctx;
        const w = lf.coll_w;
        const h = lf.coll_h;
        const cell_count: usize = @intCast(w * h);

        // generateActFull holds each level's CollMap deflated so a whole act does not sit in
        // memory as raw u16 grids; a pathfinder wants exactly that raw grid, so inflate it once.
        const raw = try drlg.inflateZlib(self.alloc, lf.coll_deflated, cell_count * @sizeOf(u16));
        defer self.alloc.free(raw);
        const cells = try self.alloc.alloc(u16, cell_count);
        errdefer self.alloc.free(cells);
        for (cells, 0..) |*c, i| c.* = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);

        // Room boxes come out of drlg in WORLD tiles; rebase them onto this level's own frame so
        // rooms, collision and positions all agree.
        var boxes = try self.alloc.alloc(rooms_mod.Room, lf.meta.rooms.len);
        defer self.alloc.free(boxes);
        for (lf.meta.rooms, 0..) |r, i| boxes[i] = .{
            .x = r.x - lf.meta.origin_x,
            .y = r.y - lf.meta.origin_y,
            .w = r.w,
            .h = r.h,
        };
        var room_set = try rooms_mod.build(
            self.alloc,
            boxes,
            @divTrunc(w, grid.SUBTILES_PER_TILE),
            @divTrunc(h, grid.SUBTILES_PER_TILE),
        );
        errdefer room_set.deinit(self.alloc);

        const exits = try self.alloc.alloc(Exit, lf.adjacents.len);
        errdefer self.alloc.free(exits);
        for (lf.adjacents, 0..) |a, i| exits[i] = .{
            .to_level = a.dest_level_id,
            .x = a.x,
            .y = a.y,
            .kind = switch (a.kind) {
                .warp => .warp,
                .seam => .seam,
            },
        };

        const id = lf.meta.level_id;
        try self.levels.append(self.alloc, .{
            .id = id,
            .origin_x = lf.meta.origin_x,
            .origin_y = lf.meta.origin_y,
            .w = w,
            .h = h,
            .cells = cells,
            .rooms = room_set,
            .exits = exits,
            .teleport = self.teleportRuleFor(id),
            .alloc = self.alloc,
        });
        try self.by_id.put(self.alloc, id, @intCast(self.levels.items.len - 1));
    }

    fn teleportRuleFor(self: *const World, id: i32) level_mod.TeleportRule {
        if (id < 0 or @as(usize, @intCast(id)) >= self.teleport_rule.len) return .allowed;
        return self.teleport_rule[@intCast(id)];
    }

    /// Every level reachable in one step from `id`, including the runtime portals map generation
    /// cannot see. The portal entries carry no coordinates — quest code decides where the portal
    /// stands — so their `x`/`y` are -1 and a caller that needs the exact tile locates the portal
    /// object itself.
    pub fn exitsOf(self: *World, id: i32, buf: *std.ArrayListUnmanaged(Exit)) !void {
        if (self.level(id)) |lv| try buf.appendSlice(self.alloc, lv.exits);
        for (portals.LINKS) |link| {
            if (link.from == id) {
                try buf.append(self.alloc, .{ .to_level = link.to, .x = -1, .y = -1, .kind = .portal });
            } else if (link.to == id and !link.one_way) {
                try buf.append(self.alloc, .{ .to_level = link.from, .x = -1, .y = -1, .kind = .portal });
            }
        }
    }

    /// The chain of levels from `from` to `to`, breadth-first over the level graph. Breadth-first
    /// on level COUNT (rather than weighted by in-level distance) because that is what actually
    /// costs a player time — every transition is a loading screen and a walk to a staircase, and
    /// the alternative routes through one extra area are essentially never worth it.
    pub fn levelRoute(self: *World, from: i32, to: i32, out: *std.ArrayListUnmanaged(i32)) !void {
        if (from == to) {
            try out.append(self.alloc, from);
            return;
        }
        var came: std.AutoHashMapUnmanaged(i32, i32) = .empty;
        defer came.deinit(self.alloc);
        var queue: std.ArrayListUnmanaged(i32) = .empty;
        defer queue.deinit(self.alloc);
        var scratch: std.ArrayListUnmanaged(Exit) = .empty;
        defer scratch.deinit(self.alloc);

        try came.put(self.alloc, from, from);
        try queue.append(self.alloc, from);
        var head: usize = 0;
        var found = false;
        while (head < queue.items.len and !found) : (head += 1) {
            const cur = queue.items[head];
            scratch.clearRetainingCapacity();
            try self.exitsOf(cur, &scratch);
            for (scratch.items) |e| {
                if (came.contains(e.to_level)) continue;
                try came.put(self.alloc, e.to_level, cur);
                if (e.to_level == to) {
                    found = true;
                    break;
                }
                try queue.append(self.alloc, e.to_level);
            }
        }
        if (!found) return error.NoLevelRoute;

        const first = out.items.len;
        var cur = to;
        while (cur != from) {
            try out.append(self.alloc, cur);
            cur = came.get(cur).?;
        }
        try out.append(self.alloc, from);
        std.mem.reverse(i32, out.items[first..]);
    }

    /// The whole thing: a route from `from` to `to`, across as many levels as it takes.
    pub fn route(self: *World, from: Pos, to: Pos, opts: Options) Error!Route {
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

            // Where this leg ends: the caller's goal on the final level, otherwise the tile that
            // leads to the next one.
            var exit: ?Exit = null;
            const target: Point = if (last) .{ .x = to.x, .y = to.y } else blk: {
                const next = chain.items[i + 1];
                const picked = try self.chooseExit(lv, next, entry, opts) orelse {
                    // A portal edge: quest code places it, so there is no tile to walk to. End the
                    // leg where we stand and let the caller drive the portal.
                    exit = .{ .to_level = next, .x = -1, .y = -1, .kind = .portal };
                    break :blk entry;
                };
                exit = picked.exit;
                break :blk picked.at;
            };

            var moves: std.ArrayListUnmanaged(Move) = .empty;
            errdefer moves.deinit(self.alloc);
            // The two ends of a leg are different kinds of thing and get different snaps: a
            // position the caller named is exact, a level-transition tile is approximate.
            const snap_from: i32 = if (i == 0) opts.snap_radius else opts.exit_snap_radius;
            const snap_to: i32 = if (last) opts.snap_radius else opts.exit_snap_radius;
            try self.pathWithin(lv, entry, target, opts, snap_from, snap_to, &moves);
            try legs.append(self.alloc, .{
                .level = level_id,
                .moves = try moves.toOwnedSlice(self.alloc),
                .exit = exit,
            });

            // Entering the next level, we arrive at its own side of the link.
            if (!last) {
                const next = chain.items[i + 1];
                entry = try self.arrivalOn(next, lv, target, exit, opts);
            }
        }

        return .{ .alloc = self.alloc, .legs = try legs.toOwnedSlice(self.alloc) };
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
    fn chooseExit(self: *World, lv: *Level, dest: i32, from: Point, opts: Options) !?Crossing {
        const pm = try lv.passMap(opts.mask);
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
        self: *World,
        next: i32,
        from_lv: *const Level,
        leaving_at: Point,
        via: ?Exit,
        opts: Options,
    ) Error!Point {
        const nlv = self.level(next) orelse return error.UnknownLevel;
        const pm = try nlv.passMap(opts.mask);

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
        self: *World,
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
            teleport.find(self.alloc, lv, from.x, from.y, to.x, to.y, .{
                .max_cast = opts.teleport_max_cast,
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

    fn walkWithin(
        self: *World,
        lv: *Level,
        from: Point,
        to: Point,
        opts: Options,
        snap_from: i32,
        snap_to: i32,
        out: *std.ArrayListUnmanaged(Move),
    ) Error!void {
        const pm = try lv.passMap(opts.mask);
        var pts: std.ArrayListUnmanaged(Point) = .empty;
        defer pts.deinit(self.alloc);
        try self.pather.find(pm, from.x, from.y, to.x, to.y, .{
            .snap_radius = snap_from,
            .goal_snap_radius = snap_to,
            .compress = opts.compress,
            .max_nodes = opts.max_nodes,
        }, &pts);
        for (pts.items) |p| try out.append(self.alloc, .{ .x = p.x, .y = p.y, .kind = .walk });
    }
};

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

/// Levels.txt `Teleport`, indexed by level id. Read at runtime (one pass over one embedded table)
/// rather than at comptime — it is a few microseconds once per World, and it keeps the build off
/// a 200 KB comptime string scan.
fn parseTeleportColumn(alloc: std.mem.Allocator) ![]level_mod.TeleportRule {
    const text = d2data.file("Levels");
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return error.InvalidTable;

    var id_col: ?usize = null;
    var tele_col: ?usize = null;
    {
        var cols = std.mem.splitScalar(u8, header, '\t');
        var i: usize = 0;
        while (cols.next()) |c| : (i += 1) {
            const name = std.mem.trim(u8, c, "\r");
            if (std.mem.eql(u8, name, "Id")) id_col = i;
            if (std.mem.eql(u8, name, "Teleport")) tele_col = i;
        }
    }
    const idc = id_col orelse return error.InvalidTable;
    const tc = tele_col orelse return error.InvalidTable;

    var rows: std.ArrayListUnmanaged(level_mod.TeleportRule) = .empty;
    errdefer rows.deinit(alloc);
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, "\r \t").len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        var i: usize = 0;
        var id: ?i32 = null;
        var tele: u8 = 1;
        while (cols.next()) |c| : (i += 1) {
            const v = std.mem.trim(u8, c, "\r ");
            if (i == idc) id = std.fmt.parseInt(i32, v, 10) catch null;
            if (i == tc) tele = std.fmt.parseInt(u8, v, 10) catch 1;
        }
        const lid = id orelse continue;
        if (lid < 0) continue;
        const want: usize = @intCast(lid + 1);
        if (rows.items.len < want) try rows.appendNTimes(alloc, .allowed, want - rows.items.len);
        rows.items[@intCast(lid)] = switch (tele) {
            0 => .forbidden,
            2 => .los_gated,
            else => .allowed,
        };
    }
    return rows.toOwnedSlice(alloc);
}

const testing = std.testing;

test "Levels.txt Teleport parses to the rule the engine applies" {
    const alloc = testing.allocator;
    const rules = try parseTeleportColumn(alloc);
    defer alloc.free(rules);

    // Only the Null level refuses teleport outright, and only Duriel's Lair gates the
    // destination — that is what Skills_SrvDoFunc_027_Teleport's two branches key on.
    try testing.expectEqual(level_mod.TeleportRule.forbidden, rules[0]);
    try testing.expectEqual(level_mod.TeleportRule.los_gated, rules[portals.DURIELS_LAIR]);
    try testing.expectEqual(level_mod.TeleportRule.allowed, rules[portals.ARCANE_SANCTUARY]);
    try testing.expectEqual(level_mod.TeleportRule.allowed, rules[1]);

    var forbidden: usize = 0;
    var gated: usize = 0;
    for (rules) |r| {
        if (r == .forbidden) forbidden += 1;
        if (r == .los_gated) gated += 1;
    }
    try testing.expectEqual(@as(usize, 1), forbidden);
    try testing.expectEqual(@as(usize, 1), gated);
}
