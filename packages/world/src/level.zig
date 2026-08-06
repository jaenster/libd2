//! One level of a live game: its collision grid, its rooms, its exits, and everything standing
//! on it right now.
//!
//! This is the domain object, not a search structure. The engine keeps exactly these two things
//! together — `D2RoomStrc` carries a collision grid AND `pRoomFirstUnit`, the list of units on it —
//! and never touches one without the other. `AllocDynamicPath` (0x6486a0) spells it out:
//!
//!     PATH_AddUnitCollision(pUnit);                              // stamp the grid
//!     Unit::DRLGROOM_AddUnitToRoom(pUnit, pDynamicPath->pRoom);  // link into the room's list
//!
//! So `addUnit` here does both, and there is no separate "overlay" for a caller to forget to keep
//! in sync. Everything a running server asks of a map — is this cell free, can I see from here to
//! there, where would the game actually put something dropped at this spot — is answered here,
//! against terrain and occupants together, with no cache in the way.
//!
//! What is NOT here is anything derived and cached for speed: the per-mask passability bitsets,
//! the connected-component labels, the distance transform. Those exist to make SEARCHING cheap and
//! they live with the searches, in d2-pathfinding. The division is the one the engine itself draws
//! — it has no bitsets either, only this grid.

const std = @import("std");
const drlg = @import("d2-drlg");
const rooms = @import("rooms.zig");
const occupancy = @import("occupancy.zig");
const core = @import("d2-core");
const collision = core.collision;

pub const Point = occupancy.Point;

/// Subtiles per DS1 tile. Positions here are subtiles; rooms are tiles.
pub const SUBTILES_PER_TILE: i32 = 5;

/// How a level connects to another one, in level-local subtiles on THIS level's grid.
pub const Exit = struct {
    to_level: i32,
    x: i32,
    y: i32,
    kind: Kind,

    pub const Kind = enum {
        /// A warp door / staircase: the room's warp slot resolved to a destination level.
        warp,
        /// An outdoor border bridge between two edge-to-edge levels — you walk across it.
        seam,
        /// A portal that map generation cannot see, because a quest creates it at runtime.
        /// See portals.zig.
        portal,
        /// A single teleport cast straight into the next level. Legal only where the engine's own
        /// cross-level near-room link exists AND the two cells are within the cast gate — see
        /// `World.crossLevelCast`.
        ///
        /// Like every other kind, `x`/`y` are where the transition happens ON THIS LEVEL — the cell
        /// you cast FROM, which is also this leg's last move. Where you land is the next leg's
        /// first move, in that level's own frame; convert both through `toWorld` to get the cast
        /// as the server sees it.
        teleport,
    };
};

/// A door placed on a level, in level-local subtiles.
pub const Door = struct {
    class_id: i32,
    x: i32,
    y: i32,
    /// Objects.txt `OperateFn`, which is a function INDEX rather than a name. 8 is the ordinary
    /// openable door (23 of the rows); 18 is a secret door, 29 the Act 3 slime doors, and 0 means
    /// the object has no operate function at all — Tyrael's door, which a quest opens, not you.
    /// A mover that has to decide whether it can open something needs this, not just the position.
    operate_fn: i16,

    /// True for the ordinary door a character opens by walking into it.
    pub fn isOrdinary(self: Door) bool {
        return self.operate_fn == 8;
    }
};

/// A one-way hop between two points of the SAME level: step on `at`, arrive at `to`.
///
/// The Arcane Sanctuary is the case that forces this to exist — its walkable ground is 17
/// disconnected islands and only the one holding the entry portal is reachable on foot, so
/// without the pads a router cannot leave the landing platform.
///
/// Pairing is `OBJOP_RevealAutomapArea` (0x581bf0, the Objects.txt `OperateFn` 27 handler): take
/// the pad stepped on, scan its own room's unit list for another OBJECT of the SAME class id that
/// is not itself, and failing that scan every adjacent room via `DRLGROOM_GetAdjacentRoomsList`.
/// First match wins. Each pad of a pair is its own object, so both directions exist as separate
/// entries here.
pub const Pad = struct {
    at: Point,
    to: Point,
    /// The Objects.txt id shared by both ends — the key the engine pairs on.
    class_id: i32,
};

pub const Level = struct {
    id: i32,
    /// World TILE origin. Levels of one act share a world frame; add `origin * 5` to a
    /// level-local subtile to get the world subtile a game client would report.
    origin_x: i32,
    origin_y: i32,
    /// Grid dimensions in SUBTILES.
    w: i32,
    h: i32,
    /// Level-local subtile collision, row-major, raw `u16` COLBIT. `collision.VOID` where no
    /// room covers. Owned.
    cells: []u16,
    rooms: rooms.RoomSet,
    /// The engine's CROSS-LEVEL near-room links for this level's rooms (`drlg.RoomLink`,
    /// harvested from `ppDrlgRoomsExNear`). `from_room` indexes `rooms.rooms`. Same-level
    /// adjacency is not in here — `RoomSet` derives that geometrically.
    links: []drlg.RoomLink,
    /// Preset units placed by the DS1s of this level, in LEVEL-LOCAL subtiles — the same frame as
    /// everything else here. `etype` 2 is an object, and then `txt_file_no` is its Objects.txt id,
    /// which is how a caller finds a waypoint, a seal or a chest to path to.
    presets: []drlg.PresetUnit,
    exits: []Exit,
    /// Paired teleporters WITHIN this level (the Arcane Sanctuary pads). Owned.
    pads: []Pad,
    /// Levels.txt `Teleport`: 0 refuses teleport outright, 1 allows it, 2 gates the destination.
    teleport: TeleportRule,

    alloc: std.mem.Allocator,
    /// Everything standing on the level right now, and the bits each occupant contributes. The
    /// engine's `pRoomFirstUnit` and its half of the collision grid, in one place — see `addUnit`.
    units: occupancy.Occupancy,
    /// Bumped whenever `editTerrain` changes the grid itself. Anything a consumer derives from
    /// `cells` and caches (d2-pathfinding's bitsets and component labels) compares this to know it
    /// has gone stale. Occupancy does NOT bump it: units never change terrain.
    terrain_gen: u64 = 0,

    pub fn deinit(self: *Level) void {
        self.units.deinit();
        self.alloc.free(self.cells);
        self.alloc.free(self.exits);
        self.alloc.free(self.links);
        self.alloc.free(self.presets);
        self.alloc.free(self.pads);
        self.rooms.deinit(self.alloc);
        self.* = undefined;
    }

    pub inline fn tileW(self: *const Level) i32 {
        return @divTrunc(self.w, SUBTILES_PER_TILE);
    }

    pub inline fn tileH(self: *const Level) i32 {
        return @divTrunc(self.h, SUBTILES_PER_TILE);
    }

    /// Put a unit on the level, or move one already there.
    ///
    /// This is `AllocDynamicPath`'s pair — `PATH_AddUnitCollision` plus `DRLGROOM_AddUnitToRoom` —
    /// as one call, because the engine never does one without the other. `what` says which cells
    /// are claimed and with which bit; build it with `core.unit.Collision.monster(...)` and friends
    /// so the answer comes from the unit's type rather than from a hand-picked flag.
    ///
    /// Every query on this level sees it from here on. A caller that wants the answer for bare
    /// TERRAIN instead drops the presence bits from its mask — `mask & ~collision.PRESENCE_BITS` —
    /// which is exactly the part of a path mask that occupancy writes.
    pub fn addUnit(self: *Level, id: u32, at_pos: Point, what: core.unit.Collision) !void {
        try self.units.place(id, at_pos, what.stamp, what.flag);
    }

    /// Walk a unit to another subtile, keeping its stamp and class. Unconditional: use `stepUnit`
    /// for the engine's guarded version.
    pub fn moveUnit(self: *Level, id: u32, to: Point) !void {
        try self.units.moveTo(id, to);
    }

    /// One step of a walking unit — `RemoveGetCollision_Width` (0x64ed20). Lifts the unit first (so
    /// it cannot collide with the cells it is itself standing on), looks at the destination, and
    /// leaves it where it was if what it found was geometry. Returns the collision bits at the
    /// destination, 0 when it was clear.
    pub fn stepUnit(self: *Level, id: u32, to: Point, mask: u16) !u16 {
        return self.units.step(id, to, self.cells, mask);
    }

    /// Take a unit off the level, restoring every cell it covered.
    pub fn removeUnit(self: *Level, id: u32) void {
        self.units.lift(id);
    }

    /// Empty the level of everything standing on it, terrain untouched.
    pub fn clearUnits(self: *Level) void {
        self.units.clear();
    }

    /// What terrain itself changed, as opposed to who is standing on it. Both directions in one
    /// call because a door opening does both: the `door` bit goes and nothing replaces it, while a
    /// quest barrier appearing adds `wall`.
    pub const TerrainEdit = struct {
        add: u16 = 0,
        remove: u16 = 0,
    };

    /// A rectangle of subtiles, inclusive of both corners.
    pub const Rect = struct {
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,

        /// The 5x5 subtile block one DS1 tile covers — the granularity the engine changes terrain
        /// at, since a door swaps a whole tile.
        pub fn tile(tx: i32, ty: i32) Rect {
            const s = SUBTILES_PER_TILE;
            return .{ .x0 = tx * s, .y0 = ty * s, .x1 = tx * s + s - 1, .y1 = ty * s + s - 1 };
        }

        pub fn at(x: i32, y: i32) Rect {
            return .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y };
        }
    };

    /// Change the terrain under a rectangle: a door opens, a quest barrier drops, Duriel's
    /// entrance unseals.
    ///
    /// This rewrites the generated grid rather than layering over it, which is what the engine does
    /// too — a door swaps its tile and `TileLibrary_UpdateCollision` (0x64c860) re-runs the tile's
    /// collision into the room's map. Unlike a unit such an edit can make a cell MORE passable, so
    /// it bumps `terrain_gen` and every cache built on this grid rebuilds. That is why it is a
    /// separate operation from `addUnit` and not merely a different set of bits.
    ///
    /// Subtiles no room covers (`collision.VOID`) are left alone: the engine has no grid there to
    /// write to either. Returns true when anything actually changed.
    pub fn editTerrain(self: *Level, rect: Rect, edit: TerrainEdit) bool {
        const x0 = @max(0, rect.x0);
        const y0 = @max(0, rect.y0);
        const x1 = @min(self.w - 1, rect.x1);
        const y1 = @min(self.h - 1, rect.y1);
        if (x0 > x1 or y0 > y1) return false;

        var changed = false;
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const i: usize = @intCast(y * self.w + x);
                if (self.cells[i] == collision.VOID) continue;
                const next = (self.cells[i] & ~edit.remove) | edit.add;
                if (next == self.cells[i]) continue;
                self.cells[i] = next;
                changed = true;
            }
        }
        if (changed) self.terrain_gen += 1;
        return changed;
    }

    /// A level that is nothing but a grid — no rooms, no exits, no presets. What a test needs, and
    /// what a host wants for a scratch arena it builds itself rather than generates. Takes
    /// ownership of `cells`.
    pub fn initBare(alloc: std.mem.Allocator, w: i32, h: i32, cells: []u16) !Level {
        std.debug.assert(cells.len == @as(usize, @intCast(w * h)));
        return .{
            .id = 0,
            .origin_x = 0,
            .origin_y = 0,
            .w = w,
            .h = h,
            .cells = cells,
            .rooms = .{},
            .links = &.{},
            .presets = &.{},
            .exits = &.{},
            .pads = &.{},
            .teleport = .allowed,
            .alloc = alloc,
            .units = try occupancy.Occupancy.init(alloc, w, h),
        };
    }

    pub inline fn inBounds(self: *const Level, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and x < self.w and y < self.h;
    }

    /// Raw collision value at a level-local subtile, `VOID` outside the grid.
    pub fn at(self: *const Level, x: i32, y: i32) u16 {
        if (!self.inBounds(x, y)) return collision.VOID;
        return self.cells[@intCast(y * self.w + x)];
    }

    /// Collision at a subtile as the GAME sees it: terrain plus whoever is standing there. This is
    /// the value every engine collision test reads; `at` is the generated half alone.
    pub fn liveAt(self: *const Level, x: i32, y: i32) u16 {
        if (!self.inBounds(x, y)) return collision.VOID;
        const i: usize = @intCast(y * self.w + x);
        return self.cells[i] | self.units.at(i);
    }

    /// May a unit whose collision model is `mask` stand on this exact subtile? Point-sized: a unit
    /// with a real footprint is checked with `blockedAt`, which is what the engine does.
    pub fn passable(self: *const Level, x: i32, y: i32, mask: u16) bool {
        return self.liveAt(x, y) & mask == 0;
    }

    /// `CheckCollision_BlockAll_Width` (0x64d9b0): the OR of everything a unit of `size` sees from
    /// this cell, terrain and occupants alike, narrowed to `mask`. 0 means the unit fits.
    ///
    /// Off the grid reads as `VOID`, which is the engine's missing-room case — a unit cannot stand
    /// half outside the world.
    pub fn blockedAt(self: *const Level, at_pos: Point, size: collision.Size, mask: u16) u16 {
        var found: u16 = 0;
        for (collision.cellsOf(size)) |d| found |= self.liveAt(at_pos.x + d[0], at_pos.y + d[1]);
        return found & mask;
    }

    /// Walk the line from `from` to `to`, stopping at the first cell `mask` rejects. Both endpoints
    /// are tested, and a cell off the grid blocks.
    ///
    /// This is `Collision::TestCollision` (0x64e260) with the room walk collapsed, because a level
    /// here is already one flat grid where the engine has to re-resolve the room at every boundary.
    /// Same four cases (degenerate, vertical, horizontal, and Bresenham split on which axis is
    /// major), same order — test the cell, then advance — so the same set of cells is visited. Note
    /// the engine's own return is inverted: `TestCollision` yields TRUE for a HIT, and
    /// `SKILLS_HasLineOfSight` (0x645910) is a one-line negation of it.
    ///
    /// The mask is what makes this one function serve every caller the engine has: line of sight
    /// with the caster's mask, a missile with `Colmask.missile_flight`, an area-of-effect check
    /// with whatever the skill passes.
    pub fn trace(self: *const Level, from: Point, to: Point, mask: u16) Trace {
        var x = from.x;
        var y = from.y;
        const span_x = to.x - x;
        const span_y = to.y - y;
        const step_x: i32 = if (span_x < 0) -1 else 1;
        const step_y: i32 = if (span_y < 0) -1 else 1;
        const dx: i32 = if (span_x < 0) -span_x else span_x;
        const dy: i32 = if (span_y < 0) -span_y else span_y;

        if (dx < dy) {
            // Steep: y advances every step, x follows the error term.
            var err: i32 = 0;
            while (true) {
                if (!self.passable(x, y, mask)) return .{ .at = .{ .x = x, .y = y }, .blocked = true };
                if (y == to.y) return .{ .at = .{ .x = x, .y = y }, .blocked = false };
                y += step_y;
                err += dx;
                if (err >= dy) {
                    err -= dy;
                    x += step_x;
                }
            }
        }
        // Shallow, and the degenerate/axis-aligned cases fall out of it: when dy is 0 the error term
        // never fires and y never moves, and when both are 0 the first cell is also the last.
        var err: i32 = 0;
        while (true) {
            if (!self.passable(x, y, mask)) return .{ .at = .{ .x = x, .y = y }, .blocked = true };
            if (x == to.x) return .{ .at = .{ .x = x, .y = y }, .blocked = false };
            err += dy;
            x += step_x;
            if (err >= dx) {
                err -= dx;
                y += step_y;
            }
        }
    }

    /// `SKILLS_HasLineOfSight` (0x645910): is the line clear end to end?
    pub fn hasLineOfSight(self: *const Level, from: Point, to: Point, mask: u16) bool {
        return !self.trace(from, to, mask).blocked;
    }

    /// Where the server would actually put something asked for at `at_pos` — `GetFreeCoordinates`
    /// (0x64dea0), which decides teleport landings, corpse and item drops, portal placement,
    /// `WarpToAct` and monster spawns.
    ///
    /// The exact cell is tried first with the unit's footprint. Failing that it walks expanding
    /// square rings, and within the FIRST ring that contains anything free it takes the candidate
    /// with the smallest MANHATTAN distance to the origin — not the first one it meets. Ring `k`
    /// sits at radius `k * step`, and the walk stops once `1 + radius` reaches `max_distance`.
    ///
    /// The `pFieldCoords` variant, which additionally requires a clear path from a second point via
    /// `FIELDTBLS_TracePathCheckCollision`, is NOT modelled here — that function has not been read.
    /// Callers that need it (item and gold drops) will place slightly differently than the server.
    pub fn freeCoordinates(self: *const Level, at_pos: Point, size: collision.Size, mask: u16, opts: FreeCoordOptions) ?Point {
        if (self.blockedAt(at_pos, size, mask) == 0) return at_pos;
        if (opts.max_distance <= 1) return null;

        const inc = opts.step;
        var y_top = at_pos.y + 1;
        var y_bottom = at_pos.y - 1;
        var x_left = at_pos.x;
        var x_right = at_pos.x;
        var stride: i32 = 2;

        while (true) {
            var best: ?Point = null;
            var best_dist: i32 = -1;

            // The ring's two vertical edges: every row, but only the leftmost and rightmost columns.
            var iy = y_bottom;
            while (iy <= y_top) : (iy += inc) {
                var ix = x_left - 1;
                while (ix <= x_right + 1) : (ix += stride) {
                    self.considerFree(at_pos, ix, iy, size, mask, &best, &best_dist);
                }
            }
            // And its two horizontal edges: every column between them, top row and bottom row only.
            var ix = x_left;
            while (ix <= x_right) : (ix += inc) {
                var iy2 = y_bottom;
                while (iy2 <= y_top) : (iy2 += stride) {
                    self.considerFree(at_pos, ix, iy2, size, mask, &best, &best_dist);
                }
            }

            if (best) |p| return p;

            y_top += inc;
            y_bottom -= inc;
            x_left -= inc;
            x_right += inc;
            stride += inc * 2;
            if (1 + (x_right - at_pos.x) >= opts.max_distance) return null;
        }
    }

    fn considerFree(self: *const Level, origin: Point, x: i32, y: i32, size: collision.Size, mask: u16, best: *?Point, best_dist: *i32) void {
        if (self.blockedAt(.{ .x = x, .y = y }, size, mask) != 0) return;
        const d: i32 = @intCast(@abs(x - origin.x) + @abs(y - origin.y));
        if (best_dist.* == -1 or d < best_dist.*) {
            best.* = .{ .x = x, .y = y };
            best_dist.* = d;
        }
    }

    /// The nearest subtile to (x,y) a unit of `size` fits on, searched in rings so the first hit is
    /// the closest. Null when nothing within `radius` fits. Our stand-in for the engine's
    /// `GetFreeCoordinates_WithNeighboorRooms` snap (0x64c2b0 family), for callers that hand us a
    /// requested position — a warp tile, a teleport landing, a caller's goal — that may sit inside
    /// a wall.
    pub fn nearestFree(self: *const Level, x: i32, y: i32, size: collision.Size, mask: u16, radius: i32) ?Point {
        const S = struct {
            lv: *const Level,
            size: collision.Size,
            mask: u16,
            fn ok(ctx: @This(), px: i32, py: i32) bool {
                return ctx.lv.blockedAt(.{ .x = px, .y = py }, ctx.size, ctx.mask) == 0;
            }
        };
        return ringSearch(S{ .lv = self, .size = size, .mask = mask }, x, y, radius, S.ok);
    }

    pub fn toWorld(self: *const Level, p: Point) Point {
        return .{
            .x = p.x + self.origin_x * SUBTILES_PER_TILE,
            .y = p.y + self.origin_y * SUBTILES_PER_TILE,
        };
    }

    /// Every preset OBJECT with this Objects.txt id, appended to `out`.
    pub fn findObjects(self: *const Level, class_id: i32, out: *std.ArrayListUnmanaged(Point), alloc: std.mem.Allocator) !void {
        for (self.presets) |u| {
            if (u.etype == 2 and u.txt_file_no == class_id) try out.append(alloc, .{ .x = u.x, .y = u.y });
        }
    }

    pub fn fromWorld(self: *const Level, p: Point) Point {
        return .{
            .x = p.x - self.origin_x * SUBTILES_PER_TILE,
            .y = p.y - self.origin_y * SUBTILES_PER_TILE,
        };
    }
};

/// Levels.txt `Teleport`, as `Skills_SrvDoFunc_027_Teleport` (0x5ca360) reads it:
///
///     if (!pLevelTxt->Teleport) return 0;                                    // .forbidden
///     if (pLevelTxt->Teleport == 2 &&
///         TestCollisionByCoordinates(pUnit, x, y, 0x804)) return 0;          // .gated
///     return SUNIT_RelocateUnit(...);                                        // .allowed
///
/// In 1.14d only level 0 (Null) is 0 and only Duriel's Lair (73) is 2 — everything else is 1.
pub const TeleportRule = enum(u8) {
    forbidden = 0,
    allowed = 1,
    gated = 2,

    /// The extra mask a `.gated` level applies to the destination. Read off the instruction
    /// itself: `PUSH 0x804` at 0x5ca3a6 feeds `TestCollisionByCoordinates`, and 0x804 is
    /// `COLMASK_PLAYER_FLYING` — door | missile_barrier. A cell carrying either refuses the cast.
    pub fn destinationMask(self: TeleportRule, base: u16) u16 {
        return switch (self) {
            .forbidden, .allowed => base,
            .gated => base | collision.Colmask.player_flying,
        };
    }
};

pub const Trace = struct {
    /// Where the walk stopped: the blocking cell when `blocked`, otherwise the destination.
    at: Point,
    blocked: bool,
};

pub const FreeCoordOptions = struct {
    /// `nMaxDistance`. The search does not start at all at 1 or less.
    max_distance: i32 = 20,
    /// `nPosIncrementValue`: how far apart the rings are, and the stride within them.
    step: i32 = 1,
};

/// Walk outward from (cx,cy) in expanding square rings and return the first cell `ok` accepts, so
/// the answer is the nearest one. Shared because both the level's own `nearestFree` and
/// d2-pathfinding's bitset-accelerated snap need exactly this order and must not disagree about it.
pub fn ringSearch(
    ctx: anytype,
    cx: i32,
    cy: i32,
    radius: i32,
    comptime ok: fn (@TypeOf(ctx), i32, i32) bool,
) ?Point {
    if (ok(ctx, cx, cy)) return .{ .x = cx, .y = cy };
    var r: i32 = 1;
    while (r <= radius) : (r += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            for ([_]i32{ -r, r }) |dy| {
                if (ok(ctx, cx + dx, cy + dy)) return .{ .x = cx + dx, .y = cy + dy };
            }
        }
        var dy: i32 = -r + 1;
        while (dy <= r - 1) : (dy += 1) {
            for ([_]i32{ -r, r }) |ddx| {
                if (ok(ctx, cx + ddx, cy + dy)) return .{ .x = cx + ddx, .y = cy + dy };
            }
        }
    }
    return null;
}

const MASK = collision.Colmask.player_path;

test "the tracer stops on the first blocking cell and reports it" {
    const alloc = std.testing.allocator;
    // Open 9x9 with a vertical wall at x = 4.
    var cells = [_]u16{0} ** (9 * 9);
    for (0..9) |y| cells[y * 9 + 4] = collision.Colbit.wall;
    var lv = try Level.initBare(alloc, 9, 9, try alloc.dupe(u16, &cells));
    defer lv.deinit();

    const hit = lv.trace(.{ .x = 0, .y = 4 }, .{ .x = 8, .y = 4 }, MASK);
    try std.testing.expect(hit.blocked);
    try std.testing.expectEqual(@as(i32, 4), hit.at.x);
    try std.testing.expectEqual(@as(i32, 4), hit.at.y);
    try std.testing.expect(!lv.hasLineOfSight(.{ .x = 0, .y = 4 }, .{ .x = 8, .y = 4 }, MASK));

    // Along the wall, never across it.
    try std.testing.expect(lv.hasLineOfSight(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 8 }, MASK));
    // Both endpoints are tested: aiming AT the wall is blocked even from right beside it.
    try std.testing.expect(!lv.hasLineOfSight(.{ .x = 3, .y = 4 }, .{ .x = 4, .y = 4 }, MASK));
    // A cell is traced against itself.
    try std.testing.expect(lv.hasLineOfSight(.{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 }, MASK));
    try std.testing.expect(!lv.hasLineOfSight(.{ .x = 4, .y = 3 }, .{ .x = 4, .y = 3 }, MASK));
}

test "an open grid traces clear in every direction, and leaving it blocks" {
    const alloc = std.testing.allocator;
    var open = [_]u16{0} ** (9 * 9);
    var lv = try Level.initBare(alloc, 9, 9, try alloc.dupe(u16, &open));
    defer lv.deinit();

    var a: i32 = 0;
    while (a < 9) : (a += 1) {
        var b: i32 = 0;
        while (b < 9) : (b += 1) {
            try std.testing.expect(lv.hasLineOfSight(.{ .x = 0, .y = a }, .{ .x = 8, .y = b }, MASK));
            try std.testing.expect(lv.hasLineOfSight(.{ .x = a, .y = 0 }, .{ .x = b, .y = 8 }, MASK));
        }
    }
    // Off the grid is the engine's null-room case: blocked.
    try std.testing.expect(!lv.hasLineOfSight(.{ .x = 4, .y = 4 }, .{ .x = 20, .y = 4 }, MASK));
    try std.testing.expect(!lv.hasLineOfSight(.{ .x = 4, .y = 4 }, .{ .x = 4, .y = -3 }, MASK));
}

test "line of sight is direction-dependent, as it is in the engine" {
    const alloc = std.testing.allocator;
    // A single blocking cell off the centre line. Bresenham visits a different chain of cells
    // depending on which end it starts from, so a thin obstacle can be clipped one way and missed
    // the other. TestCollision (0x64e260) has exactly this property, and the direction the server
    // uses is TARGET -> CASTER: SKILLS_HasLineOfSightToUnit (0x645950) puts the aim point in ptSrc
    // and the unit's own position in ptDest.
    var cells = [_]u16{0} ** (9 * 9);
    cells[3 * 9 + 6] = collision.Colbit.wall;
    var lv = try Level.initBare(alloc, 9, 9, try alloc.dupe(u16, &cells));
    defer lv.deinit();

    var asymmetric: usize = 0;
    var a: i32 = 0;
    while (a < 9) : (a += 1) {
        var b: i32 = 0;
        while (b < 9) : (b += 1) {
            const fwd = lv.hasLineOfSight(.{ .x = 0, .y = a }, .{ .x = 8, .y = b }, MASK);
            const rev = lv.hasLineOfSight(.{ .x = 8, .y = b }, .{ .x = 0, .y = a }, MASK);
            if (fwd != rev) asymmetric += 1;
        }
    }
    try std.testing.expect(asymmetric > 0);
}

test "a mask decides what a trace is stopped by" {
    const alloc = std.testing.allocator;
    var cells = [_]u16{0} ** (9 * 9);
    cells[4 * 9 + 4] = collision.Colbit.object;
    var lv = try Level.initBare(alloc, 9, 9, try alloc.dupe(u16, &cells));
    defer lv.deinit();

    const a: Point = .{ .x = 2, .y = 4 };
    const b: Point = .{ .x = 6, .y = 4 };
    // An object stops the player and not the missile...
    try std.testing.expect(!lv.hasLineOfSight(a, b, MASK));
    try std.testing.expect(lv.hasLineOfSight(a, b, collision.Colmask.missile_flight));

    // ...and a missile barrier is the other way round.
    lv.cells[4 * 9 + 4] = collision.Colbit.missile_barrier;
    try std.testing.expect(lv.hasLineOfSight(a, b, MASK));
    const stop = lv.trace(a, b, collision.Colmask.missile_flight);
    try std.testing.expect(stop.blocked);
    try std.testing.expectEqual(@as(i32, 4), stop.at.x);
}

test "freeCoordinates returns the spot itself when it is already free" {
    const alloc = std.testing.allocator;
    var open = [_]u16{0} ** (11 * 11);
    var lv = try Level.initBare(alloc, 11, 11, try alloc.dupe(u16, &open));
    defer lv.deinit();
    const got = lv.freeCoordinates(.{ .x = 5, .y = 5 }, .point, MASK, .{}).?;
    try std.testing.expectEqual(@as(i32, 5), got.x);
    try std.testing.expectEqual(@as(i32, 5), got.y);
}

test "freeCoordinates takes the best Manhattan cell of the first ring, not the first found" {
    const alloc = std.testing.allocator;
    // Block the centre. In the 3x3 ring the four orthogonal neighbours are Manhattan 1 and the four
    // diagonals are 2; the scan meets a diagonal first, so returning it would prove we had copied a
    // first-hit search instead of the engine's.
    var cells = [_]u16{0} ** (11 * 11);
    cells[5 * 11 + 5] = collision.Colbit.wall;
    var lv = try Level.initBare(alloc, 11, 11, try alloc.dupe(u16, &cells));
    defer lv.deinit();

    const got = lv.freeCoordinates(.{ .x = 5, .y = 5 }, .point, MASK, .{}).?;
    try std.testing.expectEqual(@as(u32, 1), @abs(got.x - 5) + @abs(got.y - 5));
}

test "freeCoordinates spirals past a blocked ring and respects max_distance" {
    const alloc = std.testing.allocator;
    // Everything solid except one cell four to the left, so rings 1..3 are all blocked.
    var cells = [_]u16{collision.Colbit.wall} ** (11 * 11);
    cells[5 * 11 + 1] = 0;
    var lv = try Level.initBare(alloc, 11, 11, try alloc.dupe(u16, &cells));
    defer lv.deinit();

    const at_pos = Point{ .x = 5, .y = 5 };
    const got = lv.freeCoordinates(at_pos, .point, MASK, .{ .max_distance = 20 }).?;
    try std.testing.expectEqual(@as(i32, 1), got.x);
    try std.testing.expectEqual(@as(i32, 5), got.y);

    // The walk stops once 1 + radius reaches max_distance, so a tight budget finds nothing...
    try std.testing.expect(lv.freeCoordinates(at_pos, .point, MASK, .{ .max_distance = 3 }) == null);
    // ...and at 1 or less it never starts.
    try std.testing.expect(lv.freeCoordinates(at_pos, .point, MASK, .{ .max_distance = 1 }) == null);
}

test "freeCoordinates honours the footprint the unit occupies" {
    const alloc = std.testing.allocator;
    // A one-subtile slot in a solid field: a point-sized unit fits, a cross does not (its arms
    // reach into the wall), so the two sizes must give different answers to the same request.
    var cells = [_]u16{collision.Colbit.wall} ** (21 * 21);
    cells[10 * 21 + 10] = 0;
    var lv = try Level.initBare(alloc, 21, 21, try alloc.dupe(u16, &cells));
    defer lv.deinit();

    const want = Point{ .x = 10, .y = 10 };
    try std.testing.expectEqual(want, lv.freeCoordinates(want, .point, MASK, .{ .max_distance = 30 }).?);
    // The cross cannot use it, and there is nowhere else in a solid field.
    try std.testing.expect(lv.freeCoordinates(want, .small, MASK, .{ .max_distance = 30 }) == null);
}

test "a unit stamped on the level is seen by trace and by freeCoordinates alike" {
    const alloc = std.testing.allocator;
    var open = [_]u16{0} ** (21 * 21);
    var lv = try Level.initBare(alloc, 21, 21, try alloc.dupe(u16, &open));
    defer lv.deinit();

    const a: Point = .{ .x = 8, .y = 10 };
    const b: Point = .{ .x = 12, .y = 10 };
    try std.testing.expect(lv.hasLineOfSight(a, b, MASK));

    try lv.addUnit(1, .{ .x = 10, .y = 10 }, .monster(2, false, .{}));
    // One `addUnit` and every query on the level changed its mind together.
    try std.testing.expect(!lv.hasLineOfSight(a, b, MASK));
    try std.testing.expect(!lv.passable(10, 10, MASK));
    try std.testing.expect(!std.meta.eql(
        lv.freeCoordinates(.{ .x = 10, .y = 10 }, .point, MASK, .{}).?,
        Point{ .x = 10, .y = 10 },
    ));
    // ...except one asked with the presence bits dropped, which is the terrain answer.
    try std.testing.expect(lv.hasLineOfSight(a, b, MASK & ~collision.PRESENCE_BITS));

    lv.removeUnit(1);
    try std.testing.expect(lv.hasLineOfSight(a, b, MASK));
}

test "stepUnit walks a unit and refuses geometry" {
    const alloc = std.testing.allocator;
    var cells = [_]u16{0} ** (21 * 21);
    cells[10 * 21 + 14] = collision.Colbit.wall;
    var lv = try Level.initBare(alloc, 21, 21, try alloc.dupe(u16, &cells));
    defer lv.deinit();

    try lv.addUnit(1, .{ .x = 5, .y = 10 }, .player(2));
    try std.testing.expectEqual(@as(u16, 0), try lv.stepUnit(1, .{ .x = 6, .y = 10 }, MASK));
    try std.testing.expectEqual(Point{ .x = 6, .y = 10 }, lv.units.get(1).?.at);

    // A player is a SMALL unit, checked over its whole cross, so (13,10) is already refused — one
    // subtile short of the wall itself — and the unit stays where it was.
    try lv.moveUnit(1, .{ .x = 12, .y = 10 });
    try std.testing.expectEqual(collision.Colbit.wall, try lv.stepUnit(1, .{ .x = 13, .y = 10 }, MASK));
    try std.testing.expectEqual(Point{ .x = 12, .y = 10 }, lv.units.get(1).?.at);
}
