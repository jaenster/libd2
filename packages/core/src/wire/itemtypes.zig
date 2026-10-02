//! Item base-code classification (armor / weapon / misc + stackable), extracted from 1.14d
//! Armor.txt / Weapons.txt / Misc.txt. The item bit-stream decoder needs this to consume the
//! base-type-dependent fixed fields (armorclass, durability, stackable quantity) before the
//! stat list — getting the category wrong desyncs the bitstream. See docs/re/sc-packets.md.

const std = @import("std");
const d2data = @import("d2-data");

const raw = @embedFile("data/itemtypes.tsv");

pub const Cat = enum { armor, weapon, misc };
pub const Type = struct { cat: Cat, stackable: bool };

const Entry = struct { code: [4]u8, cat: Cat, stackable: bool };

const MAX = 1024;

const Parsed = struct { items: [MAX]Entry, len: usize };

const parsed: Parsed = build: {
    @setEvalBranchQuota(4_000_000);
    var out: [MAX]Entry = undefined;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (line.len == 0 or n >= MAX) continue;
        var it = std.mem.splitScalar(u8, line, '\t');
        const code = it.next() orelse continue;
        const cat_s = it.next() orelse continue;
        const stk_s = it.next() orelse continue;
        if (code.len == 0 or code.len > 4) continue;
        var c = [_]u8{0} ** 4;
        for (code, 0..) |ch, i| c[i] = ch;
        out[n] = .{
            .code = c,
            .cat = switch (cat_s[0]) {
                'a' => .armor,
                'w' => .weapon,
                else => .misc,
            },
            .stackable = stk_s.len > 0 and stk_s[0] == '1',
        };
        n += 1;
    }
    break :build .{ .items = out, .len = n };
};

pub const entries: []const Entry = parsed.items[0..parsed.len];

/// The base items read from the game's own Armor, Weapons and Misc tables by `install`; null means the embedded stock ones.
var installed: ?[]const Entry = null;

pub fn lookup(code: []const u8) ?Type {
    for (installed orelse entries) |e| {
        const elen = std.mem.indexOfScalar(u8, &e.code, 0) orelse 4;
        if (std.mem.eql(u8, e.code[0..elen], code)) return .{ .cat = e.cat, .stackable = e.stackable };
    }
    return null;
}

test "classification matches base tables" {
    try std.testing.expectEqual(Cat.weapon, lookup("jav").?.cat);
    try std.testing.expect(lookup("jav").?.stackable); // javelins stack
    try std.testing.expectEqual(Cat.armor, lookup("hbl").?.cat); // leather boots
    try std.testing.expectEqual(Cat.misc, lookup("cm3").?.cat); // grand charm
    try std.testing.expect(lookup("aqv").?.stackable); // arrows stack
    try std.testing.expect(lookup("zzz") == null);
}

/// The base items of the Armor.txt, Weapons.txt and Misc.txt the data package holds now (`d2data.setOverride`): a program
/// that plays a modified game supplies its own tables there, calls this once at start, and the decoder then knows every
/// base item those tables have. The list lives for the rest of the process. Not thread safe against readers.
pub fn install(gpa: std.mem.Allocator) !void {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(gpa);
    inline for (.{ .{ "Armor", Cat.armor }, .{ "Weapons", Cat.weapon }, .{ "Misc", Cat.misc } }) |t| {
        var tbl = try d2data.tsv.parse(gpa, d2data.raw(t[0]).?);
        defer tbl.deinit();
        for (0..tbl.rowCount()) |row| {
            const code = tbl.get(row, "code");
            if (code.len == 0 or code.len > 4) continue;
            var c = [_]u8{0} ** 4;
            @memcpy(c[0..code.len], code);
            try list.append(gpa, .{ .code = c, .cat = t[1], .stackable = std.mem.eql(u8, tbl.get(row, "stackable"), "1") });
        }
    }
    installed = try list.toOwnedSlice(gpa);
}

/// Back to the embedded stock base items.
pub fn uninstall() void {
    installed = null;
}

test "the base items read from the game's tables are the embedded ones" {
    const gpa = std.testing.allocator;
    try install(gpa);
    defer {
        gpa.free(installed.?);
        uninstall();
    }
    try std.testing.expectEqual(entries.len, installed.?.len);
    for (entries) |e| {
        const elen = std.mem.indexOfScalar(u8, &e.code, 0) orelse 4;
        const got = lookup(e.code[0..elen]).?;
        try std.testing.expectEqual(e.cat, got.cat);
        try std.testing.expectEqual(e.stackable, got.stackable);
    }
}

test "a base item the supplied Misc table adds is known once installed, and not before" {
    const gpa = std.testing.allocator;
    const stock = d2data.raw("Misc").?;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, std.mem.trimEnd(u8, stock, "\r\n"));
    try text.append(gpa, '\n');
    var cols = std.mem.splitScalar(u8, std.mem.trimEnd(u8, stock[0..std.mem.indexOfScalar(u8, stock, '\n').?], "\r"), '\t');
    var first = true;
    while (cols.next()) |name| {
        if (!first) try text.append(gpa, '\t');
        first = false;
        try text.appendSlice(gpa, if (std.mem.eql(u8, name, "code")) "tst" else if (std.mem.eql(u8, name, "stackable")) "1" else "");
    }
    try text.append(gpa, '\n');
    try d2data.setOverride("Misc", text.items);
    defer d2data.clearOverrides();
    try std.testing.expect(lookup("tst") == null);
    try install(gpa);
    defer {
        gpa.free(installed.?);
        uninstall();
    }
    try std.testing.expectEqual(Cat.misc, lookup("tst").?.cat);
    try std.testing.expect(lookup("tst").?.stackable);
    try std.testing.expect(lookup("jav").?.stackable);
}
