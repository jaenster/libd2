//! Golden tests: the seeded 1.14d characters, described. The expected text is what the game's tooltip
//! shows for these records (names from the string tables, lines in descending priority, the engine's
//! wording for grouped and per-class stats).

const std = @import("std");
const save = @import("lib.zig");
const itemtext = save.describe.itemtext;

const sorc_bytes = @embedFile("testdata/seed/EpicSorc.d2s");
const ama_bytes = @embedFile("testdata/seed/EpicAma.d2s");

const Ctx = struct {
    arena: std.heap.ArenaAllocator,
    d: itemtext.Describer,
    views: []itemtext.ItemView,

    fn init(bytes: []const u8) !*Ctx {
        const c = try std.testing.allocator.create(Ctx);
        errdefer std.testing.allocator.destroy(c);
        c.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer c.arena.deinit();
        c.d = try itemtext.Describer.init(std.testing.allocator);
        errdefer c.d.deinit();
        const s = try save.parse(bytes);
        c.views = try save.describe.describePlayerItems(&c.d, c.arena.allocator(), s, null);
        return c;
    }
    fn deinit(c: *Ctx) void {
        c.d.deinit();
        c.arena.deinit();
        std.testing.allocator.destroy(c);
    }
    fn at(c: *const Ctx, place: itemtext.Place, page: ?u8, x: u16, y: u16) !*const itemtext.ItemView {
        for (c.views) |*v| {
            if (v.location.place == place and v.location.page == page and v.location.x == x and v.location.y == y) return v;
        }
        return error.NoSuchItem;
    }
    fn equipped(c: *const Ctx, body: u8) !*const itemtext.ItemView {
        for (c.views) |*v| if (v.location.place == .equipped and v.location.body_loc == body) return v;
        return error.NoSuchItem;
    }
};

fn expectLines(v: *const itemtext.ItemView, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, v.lines.len);
    for (want, v.lines) |w, l| try std.testing.expectEqualStrings(w, l.text);
}

test "every record of both saves is described and nothing is lost" {
    for ([_][]const u8{ sorc_bytes, ama_bytes }) |bytes| {
        const c = try Ctx.init(bytes);
        defer c.deinit();
        const s = try save.parse(bytes);
        var n: usize = 0;
        var it = s.items.iterator();
        while (it.next()) |_| n += 1;
        var shown: usize = c.views.len;
        for (c.views) |v| shown += v.socketed.len;
        try std.testing.expectEqual(n, shown);
        for (c.views) |v| try std.testing.expect(v.name.len != 0 and v.invfile.len != 0);
    }
}

test "a runeword, personalised, with its runes in the sockets (stash page 0,0)" {
    const c = try Ctx.init(sorc_bytes);
    defer c.deinit();
    const v = try c.at(.grid, 4, 0, 0);
    try std.testing.expectEqualStrings("SilverDeth-II's Enigma", v.name);
    try std.testing.expectEqualStrings("Enigma", v.runeword.?);
    try std.testing.expectEqualStrings("Archon Plate", v.base_name);
    try std.testing.expectEqualStrings("invltp", v.invfile);
    try std.testing.expectEqual(@as(u8, 2), v.location.w);
    try std.testing.expectEqual(@as(u8, 3), v.location.h);
    try std.testing.expectEqual(itemtext.Color.gold, v.color);
    try std.testing.expectEqual(@as(u8, 3), v.sockets);
    try std.testing.expectEqual(@as(usize, 3), v.socketed.len);
    try std.testing.expectEqualStrings("Jah Rune", v.socketed[0].name);
    try std.testing.expectEqualStrings("Ith Rune", v.socketed[1].name);
    try std.testing.expectEqualStrings("Ber Rune", v.socketed[2].name);
    try expectLines(v, &.{
        "Defense: 1373",
        "Required Strength: 103",
        "Required Level: 65",
        "+2 to All Skills",
        "+45% Faster Run/Walk",
        "+1 to Teleport",
        "+15% Enhanced Defense",
        "+775 Defense",
        "+74 to Strength (Based on Character Level)",
        "+14 Life after each Kill",
        "99% Better Chance of Getting Magic Items (Based on Character Level)",
        "Increase Maximum Durability 10%",
        "Socketed (3)",
    });
}

test "a unique with grouped stats: Annihilus (inventory 6,3)" {
    const c = try Ctx.init(sorc_bytes);
    defer c.deinit();
    const v = try c.at(.grid, 0, 6, 3);
    try std.testing.expectEqualStrings("Annihilus", v.name);
    try std.testing.expectEqualStrings("Small Charm", v.base_name);
    try std.testing.expectEqualStrings("invmss", v.invfile); // its own picture, not the base charm's
    try std.testing.expectEqual(itemtext.Color.gold, v.color);
    try expectLines(v, &.{
        "Required Level: 70",
        "+1 to All Skills",
        "+20 to all Attributes",
        "All Resistances +20",
        "+10% to Experience Gained",
    });
}

test "a magic charm: prefix and suffix, class skill tab (inventory 3,0)" {
    const c = try Ctx.init(sorc_bytes);
    defer c.deinit();
    const v = try c.at(.grid, 0, 3, 0);
    try std.testing.expectEqualStrings("Sparking Grand Charm of Sustenance", v.name);
    try std.testing.expectEqualStrings("Grand Charm", v.base_name);
    try std.testing.expectEqual(itemtext.Color.blue, v.color);
    try std.testing.expectEqual(@as(u8, 3), v.location.h);
    try expectLines(v, &.{ "Required Level: 53", "+1 to Lightning Skills (Sorceress Only)", "+34 to Life" });
}

test "crafted and rare names come from the rare word tables (equipped)" {
    const c = try Ctx.init(sorc_bytes);
    defer c.deinit();
    const ring = try c.equipped(6);
    try std.testing.expectEqualStrings("Ghoul Master", ring.name);
    try std.testing.expectEqual(itemtext.Color.orange, ring.color);
    try expectLines(ring, &.{
        "+10% Faster Cast Rate",
        "+19 to Attack Rating",
        "3% Life stolen per hit",
        "+5 to Strength",
        "+16 to Life",
        "Cold Resist +24%",
        "Poison Resist +26%",
    });
    const amu = try c.equipped(2);
    try std.testing.expectEqualStrings("Shadow Wing", amu.name);
    try std.testing.expectEqual(itemtext.Color.orange, amu.color);
    const boots = try c.equipped(9);
    try std.testing.expectEqualStrings("Spirit Greaves", boots.name);
    try std.testing.expectEqualStrings("Scarabshell Boots", boots.base_name);
    try std.testing.expectEqual(itemtext.Color.yellow, boots.color);
}

test "a socketed unique shows its jewel and the jewel's own properties" {
    const c = try Ctx.init(sorc_bytes);
    defer c.deinit();
    const v = try c.equipped(1);
    try std.testing.expectEqualStrings("Griffon's Eye", v.name);
    try std.testing.expectEqualStrings("Diadem", v.base_name);
    try std.testing.expectEqual(@as(u8, 1), v.sockets);
    try std.testing.expectEqual(@as(usize, 1), v.socketed.len);
    try std.testing.expectEqualStrings("Rainbow Facet", v.socketed[0].name);
    try std.testing.expectEqual(itemtext.Quality.unique, v.socketed[0].quality);
    // the jewel's properties are part of the host's list too
    var found = false;
    for (v.lines) |l| if (std.mem.eql(u8, l.text, "-5% to Enemy Fire Resistance")) {
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("Socketed (1)", v.lines[v.lines.len - 1].text);
}

test "an ethereal unique, and a javelin's damage, quantity and class skill lines (Amazon)" {
    const c = try Ctx.init(ama_bytes);
    defer c.deinit();
    const boots = try c.equipped(9);
    try std.testing.expectEqualStrings("Sandstorm Trek", boots.name);
    try std.testing.expect(boots.ethereal);
    try expectLines(boots, &.{
        "Defense: 267",
        "Required Strength: 91",
        "Required Level: 64",
        "Ethereal (Cannot be Repaired)",
        "+20% Faster Run/Walk",
        "+20% Faster Hit Recovery",
        "+170% Enhanced Defense",
        "+15 to Strength",
        "+15 to Vitality",
        "+91 Maximum Stamina (Based on Character Level)",
        "50% Slower Stamina Drain",
        "Poison Resist +70%",
        "Repairs 1 Durability In 20 Seconds",
    });
    const jav = try c.at(.grid, 4, 0, 0);
    try std.testing.expectEqualStrings("Thunderstroke", jav.name);
    try std.testing.expectEqual(@as(u16, 44), jav.quantity);
    try expectLines(jav, &.{
        "One-Hand Damage: 90 to 162",
        "Throw Damage: 105 to 198",
        "Quantity: 44",
        "Required Dexterity: 151",
        "Required Strength: 107",
        "Required Level: 69",
        "20% Chance to cast level 14 Lightning on striking",
        "+4 to Javelin and Spear Skills (Amazon Only)",
        "+15% Increased Attack Speed",
        "+200% Enhanced Damage",
        "Adds 1-511 lightning damage",
        "-15% to Enemy Lightning Resistance",
        "+3 to Lightning Bolt (Amazon Only)",
    });
}

test "a loose gem lists what it adds to each kind of item" {
    const c = try Ctx.init(sorc_bytes);
    defer c.deinit();
    const v = try c.at(.grid, 0, 2, 0);
    try std.testing.expectEqualStrings("Topaz", v.name);
    try expectLines(v, &.{
        "Required Level: 12",
        "Weapons: Adds 1-22 lightning damage",
        "Armor: 16% Better Chance of Getting Magic Items",
        "Shields: Lightning Resist +22%",
    });
}

test "positions: stash page, belt column, cube size" {
    const c = try Ctx.init(sorc_bytes);
    defer c.deinit();
    const cube = try c.at(.grid, 4, 4, 0);
    try std.testing.expectEqualStrings("Horadric Cube", cube.name);
    try std.testing.expectEqual(@as(u8, 2), cube.location.w);
    try std.testing.expectEqual(@as(u8, 2), cube.location.h);
    const rejuv = try c.at(.belt, null, 3, 0);
    try std.testing.expectEqualStrings("Full Rejuvenation Potion", rejuv.name);
}
