//! The roll ranges after the stat lines (d2-item ranges.zig), per kind of item, on items the character kit makes.
//! A kit item has every value at its best unless `nomax`, which makes the expected ranges exact to write down.
const std = @import("std");
const item = @import("d2-item");
const save = @import("d2-save");
const itemdesc = item.itemdesc;

const testing = std.testing;

const Fixture = struct {
    t: item.Tables,
    s: item.strings.Strings,
    d: itemdesc.Describer,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture) !void {
        f.t = try item.Tables.load(testing.allocator);
        f.s = try item.strings.Strings.load(testing.allocator);
        f.d = try itemdesc.Describer.init(testing.allocator, &f.t, &f.s);
        f.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.d.deinit();
        f.s.deinit();
        f.t.deinit();
    }

    /// The engine string of a kit item, colour codes and all.
    fn raw(f: *Fixture, kit: []const u8, scope: save.kititem.Scope, version0: bool, style: itemdesc.range.Style) ![]const u8 {
        var maker = try save.kititem.Maker.init(testing.allocator, scope, 1);
        defer maker.deinit();
        if (version0) maker.version = 0;
        var made = try maker.makeKit(kit);
        defer made.deinit(testing.allocator);
        const a = f.arena.allocator();
        const recs = try itemdesc.parseRecords(a, try a.dupe(u8, made.rec), 16);
        const desc = try f.d.describe(a, &recs[0], recs[1..], .{ .ranges = style });
        return desc.text;
    }

    fn plain(f: *Fixture, kit: []const u8, scope: save.kititem.Scope, version0: bool, style: itemdesc.range.Style) ![]const u8 {
        var maker = try save.kititem.Maker.init(testing.allocator, scope, 1);
        defer maker.deinit();
        if (version0) maker.version = 0;
        var made = try maker.makeKit(kit);
        defer made.deinit(testing.allocator);
        const a = f.arena.allocator();
        const recs = try itemdesc.parseRecords(a, try a.dupe(u8, made.rec), 16);
        return itemdesc.plain(a, try f.d.describe(a, &recs[0], recs[1..], .{ .ranges = style }));
    }
};

fn expectLine(text: []const u8, line: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) return;
    std.debug.print("no line \"{s}\" in:\n{s}\n", .{ line, text });
    return error.TestExpectedEqual;
}

test "ranges off: the tooltip is the engine's" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.plain("unique:Harlequin Crest", .expansion, false, .off);
    try expectLine(t, "Defense: 141");
    try expectLine(t, "+2 to All Skills");
}

test "a unique: its row's ranges, fixed values as one number, the base defense range" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.plain("unique:Harlequin Crest", .expansion, false, .grey);
    try expectLine(t, "Defense: 141 [98-141]");
    try expectLine(t, "+2 to All Skills [2]");
    try expectLine(t, "Damage Reduced by 10% [10]");
    // a per-level stat shows what the character's level makes of it: no row range
    try expectLine(t, "+148 to Life (Based on Character Level)");
    const s = try f.plain("unique:The Stone of Jordan", .expansion, false, .grey);
    try expectLine(s, "Adds 1-12 lightning damage [1-12]");
    try expectLine(s, "Increase Maximum Mana 25% [25]");
}

test "a rare: each affix's range, a value with a shift (mana) in the line's own units" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.plain("rare:amu;prefix=Summoner's,Prismatic,Great Wyrm's;suffix=of Perfection,of the Apprentice", .expansion, false, .grey);
    try expectLine(t, "All Resistances +20 [16-20]");
    try expectLine(t, "+90 to Mana [61-90]");
    try expectLine(t, "+20 to Dexterity [16-20]");
    try expectLine(t, "+1 to Necromancer Skill Levels [1]");
}

test "a set item: its own lines, and a flat defense on top of the base range" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.plain("set:Tal Rasha's Howling Wind", .expansion, false, .grey);
    try expectLine(t, "Defense: 941 [833-941]");
    try expectLine(t, "+400 Defense [400]");
    try expectLine(t, "Requirements -60% [-60]");
}

test "a runeword: the Runes.txt row's ranges" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.plain("base:crs;runeword=Spirit", .expansion, false, .grey);
    try expectLine(t, "+35% Faster Cast Rate [25-35]");
    try expectLine(t, "+112 to Mana [89-112]");
    try expectLine(t, "Adds 1-50 lightning damage [1-50]");
}

test "rolled: fixed lines stay as they are, a value at the top of its range is gold" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = try f.plain("base:crs;runeword=Spirit", .expansion, false, .rolled);
    try expectLine(t, "+2 to All Skills");
    try expectLine(t, "+35% Faster Cast Rate [25-35]");
    const r = try f.raw("base:crs;runeword=Spirit", .expansion, false, .rolled);
    try testing.expect(std.mem.indexOf(u8, r, "\xc3\xbfc4[25-35]\xc3\xbfc3") != null);
}

test "a pre-patch rare ends one below the row's max, and a value outside a range shows none" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // the kit rolls the top of the row, which 1.06 never reached: nothing could have made it, so no range is claimed
    const t = try f.plain("rare:rin;prefix=Ruby,Meteoric;suffix=of Precision,of the Apprentice", .classic, true, .grey);
    try expectLine(t, "Fire Resist +50%");
    try expectLine(t, "+10% Faster Cast Rate [10]");
    const n = try f.plain("rare:rin;prefix=Ruby,Meteoric;suffix=of Precision,of the Apprentice", .classic, false, .grey);
    try expectLine(n, "Fire Resist +50% [31-50]");
}
