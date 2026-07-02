//! Parser for Diablo II `.ds1` preset map files — the tile grid that defines a
//! level's hand-authored layout (floors, walls, shadows, objects).
//!
//! Ported faithfully from the reconstructed 1.14d `ParsePresetsOfDrlgFile`
//! (D2Common/Drlg/Preset.cpp, ~lines 82-449). The reconstruction reads the DS1
//! straight out of a loaded file buffer that the decompiler aliases through
//! `D2ArchiveStrc` fields; here we drop that aliasing and walk the byte stream
//! with a plain cursor. The version gates are the authoritative part and are
//! reproduced exactly.
//!
//! Cell counts: the DS1 header stores width/height as (tiles - 1); the real tile
//! grid is `(width+1) * (height+1)` cells. We store the *actual* tile counts.

const std = @import("std");

/// One packed tile cell. The raw int32 carries up to four byte-fields; for
/// floor/wall layers these are prop1 (main tile index), prop2 (sub index),
/// orientation, and flags. We expose the raw value plus the decoded fields a
/// renderer needs.
pub const Cell = struct {
    raw: u32,
    prop1: u8,
    prop2: u8,
    orientation: u8,

    fn from(v: u32) Cell {
        return .{
            .raw = v,
            .prop1 = @truncate(v),
            .prop2 = @truncate(v >> 8),
            .orientation = @truncate(v >> 16),
        };
    }
};

/// One wall layer: the wall cells plus their paired orientation/type cells.
/// The reconstruction stores these interleaved per layer (wall block then
/// orientation block), which is what we mirror.
pub const WallLayer = struct {
    wall: []Cell,
    orient: []Cell,
};

/// A preset object record: { type, id, x, y, flags }. `flags` is only present
/// (and meaningful) for version >= 6; older files read back 0.
pub const Object = struct {
    kind: i32,
    id: i32,
    x: i32,
    y: i32,
    flags: i32,
};

/// A substitution-group record (recon `D2DrlgSubstGroupStrc`): a tile box plus
/// one unknown field. Present only for version >= 12 AND act in {1,2}; the
/// `unknown` field exists only for version >= 13 (read back 0 otherwise). The
/// generator's substitution logic keys off these boxes.
pub const SubstGroup = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    unknown: i32,
};

/// One node of an NPC walk path: a tile coord plus an action code. `action` is
/// only stored in the file for version >= 15; for version 14 the recon
/// hard-codes it to 1.
pub const PathPoint = struct {
    x: i32,
    y: i32,
    action: i32,
};

/// An NPC-path stream entry (recon: a preset unit's `pPath`). Each entry names a
/// target tile (x,y); the recon matches it against a preset object with the same
/// coords and hangs the path off that object. We record the matched object index
/// (or null when no object shares the coords) so nothing is lost either way.
pub const NpcPath = struct {
    x: i32,
    y: i32,
    object_index: ?usize,
    points: []PathPoint,
};

pub const Ds1 = struct {
    allocator: std.mem.Allocator,

    version: i32,
    /// Actual tile counts (header value + 1).
    width: u32,
    height: u32,
    /// DS1 act field. `act` is the version>=10 field that gates the subst-tag
    /// layer and subst groups (struct nAct in the recon). `act_id` is the
    /// version>=8 field clamped to <=4 (nActId in the recon, used for monster
    /// preset lookups).
    act: i32,
    act_id: i32,

    wall_layers: []WallLayer,
    floor_layers: [][]Cell,
    shadow: []Cell,
    /// Substitution-group tag layer, present only when act is 1 or 2.
    subst_tags: ?[]Cell,

    objects: []Object,

    /// Substitution groups (version >= 12, act 1/2). Empty for other files.
    subst_groups: []SubstGroup,
    /// NPC walk paths (version >= 14). Empty for older files. Each entry's
    /// `object_index` points back into `objects` when a coord match was found.
    npc_paths: []NpcPath,

    /// Total bytes consumed by the parse. For a well-formed DS1 this equals the
    /// input length (the whole file is now consumed to EOF).
    bytes_consumed: usize,
    /// True only as a fallback: a file version outside the recon's handled range
    /// appeared, so the trailing NPC-path stream may not be fully modelled. For
    /// every version the recon handles (<= 18) this stays false.
    npc_paths_deferred: bool,

    pub fn deinit(self: *Ds1) void {
        const a = self.allocator;
        for (self.wall_layers) |wl| {
            a.free(wl.wall);
            a.free(wl.orient);
        }
        a.free(self.wall_layers);
        for (self.floor_layers) |fl| a.free(fl);
        a.free(self.floor_layers);
        a.free(self.shadow);
        if (self.subst_tags) |st| a.free(st);
        a.free(self.objects);
        a.free(self.subst_groups);
        for (self.npc_paths) |np| a.free(np.points);
        a.free(self.npc_paths);
        self.* = undefined;
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readI32(self: *Reader) !i32 {
        return @bitCast(try self.readU32());
    }

    fn readU32(self: *Reader) !u32 {
        if (self.pos + 4 > self.bytes.len) return error.UnexpectedEof;
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.bytes.len) return error.UnexpectedEof;
        self.pos += n;
    }

    /// Skip one NUL-terminated string (path entry).
    fn skipCStr(self: *Reader) !void {
        while (true) {
            if (self.pos >= self.bytes.len) return error.UnexpectedEof;
            const c = self.bytes[self.pos];
            self.pos += 1;
            if (c == 0) return;
        }
    }

    /// Read `n` packed cells into a freshly allocated slice.
    fn readBlock(self: *Reader, a: std.mem.Allocator, n: usize) ![]Cell {
        const cells = try a.alloc(Cell, n);
        errdefer a.free(cells);
        for (cells) |*c| c.* = Cell.from(try self.readU32());
        return cells;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Ds1 {
    var r = Reader{ .bytes = bytes };

    const version = try r.readI32();
    const raw_width = try r.readI32();
    const raw_height = try r.readI32();

    var act_id: i32 = 0;
    if (version > 7) {
        act_id = try r.readI32();
        if (act_id > 4) act_id = 4;
    }

    var act: i32 = 0;
    if (version > 9) act = try r.readI32();

    // version >= 3: numFiles, then that many NUL-terminated path strings.
    if (version > 2) {
        const num_files = try r.readI32();
        var i: i32 = 0;
        while (i < num_files) : (i += 1) try r.skipCStr();
    }

    const w: usize = @intCast(raw_width + 1);
    const h: usize = @intCast(raw_height + 1);
    const cells: usize = w * h;

    // Murky recon gate (`nDs1Version[-1].szInternalPrefix + 0xff < 0x5`, pure
    // decompiler aliasing). Public DS1 spec: skip 8 bytes for version in [9..13].
    if (version >= 9 and version <= 13) try r.skip(8);

    var wall_layers_list: std.ArrayListUnmanaged(WallLayer) = .empty;
    errdefer freeWallList(allocator, &wall_layers_list);
    var floor_layers_list: std.ArrayListUnmanaged([]Cell) = .empty;
    errdefer freeFloorList(allocator, &floor_layers_list);

    if (version < 4) {
        // Legacy packed layout: one wall, one orientation/type, one floor block
        // (plus a fourth block the recon reserves for subst tags). Not exercised
        // by 1.14d data; kept for completeness.
        const wall = try r.readBlock(allocator, cells);
        const orient = try r.readBlock(allocator, cells);
        try wall_layers_list.append(allocator, .{ .wall = wall, .orient = orient });
        const floor = try r.readBlock(allocator, cells);
        try floor_layers_list.append(allocator, floor);
        try r.skip(cells * 4); // reserved subst-tags block
    } else {
        const num_walls = try r.readI32();
        var num_floors: i32 = 1;
        if (version >= 16) num_floors = try r.readI32();

        var i: i32 = 0;
        while (i < num_walls) : (i += 1) {
            const wall = try r.readBlock(allocator, cells);
            errdefer allocator.free(wall);
            const orient = try r.readBlock(allocator, cells);
            try wall_layers_list.append(allocator, .{ .wall = wall, .orient = orient });
        }
        i = 0;
        while (i < num_floors) : (i += 1) {
            const floor = try r.readBlock(allocator, cells);
            try floor_layers_list.append(allocator, floor);
        }
    }

    // version < 7 remaps wall orientation indices via
    // DRLGANIM_GetOrientationFromIndex. 1.14d files are >= 7, so the raw
    // orientation byte is already in final form; we expose it unmodified.

    const shadow = try r.readBlock(allocator, cells);
    errdefer allocator.free(shadow);

    // Subst-group tag layer present when act is 1 or 2 (recon: nAct-1U < 2).
    var subst_tags: ?[]Cell = null;
    errdefer if (subst_tags) |st| allocator.free(st);
    if (act >= 1 and act <= 2) {
        subst_tags = try r.readBlock(allocator, cells);
    }

    // version >= 2: object list.
    var objects_list: std.ArrayListUnmanaged(Object) = .empty;
    errdefer objects_list.deinit(allocator);
    if (version > 1) {
        const num_objects = try r.readI32();
        var i: i32 = 0;
        while (i < num_objects) : (i += 1) {
            const kind = try r.readI32();
            const id = try r.readI32();
            const x = try r.readI32();
            const y = try r.readI32();
            var flags: i32 = 0;
            if (version > 5) flags = try r.readI32();
            try objects_list.append(allocator, .{ .kind = kind, .id = id, .x = x, .y = y, .flags = flags });
        }
    }

    const objects = try objects_list.toOwnedSlice(allocator);
    errdefer allocator.free(objects);

    // Substitution groups: version >= 12 AND act in {1,2} (recon: nAct-1U < 2).
    // version >= 18 prepends a 4-byte field before the count. Each group is a
    // 4-int tile box; version >= 13 adds a 5th "unknown" int.
    var subst_groups_list: std.ArrayListUnmanaged(SubstGroup) = .empty;
    errdefer subst_groups_list.deinit(allocator);
    if (version > 11 and act >= 1 and act <= 2) {
        if (version > 17) try r.skip(4);
        const num_groups = try r.readI32();
        var i: i32 = 0;
        while (i < num_groups) : (i += 1) {
            const x = try r.readI32();
            const y = try r.readI32();
            const gw = try r.readI32();
            const gh = try r.readI32();
            var unknown: i32 = 0;
            if (version > 12) unknown = try r.readI32();
            try subst_groups_list.append(allocator, .{ .x = x, .y = y, .w = gw, .h = gh, .unknown = unknown });
        }
    }

    // NPC paths: version >= 14. int32 numNpcs, then per NPC a { count, x, y }
    // header; when count != 0, that many path nodes follow. Each node is { x, y }
    // and, for version >= 15, an int32 action (else action = 1). The recon hangs
    // the path off the preset object sharing the (x,y); we record that index.
    var npc_paths_list: std.ArrayListUnmanaged(NpcPath) = .empty;
    errdefer {
        for (npc_paths_list.items) |np| allocator.free(np.points);
        npc_paths_list.deinit(allocator);
    }
    var npc_paths_deferred = false;
    if (version > 13) {
        if (version > 18) {
            // Outside the recon's branch coverage — parse best-effort with the
            // newest known layout but flag it so callers know it's unverified.
            npc_paths_deferred = true;
            std.debug.print("ds1: NPC-path stream version {d} > 18 not verified by recon\n", .{version});
        }
        const num_npcs = try r.readI32();
        var n: i32 = 0;
        while (n < num_npcs) : (n += 1) {
            const count = try r.readI32();
            const x = try r.readI32();
            const y = try r.readI32();
            if (count <= 0) continue;

            const points = try allocator.alloc(PathPoint, @intCast(count));
            errdefer allocator.free(points);
            for (points) |*p| {
                const px = try r.readI32();
                const py = try r.readI32();
                var action: i32 = 1;
                if (version > 14) action = try r.readI32();
                p.* = .{ .x = px, .y = py, .action = action };
            }

            // Match to a preset object by coords (recon scans preset units, which
            // are prepended — i.e. reverse object order — so we scan in reverse).
            var object_index: ?usize = null;
            var oi: usize = objects.len;
            while (oi > 0) {
                oi -= 1;
                if (objects[oi].x == x and objects[oi].y == y) {
                    object_index = oi;
                    break;
                }
            }
            try npc_paths_list.append(allocator, .{ .x = x, .y = y, .object_index = object_index, .points = points });
        }
    }

    return .{
        .allocator = allocator,
        .version = version,
        .width = @intCast(w),
        .height = @intCast(h),
        .act = act,
        .act_id = act_id,
        .wall_layers = try wall_layers_list.toOwnedSlice(allocator),
        .floor_layers = try floor_layers_list.toOwnedSlice(allocator),
        .shadow = shadow,
        .subst_tags = subst_tags,
        .objects = objects,
        .subst_groups = try subst_groups_list.toOwnedSlice(allocator),
        .npc_paths = try npc_paths_list.toOwnedSlice(allocator),
        .bytes_consumed = r.pos,
        .npc_paths_deferred = npc_paths_deferred,
    };
}

fn freeWallList(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(WallLayer)) void {
    for (list.items) |wl| {
        a.free(wl.wall);
        a.free(wl.orient);
    }
    list.deinit(a);
}

fn freeFloorList(a: std.mem.Allocator, list: *std.ArrayListUnmanaged([]Cell)) void {
    for (list.items) |fl| a.free(fl);
    list.deinit(a);
}

/// Count seed advances `DRLGPRESET_AddPresetUnitToDrlgMap` would emit for this
/// DS1's unit list. The engine gates on game classIds derived from MonPreset.txt
/// (monsters, kind=1) and gpsPresetObjectTable (objects, kind=2). Derived from
/// those tables: only act_id=1 (Act2) has qualifying units.
///   Monsters (kind=1): ds1_id ∈ {25, 26, 41, 42} → classIds {204, 205, 371, 372}
///   Objects  (kind=2): ds1_id == 44              → classId 261
pub fn countSeedAdvances(act_id: i32, objects: []const Object) u32 {
    if (act_id != 1) return 0;
    var count: u32 = 0;
    for (objects) |obj| {
        const qualifies = switch (obj.kind) {
            1 => obj.id == 25 or obj.id == 26 or obj.id == 41 or obj.id == 42,
            2 => obj.id == 44,
            else => false,
        };
        if (qualifies) count += 1;
    }
    return count;
}

const testing = std.testing;

test "parse TownETrans.ds1 fixture" {
    const bytes = @embedFile("maps/TownETrans.ds1");
    var ds1 = try parse(testing.allocator, bytes);
    defer ds1.deinit();

    std.debug.print(
        \\TownETrans.ds1 header:
        \\  version       = {d}
        \\  width         = {d} (tiles)
        \\  height        = {d} (tiles)
        \\  act           = {d}
        \\  act_id        = {d}
        \\  wall layers   = {d}
        \\  floor layers  = {d}
        \\  shadow cells  = {d}
        \\  subst tags    = {?}
        \\  objects       = {d}
        \\  npc deferred  = {}
        \\
    , .{
        ds1.version,
        ds1.width,
        ds1.height,
        ds1.act,
        ds1.act_id,
        ds1.wall_layers.len,
        ds1.floor_layers.len,
        ds1.shadow.len,
        if (ds1.subst_tags) |st| st.len else null,
        ds1.objects.len,
        ds1.npc_paths_deferred,
    });

    try testing.expect(ds1.version > 0);
    try testing.expect(ds1.width >= 1 and ds1.width <= 256);
    try testing.expect(ds1.height >= 1 and ds1.height <= 256);
    try testing.expect(ds1.wall_layers.len >= 1);
    try testing.expect(ds1.floor_layers.len >= 1);

    // Every tile layer must hold exactly (w*h) cells.
    const expect_cells = ds1.width * ds1.height;
    for (ds1.wall_layers) |wl| {
        try testing.expectEqual(@as(usize, expect_cells), wl.wall.len);
        try testing.expectEqual(@as(usize, expect_cells), wl.orient.len);
    }
    for (ds1.floor_layers) |fl| try testing.expectEqual(@as(usize, expect_cells), fl.len);
    try testing.expectEqual(@as(usize, expect_cells), ds1.shadow.len);

    // Object coords should land inside (or at the edge of) the tile grid — a
    // cheap sanity check that the object list parsed without overrun.
    for (ds1.objects) |o| {
        try testing.expect(o.x >= -1 and o.x <= @as(i32, @intCast(ds1.width)) + 1);
        try testing.expect(o.y >= -1 and o.y <= @as(i32, @intCast(ds1.height)) + 1);
    }

    // TownETrans is version 13: the recon returns at `version <= 13` (just
    // before the NPC-path stream), so it faithfully leaves a 4-byte tail — the
    // unread numNpcs field, which the file zero-fills. We assert that exact,
    // documented tail rather than force-consuming it (matching the engine).
    try testing.expectEqual(@as(i32, 13), ds1.version);
    try testing.expectEqual(bytes.len - 4, ds1.bytes_consumed);
    for (bytes[ds1.bytes_consumed..]) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expect(!ds1.npc_paths_deferred);
}

test "parse real town DS1s from every act" {
    const fixtures = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "Act1 TownN1", .bytes = @embedFile("maps/Act1_Town_TownN1.ds1") },
        .{ .name = "Act2 LutW", .bytes = @embedFile("maps/Act2_Town_LutW.ds1") },
        .{ .name = "Act3 DockTown3", .bytes = @embedFile("maps/Act3_Docktown_DockTown3.ds1") },
        .{ .name = "Act4 Fortress", .bytes = @embedFile("maps/Act4_Fort_Fortress.ds1") },
        .{ .name = "Act5 townWest", .bytes = @embedFile("maps/Expansion_Town_townWest.ds1") },
    };

    for (fixtures) |f| {
        var ds1 = parse(testing.allocator, f.bytes) catch |e| {
            std.debug.print("FAIL parsing {s}: {}\n", .{ f.name, e });
            return e;
        };
        defer ds1.deinit();

        // Structural invariants that must hold for any well-formed DS1.
        try testing.expect(ds1.version > 0 and ds1.version <= 20);
        try testing.expect(ds1.width >= 1 and ds1.width <= 256);
        try testing.expect(ds1.height >= 1 and ds1.height <= 256);
        try testing.expect(ds1.wall_layers.len >= 1 and ds1.wall_layers.len <= 4);
        try testing.expect(ds1.floor_layers.len >= 1 and ds1.floor_layers.len <= 2);

        const cells = ds1.width * ds1.height;
        for (ds1.wall_layers) |wl| {
            try testing.expectEqual(@as(usize, cells), wl.wall.len);
            try testing.expectEqual(@as(usize, cells), wl.orient.len);
        }
        for (ds1.floor_layers) |fl| try testing.expectEqual(@as(usize, cells), fl.len);
        try testing.expectEqual(@as(usize, cells), ds1.shadow.len);

        // Subst groups must parse without overrun: every box should sit inside a
        // generous tile-grid bound, and the whole file must be consumed to EOF.
        for (ds1.subst_groups) |g| {
            try testing.expect(g.x >= -1 and g.x <= @as(i32, @intCast(ds1.width)) + 1);
            try testing.expect(g.y >= -1 and g.y <= @as(i32, @intCast(ds1.height)) + 1);
        }
        try testing.expectEqual(f.bytes.len, ds1.bytes_consumed);
        try testing.expect(!ds1.npc_paths_deferred);

        var path_nodes: usize = 0;
        for (ds1.npc_paths) |np| path_nodes += np.points.len;
        std.debug.print("{s}: v{d} {d}x{d} walls={d} floors={d} objs={d} subst={d} npcPaths={d} pathNodes={d}\n", .{
            f.name,           ds1.version,         ds1.width,            ds1.height,
            ds1.wall_layers.len, ds1.floor_layers.len, ds1.objects.len, ds1.subst_groups.len,
            ds1.npc_paths.len, path_nodes,
        });
    }
}
