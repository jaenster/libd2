//! Golden-dump model + loader for verifying the Zig generator against the real
//! 1.14d engine. The d2gs "DRLG oracle" hook emits one JSON line per generated
//! level (evt="drlg_level"); we parse those into `Level` and diff them against
//! what our generator produces for the same seed. This is the ground-truth gate
//! for the generation pipeline — a mismatch means our port diverges from the game.

const std = @import("std");

/// Sentinel for Level.lvl_pick when the golden line carries no `lvlPick` field
/// (non-preset levels, or goldens captured before the field existed). Chosen to
/// never collide with a real nPickedFile value (0..n or -1).
pub const LVL_PICK_NONE: i32 = std.math.minInt(i32);

pub const Coords = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn eql(a: Coords, b: Coords) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
};

pub const Room = struct {
    coords: Coords = .{},
    seed: u32 = 0,
    // Room CONTENT (the deep-golden fields). For a preset room these come from the
    // engine's D2RoomExStrc/pRoomExData: `def` = the LvlPrest row id rolled for this
    // cell (preset = level's LvlPrest.Def; maze = the per-cell PickRoomPreset id),
    // `picked_file` = which File column of that LvlPrest was selected (pRoomExData[3]),
    // `n_type` (D2RoomExStrc @0x10), `n_preset_type` (@0x48: 1=maze/outdoor, 2=preset).
    // Default 0 so the coords-only seed_*.jsonl goldens and the generators that emit
    // geometry-only still construct/parse unchanged.
    def: i32 = 0,
    picked_file: i32 = 0,
    n_type: i32 = 0,
    n_preset_type: i32 = 0,
    // Adjacency (deep goldens only): `near` = DefineRoomsNear count, `adj` = the
    // adjacent room indices within the level. Owned by the parsed Level (freed in
    // Level.deinit); empty for generator-built rooms.
    near: i32 = 0,
    adj: []const i32 = &.{},
};

/// One generated level — the shape BOTH the oracle dump and our generator yield,
/// so they can be compared field-for-field.
pub const Level = struct {
    id: i32 = 0,
    drlg_type: u8 = 0, // 1=maze 2=preset 3=wilderness
    seed: u32 = 0,
    coords: Coords = .{},
    rooms: []Room = &.{},
    // Level-level preset pick (the "jail-exit variant") for PresetArea levels
    // (drlg_type==2): D2DrlgLevelDataPresetArea.nPickedFile. -1 = unresolved.
    // Defaults to a sentinel so non-preset levels / older goldens never falsely
    // mismatch; only compared when both sides carry a real value.
    lvl_pick: i32 = LVL_PICK_NONE,

    pub fn deinit(self: *Level, allocator: std.mem.Allocator) void {
        for (self.rooms) |r| if (r.adj.len > 0) allocator.free(r.adj);
        allocator.free(self.rooms);
        self.rooms = &.{};
    }
};

fn jint(obj: std.json.Value, key: []const u8) i64 {
    const v = obj.object.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn jcoords(obj: std.json.Value) Coords {
    const c = obj.object.get("coords") orelse return .{};
    if (c != .object) return .{};
    return .{
        .x = @intCast(jint(c, "x")),
        .y = @intCast(jint(c, "y")),
        .w = @intCast(jint(c, "w")),
        .h = @intCast(jint(c, "h")),
    };
}

/// Parse the oracle's JSONL (one event per line). Only "drlg_level" events are
/// returned. Caller owns the slice and must `deinit` each Level + free the slice.
pub fn parseJsonl(allocator: std.mem.Allocator, bytes: []const u8) ![]Level {
    var levels: std.ArrayListUnmanaged(Level) = .empty;
    errdefer {
        for (levels.items) |*lv| lv.deinit(allocator);
        levels.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] != '{') continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) continue;
        const evt = root.object.get("evt") orelse continue;
        if (evt != .string or !std.mem.eql(u8, evt.string, "drlg_level")) continue;

        var lv: Level = .{
            .id = @intCast(jint(root, "levelId")),
            .drlg_type = @intCast(jint(root, "drlgType")),
            .seed = @bitCast(@as(i32, @truncate(jint(root, "seed")))),
            .coords = jcoords(root),
            // Only carry a real value when the field is present (presence check, not
            // jint's 0-default — 0 is a valid pick).
            .lvl_pick = if (root.object.get("lvlPick")) |_| @intCast(jint(root, "lvlPick")) else LVL_PICK_NONE,
        };

        if (root.object.get("rooms")) |rooms_v| {
            if (rooms_v == .array) {
                var rooms = try allocator.alloc(Room, rooms_v.array.items.len);
                for (rooms_v.array.items, 0..) |rv, i| {
                    // Adjacency list (deep goldens). Owned per room; freed in deinit.
                    var adj: []i32 = &.{};
                    if (rv.object.get("adj")) |adj_v| {
                        if (adj_v == .array and adj_v.array.items.len > 0) {
                            const a = try allocator.alloc(i32, adj_v.array.items.len);
                            for (adj_v.array.items, 0..) |av, k| {
                                a[k] = switch (av) {
                                    .integer => |n| @intCast(n),
                                    else => 0,
                                };
                            }
                            adj = a;
                        }
                    }
                    rooms[i] = .{
                        .coords = .{
                            .x = @intCast(jint(rv, "x")),
                            .y = @intCast(jint(rv, "y")),
                            .w = @intCast(jint(rv, "w")),
                            .h = @intCast(jint(rv, "h")),
                        },
                        .seed = @bitCast(@as(i32, @truncate(jint(rv, "seed")))),
                        .def = @intCast(jint(rv, "def")),
                        .picked_file = @intCast(jint(rv, "pickedFile")),
                        .n_type = @intCast(jint(rv, "nType")),
                        .n_preset_type = @intCast(jint(rv, "nPresetType")),
                        .near = @intCast(jint(rv, "near")),
                        .adj = adj,
                    };
                }
                lv.rooms = rooms;
            }
        }
        try levels.append(allocator, lv);
    }
    return levels.toOwnedSlice(allocator);
}

pub const Mismatch = struct {
    field: []const u8,
    expected: i64,
    actual: i64,
};

/// Compare a generated level against the golden (oracle) level. Appends one
/// Mismatch per differing field. Returns true if they match exactly.
pub fn diff(
    allocator: std.mem.Allocator,
    golden: Level,
    actual: Level,
    out: *std.ArrayListUnmanaged(Mismatch),
) !bool {
    const before = out.items.len;
    if (golden.id != actual.id) try out.append(allocator, .{ .field = "id", .expected = golden.id, .actual = actual.id });
    if (golden.drlg_type != actual.drlg_type) try out.append(allocator, .{ .field = "drlgType", .expected = golden.drlg_type, .actual = actual.drlg_type });
    if (golden.seed != actual.seed) try out.append(allocator, .{ .field = "seed", .expected = golden.seed, .actual = actual.seed });
    if (!golden.coords.eql(actual.coords)) try out.append(allocator, .{ .field = "coords", .expected = golden.coords.x, .actual = actual.coords.x });
    if (golden.rooms.len != actual.rooms.len) {
        try out.append(allocator, .{ .field = "roomCount", .expected = @intCast(golden.rooms.len), .actual = @intCast(actual.rooms.len) });
    } else {
        for (golden.rooms, actual.rooms, 0..) |g, a, i| {
            if (!g.coords.eql(a.coords)) try out.append(allocator, .{ .field = "room.coords", .expected = @intCast(i), .actual = @intCast(i) });
        }
    }
    return out.items.len == before;
}

const testing = std.testing;

test "parse a drlg_level JSONL line into a Level" {
    const jsonl =
        \\{"evt":"other","x":1}
        \\{"evt":"drlg_level","levelId":1,"drlgType":2,"seed":305419904,"roomCount":2,"coords":{"x":100,"y":200,"w":56,"h":40},"rooms":[{"x":100,"y":200,"w":8,"h":8,"seed":7,"nType":0,"nPresetType":2,"def":301,"pickedFile":0,"near":1,"adj":[1]},{"x":108,"y":200,"w":8,"h":8,"seed":9}]}
    ;
    const levels = try parseJsonl(testing.allocator, jsonl);
    defer {
        for (levels) |*lv| lv.deinit(testing.allocator);
        testing.allocator.free(levels);
    }
    try testing.expectEqual(@as(usize, 1), levels.len);
    try testing.expectEqual(@as(i32, 1), levels[0].id);
    try testing.expectEqual(@as(u8, 2), levels[0].drlg_type);
    try testing.expectEqual(@as(i32, 56), levels[0].coords.w);
    try testing.expectEqual(@as(usize, 2), levels[0].rooms.len);
    try testing.expectEqual(@as(i32, 108), levels[0].rooms[1].coords.x);
    // Deep-golden content fields parse; absent fields default to 0.
    try testing.expectEqual(@as(i32, 301), levels[0].rooms[0].def);
    try testing.expectEqual(@as(i32, 2), levels[0].rooms[0].n_preset_type);
    try testing.expectEqual(@as(i32, 1), levels[0].rooms[0].near);
    try testing.expectEqual(@as(usize, 1), levels[0].rooms[0].adj.len);
    try testing.expectEqual(@as(i32, 1), levels[0].rooms[0].adj[0]);
    try testing.expectEqual(@as(i32, 0), levels[0].rooms[1].def);
    try testing.expectEqual(@as(usize, 0), levels[0].rooms[1].adj.len);
}

test "diff flags a roomCount mismatch and a clean match" {
    const g: Level = .{ .id = 1, .drlg_type = 2, .seed = 5, .coords = .{ .x = 1, .y = 2, .w = 3, .h = 4 } };
    var a = g;

    var ms: std.ArrayListUnmanaged(Mismatch) = .empty;
    defer ms.deinit(testing.allocator);
    try testing.expect(try diff(testing.allocator, g, a, &ms));

    a.seed = 9;
    try testing.expect(!try diff(testing.allocator, g, a, &ms));
    try testing.expectEqualStrings("seed", ms.items[0].field);
}
