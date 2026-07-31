//! Item base-code classification (armor / weapon / misc + stackable), extracted from 1.14d
//! Armor.txt / Weapons.txt / Misc.txt. The item bit-stream decoder needs this to consume the
//! base-type-dependent fixed fields (armorclass, durability, stackable quantity) before the
//! stat list — getting the category wrong desyncs the bitstream. See docs/re/sc-packets.md.

const std = @import("std");

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

pub fn lookup(code: []const u8) ?Type {
    for (entries) |e| {
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
