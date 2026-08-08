//! Which object class is which, straight out of Objects.txt.
//!
//! A client learns about objects as bare class ids: `0x51 CreateObject` carries `classId`, and
//! nothing else. Turning that into "this one is the waypoint" is a table lookup, and doing it from
//! the table rather than from a transcribed list of ids is the whole point — the six waypoint rows
//! (119, 145, 156, 157, 237, 238) are an implementation detail of the data, not of this code.

const std = @import("std");
const d2data = @import("d2-data");

/// Class ids whose Objects.txt `Name` matches `name` exactly (case-insensitive), as a bitset
/// indexed by class id. Caller owns the result.
pub fn classesNamed(alloc: std.mem.Allocator, name: []const u8) ![]bool {
    const text = d2data.file("Objects");
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return error.InvalidTable;

    var id_col: ?usize = null;
    var name_col: ?usize = null;
    {
        var cols = std.mem.splitScalar(u8, header, '\t');
        var i: usize = 0;
        while (cols.next()) |c| : (i += 1) {
            const col = std.mem.trim(u8, c, "\r");
            if (std.mem.eql(u8, col, "Id")) id_col = i;
            if (name_col == null and std.mem.eql(u8, col, "Name")) name_col = i;
        }
    }
    const idc = id_col orelse return error.InvalidTable;
    const nc = name_col orelse return error.InvalidTable;

    var out: std.ArrayListUnmanaged(bool) = .empty;
    errdefer out.deinit(alloc);
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, "\r \t").len == 0) continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        var i: usize = 0;
        var id: ?u32 = null;
        var hit = false;
        while (cols.next()) |c| : (i += 1) {
            const v = std.mem.trim(u8, c, "\r ");
            if (i == idc) id = std.fmt.parseInt(u32, v, 10) catch null;
            if (i == nc) hit = std.ascii.eqlIgnoreCase(v, name);
        }
        const cid = id orelse continue;
        const want: usize = cid + 1;
        if (out.items.len < want) try out.appendNTimes(alloc, false, want - out.items.len);
        if (hit) out.items[cid] = true;
    }
    return out.toOwnedSlice(alloc);
}

/// The waypoint object classes — one per act's art, all named "Waypoint" in Objects.txt.
pub fn waypointClasses(alloc: std.mem.Allocator) ![]bool {
    return classesNamed(alloc, "Waypoint");
}

const testing = std.testing;

test "Objects.txt names sixteen waypoint classes" {
    const wp = try waypointClasses(testing.allocator);
    defer testing.allocator.free(wp);

    // Every act has its own waypoint art, and the town and wilderness variants are separate rows
    // again — sixteen in all. Asserting the whole set (not a sample) is the point: a transcribed
    // list of "the" waypoint ids is exactly the thing this function exists to avoid.
    const expected = [_]usize{ 119, 145, 156, 157, 237, 238, 288, 323, 324, 398, 402, 429, 494, 496, 511, 539 };
    var seen: usize = 0;
    for (wp, 0..) |b, id| {
        if (!b) continue;
        seen += 1;
        try testing.expect(std.mem.indexOfScalar(usize, &expected, id) != null);
    }
    try testing.expectEqual(expected.len, seen);
}

test "a name that is not an object class matches nothing" {
    const none = try classesNamed(testing.allocator, "NotAnObjectName");
    defer testing.allocator.free(none);
    for (none) |b| try testing.expect(!b);
}
