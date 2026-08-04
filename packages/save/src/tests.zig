//! Correctness gate for the `.d2s` codec: parse a real 1.14d save, re-emit it, and require
//! the output to be byte-identical to the input. The fixture is embedded so the suite is
//! hermetic (no filesystem, wasm-clean).

const std = @import("std");
const save = @import("lib.zig");

const EPIC_SORC = @embedFile("testdata/EpicSorc.d2s");

test "fixture is a valid 1.14d save" {
    try std.testing.expect(save.validate(EPIC_SORC));
    const h = save.header.parseHeader(EPIC_SORC) orelse return error.NoHeader;
    try std.testing.expectEqualStrings("EpicSorc", h.nameSlice());
    try std.testing.expectEqual(@as(u32, save.header.version_114d), h.version);
    try std.testing.expectEqual(@as(u32, EPIC_SORC.len), h.file_size);
}

test "parse decodes every section of a real save" {
    const s = try save.parse(EPIC_SORC);

    // Section sizes are fixed, so the decoded offsets must add back up to the file length.
    try std.testing.expectEqual(@as(usize, EPIC_SORC.len), s.byteLen());

    const a = s.attributes.attributes();
    try std.testing.expectEqual(@as(u32, 88), a.strength);
    try std.testing.expectEqual(@as(u32, 35), a.energy);
    try std.testing.expectEqual(@as(u32, 25), a.dexterity);
    try std.testing.expectEqual(@as(u32, 397), a.vitality);
    try std.testing.expectEqual(@as(u32, 99), a.level);
    try std.testing.expectEqual(@as(u32, 3520485254), a.experience);
    try std.testing.expectEqual(@as(u32, 148), a.gold);
    try std.testing.expectEqual(@as(u32, 2088168), a.goldbank);
    // maxhp is 8.8 fixed point in the stream.
    try std.testing.expectEqual(@as(u32, 251392 >> 8), a.maxhp);

    try std.testing.expectEqual(@as(u32, 1), s.waypoints.version);
    try std.testing.expectEqual(@as(u16, 80), s.waypoints.size);
    try std.testing.expect(s.waypoints.isSet(.normal, 0)); // Rogue Encampment
    try std.testing.expect(s.waypoints.isSet(.hell, 0));

    // The skill section carries 30 class-relative skill levels.
    try std.testing.expectEqual(@as(usize, 30), s.skills.levels.len);

    // The item tail starts at the player list header and the count is sane.
    try std.testing.expect(s.items.playerCount() > 0);
    var it = s.items.iterator();
    var seen: usize = 0;
    while (it.next()) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, s.items.playerCount()), seen);
}

test "parse then write is byte-identical to the source save" {
    const s = try save.parse(EPIC_SORC);
    var buf: [EPIC_SORC.len]u8 = undefined;
    const out = try s.writeInto(&buf);
    try std.testing.expectEqualSlices(u8, EPIC_SORC, out);
}

test "an edited save stays valid and re-parses with the edit" {
    var s = try save.parse(EPIC_SORC);
    s.attributes.setRaw(14, 12345); // gold
    s.waypoints.set(.nightmare, 17, true);

    var buf: [EPIC_SORC.len + 64]u8 = undefined;
    const out = try s.writeInto(&buf);
    try std.testing.expect(save.validate(out));

    const back = try save.parse(out);
    try std.testing.expectEqual(@as(u32, 12345), back.attributes.attributes().gold);
    try std.testing.expect(back.waypoints.isSet(.nightmare, 17));
    try std.testing.expectEqualSlices(u8, EPIC_SORC[0x14..0x24], &back.header.name);
}

test "parse rejects a header-only save and a corrupt signature" {
    var fresh: [save.header.header_size]u8 = undefined;
    try std.testing.expect(save.newSave(&fresh, "Freshie", 1, 0x20, 0));
    try std.testing.expectError(error.BadQuestMarker, save.parse(&fresh));

    var bad = [_]u8{0} ** save.header.header_size;
    try std.testing.expectError(error.BadSignature, save.parse(&bad));
    try std.testing.expectError(error.TooShort, save.parse(bad[0..16]));
}
