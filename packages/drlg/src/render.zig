//! Text rendering of a parsed map. A DS1 cell is "present" when its low 24 bits
//! (tile main/sub index + orientation) are non-zero; an all-zero cell is empty.
//! This is a coarse floor/wall/object view — enough to eyeball a layout and to
//! diff structurally. Tile-accurate (per-dt1 graphics) rendering comes later.

const std = @import("std");
const ds1 = @import("ds1.zig");

fn present(c: ds1.Cell) bool {
    return (c.raw & 0x00ff_ffff) != 0;
}

fn anyPresent(layers: []const []ds1.Cell, i: usize) bool {
    for (layers) |layer| {
        if (i < layer.len and present(layer[i])) return true;
    }
    return false;
}

/// Render a DS1 to an ASCII grid: '#' wall, '.' floor, 'o' object, ' ' empty.
/// One char per tile cell, row-major (y outer, x inner). Caller frees the result.
pub fn asciiMap(d: *const ds1.Ds1, allocator: std.mem.Allocator) ![]u8 {
    const width = d.width;
    const height = d.height;

    var wall_slices: [4][]ds1.Cell = undefined;
    for (d.wall_layers, 0..) |wl, k| wall_slices[k] = wl.wall;
    const walls = wall_slices[0..d.wall_layers.len];

    var obj_at = try allocator.alloc(bool, width * height);
    defer allocator.free(obj_at);
    @memset(obj_at, false);
    for (d.objects) |o| {
        if (o.x >= 0 and o.y >= 0 and o.x < @as(i32, @intCast(width)) and o.y < @as(i32, @intCast(height))) {
            obj_at[@as(usize, @intCast(o.y)) * width + @as(usize, @intCast(o.x))] = true;
        }
    }

    // (width + 1) chars per row including the trailing newline.
    var out = try allocator.alloc(u8, (width + 1) * height);
    var p: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const i = y * width + x;
            out[p] = if (obj_at[i])
                'o'
            else if (anyPresent(walls, i))
                '#'
            else if (anyPresent(d.floor_layers, i))
                '.'
            else
                ' ';
            p += 1;
        }
        out[p] = '\n';
        p += 1;
    }
    return out;
}

const testing = std.testing;

test "asciiMap renders a town DS1 without overrun" {
    const bytes = @embedFile("maps/Act1_Town_TownN1.ds1");
    var d = try ds1.parse(testing.allocator, bytes);
    defer d.deinit();

    const map = try asciiMap(&d, testing.allocator);
    defer testing.allocator.free(map);

    try testing.expectEqual((d.width + 1) * d.height, map.len);
    try testing.expect(std.mem.indexOfScalar(u8, map, '.') != null); // town has floor
}
