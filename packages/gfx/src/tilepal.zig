//! Which palette a tile's texture is made with. The game has one palette on screen, the act's of
//! the level the player stands in. The act palettes agree everywhere but indices 225 to 254, each
//! act's own stretch, and a DT1 is made for the palette of the act whose folder it sits in
//! (data\global\tiles\ACT1 .. ACT4, EXPANSION for act 5). A level that lays another act's DT1 has it
//! converted with the screen palette but for the stretch, which is the DT1's act's.
//!
//! The stretches are palette data, so they come from the host (`Ramps`), as does any folder a mod
//! adds (`Folders`). Without a ramp for an act, its tiles take the screen palette.
const std = @import("std");

pub const first = 225;
pub const count = 30;
pub const acts = 6;

/// Each act's stretch, indices 225..254, R, G, B; null for an act the host has none for.
pub const Ramps = [acts]?[count][3]u8;

/// A folder name under data\global\tiles (lower case) and the act whose palette its DT1s are made
/// for.
pub const Folder = struct { name: []const u8, act: u8 };

pub const stock_folders = [_]Folder{
    .{ .name = "act1", .act = 0 },
    .{ .name = "act2", .act = 1 },
    .{ .name = "act3", .act = 2 },
    .{ .name = "act4", .act = 3 },
    .{ .name = "expansion", .act = 4 },
};

fn eqlLower(a: []const u8, w: []const u8) bool {
    if (a.len != w.len) return false;
    for (a, w) |x, y| if (std.ascii.toLower(x) != y) return false;
    return true;
}

/// The act a DT1's pixels were made for, from its path (either slash, any case): the folder after
/// the last "tiles" folder. Null for a file under no known folder.
pub fn originAct(path: []const u8, folders: []const Folder) ?u8 {
    var parts: [32][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, "\\/");
    while (it.next()) |p| {
        if (n == parts.len) break;
        parts[n] = p;
        n += 1;
    }
    if (n < 2) return null;
    // the last "tiles" that has a folder after it (not the file itself)
    var at: ?usize = null;
    for (0..n - 1) |k| {
        if (eqlLower(parts[k], "tiles") and k + 1 < n - 1) at = k + 1;
    }
    const k = at orelse return null;
    for (folders) |f| if (eqlLower(parts[k], f.name)) return f.act;
    return null;
}

/// The act whose stretch the screen palette (R, G, B per index) holds exactly.
pub fn screenAct(rgb: *const [256][3]u8, ramps: *const Ramps) ?u8 {
    for (ramps, 0..) |r, a| {
        const ramp = r orelse continue;
        var same = true;
        for (0..count) |k| {
            if (!std.mem.eql(u8, &rgb[first + k], &ramp[k])) {
                same = false;
                break;
            }
        }
        if (same) return @intCast(a);
    }
    return null;
}

/// The palette a DT1's tiles are converted with: the screen's, its stretch replaced by the DT1's
/// act's when that is another act and the host gave its ramp.
pub fn forLibrary(screen: *const [256][3]u8, path: []const u8, ramps: *const Ramps, folders: []const Folder, out: *[256][3]u8) void {
    out.* = screen.*;
    const sa = screenAct(screen, ramps) orelse return;
    const oa = originAct(path, folders) orelse return;
    if (oa == sa) return;
    const ramp = ramps[oa] orelse return;
    for (0..count) |k| out[first + k] = ramp[k];
}

test "the folder after tiles names the act" {
    const f = &stock_folders;
    try std.testing.expectEqual(@as(?u8, 1), originAct("data\\global\\tiles\\ACT2\\Outdoors\\sand.dt1", f));
    try std.testing.expectEqual(@as(?u8, 4), originAct("data/global/tiles/expansion/Town/x.dt1", f));
    try std.testing.expectEqual(@as(?u8, null), originAct("data\\global\\tiles\\x.dt1", f));
    try std.testing.expectEqual(@as(?u8, null), originAct("d2up\\tiles\\x.dt1", f));
}
