//! Converting a whole `.d2s` between the pre-1.09 and modern layouts.
//!
//! `formats.d2s` converts the header; this does the body. What can be converted, and what cannot,
//! is a property of the format rather than of how much effort went in:
//!
//!   quests      identical, copied straight across
//!   waypoints   the same six lead bytes and the same three blocks; the modern section has one
//!               trailing byte the old one does not
//!   attributes  a real re-encode — 16-bit bitmap plus i32 values one way, 9-bit id plus a
//!               per-stat width the other. Same sixteen stats and the same units, so this is exact
//!   skills      one byte per level either way; the count differs (class-sized vs a fixed 30)
//!   npc intros  NOT converted, see below
//!   items       NOT convertible, see below
//!
//! **Items are refused across the boundary, and that is the engine's own position.** The old
//! loader passes the save's VERSION as the format selector — `PLRSAVE_DispatchItemLoadByFormat`
//! (Game.exe 0x005337f0) is handed the version out of the header — so the item bit-layout is
//! era-specific by construction. Carrying the bytes over would produce a file that parses and
//! decodes to different items, which is worse than refusing.
//!
//! **NPC intros are left at their defaults.** The old section body is 50 bytes and the modern one
//! 49, and neither is field-decoded here. There is no honest mapping between two opaque blobs of
//! different lengths, and inventing one silently loses or fabricates "have I met this NPC" state.

const std = @import("std");
const formats = @import("d2-formats");
const sections = @import("sections.zig");
const old_sections = @import("old_sections.zig");
const attributes = @import("attributes.zig");

pub const d2s = formats.d2s;

pub const ConvertError = error{
    /// The save carries items, and item encoding is selected by save version.
    ItemsNotConvertible,
    /// A stat value does not fit the modern stream's width for that stat. The old format stores
    /// every stat as a full i32, so a value legal there can be unrepresentable here.
    ValueTooWide,
    /// A stat value is negative. The modern stream is unsigned per-stat.
    ValueNegative,
};

/// True when a save's items may be carried between these two versions unchanged — i.e. when they
/// are on the same side of the 0x5c boundary and so use the same item format.
pub fn itemsCompatible(from_version: u32, to_version: u32) bool {
    return d2s.era(from_version) == d2s.era(to_version);
}

/// Convert a pre-1.09 save to the modern layout, stamped with `target_version` (0x5c or later).
///
/// `items` is what the caller has decided to put in the result. Passing the source's own bytes is
/// refused unless the versions share an era — see the file comment.
pub fn oldToModern(o: *const old_sections.Save, target_version: u32, items: []const u8) ConvertError!sections.Save {
    if (items.len != 0 and !itemsCompatible(o.header.version, target_version)) return error.ItemsNotConvertible;

    var m = sections.Save{};
    m.header = d2s.oldToModern(&o.header, target_version);
    m.quests = o.quests;

    @memcpy(m.waypoints.blocks[0..], o.waypoints.blocks[0..]);
    m.waypoints.version = std.mem.readInt(u32, o.waypoints.head[0..4], .little);
    m.waypoints.size = std.mem.readInt(u16, o.waypoints.head[4..6], .little);
    // The trailing byte has no source in the old section; the engine writes zero here.
    m.waypoints.tail = 0;

    for (0..old_sections.attribute_stat_count) |stat| {
        const id: u8 = @intCast(stat);
        if (!o.attributes.has(@intCast(stat))) continue;
        const v = o.attributes.values[stat];
        if (v < 0) return error.ValueNegative;
        const raw: u32 = @intCast(v);
        // ATTR_BITS is u6 because 32 is a legal width; a 32-bit stat has no ceiling to test.
        const width: u6 = attributes.ATTR_BITS[id];
        if (width < 32 and raw >= (@as(u32, 1) << @intCast(width))) return error.ValueTooWide;
        m.attributes.setRaw(id, raw);
    }

    const n = @min(o.skills.len, m.skills.levels.len);
    @memcpy(m.skills.levels[0..n], o.skills.slice()[0..n]);

    m.items = .{ .bytes = items };
    return m;
}

/// Convert a modern save to the pre-1.09 layout, stamped with `target_version` (below 0x5c).
///
/// `txt_skills_count` is the Skills.txt row count of the TARGET build and `class_skill_count` the
/// number of skills the character's class has there — both are properties of the build being
/// written for, not of the save, and the engine bounds-checks the first against its own table.
pub fn modernToOld(
    m: *const sections.Save,
    target_version: u32,
    txt_skills_count: u16,
    class_skill_count: u8,
    items: []const u8,
) ConvertError!old_sections.Save {
    if (items.len != 0 and !itemsCompatible(m.header.version, target_version)) return error.ItemsNotConvertible;

    var o = old_sections.Save{};
    o.header = d2s.modernToOld(&m.header, target_version, txt_skills_count);
    o.quests = m.quests;

    std.mem.writeInt(u32, o.waypoints.head[0..4], m.waypoints.version, .little);
    std.mem.writeInt(u16, o.waypoints.head[4..6], m.waypoints.size, .little);
    @memcpy(o.waypoints.blocks[0..], m.waypoints.blocks[0..]);
    // m.waypoints.tail is dropped: the old section has nowhere to put it.

    for (m.attributes.slice()) |e| {
        if (e.id >= old_sections.attribute_stat_count) continue;
        o.attributes.present |= @as(u16, 1) << @intCast(e.id);
        o.attributes.values[e.id] = @intCast(e.raw);
    }

    o.skills.len = @min(class_skill_count, @as(u8, @intCast(o.skills.levels.len)));
    const n = @min(@as(usize, o.skills.len), m.skills.levels.len);
    @memcpy(o.skills.levels[0..n], m.skills.levels[0..n]);

    o.items = .{ .bytes = items };
    return o;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn sampleOld() old_sections.Save {
    var o = old_sections.Save{};
    o.header.version = 0x57;
    o.header.class = 1;
    o.header.flags = formats.d2s.old.flag_expansion | formats.d2s.old.flag_hardcore | (@as(u32, 7) << 8);
    o.header.difficulty = 0x13; // act 3, difficulty 1
    @memcpy(o.header.name[0.."Sorc".len], "Sorc");
    o.quests.head = .{ 6, 0, 0, 0, 0x2a, 1 };
    o.quests.blocks[1][5] = 0xAB;
    o.waypoints.head = .{ 1, 0, 0, 0, 0x50, 0 };
    o.waypoints.blocks[2][3] = 0x7f;
    o.attributes.present = 0b0000_0000_0100_1101; // stats 0, 2, 3, 6
    o.attributes.values[0] = 30;
    o.attributes.values[2] = 25;
    o.attributes.values[3] = 20;
    o.attributes.values[6] = 1234;
    o.skills.len = 30;
    for (0..30) |i| o.skills.levels[i] = @intCast(i % 7);
    return o;
}

test "old -> modern -> old keeps every section the two formats share" {
    const o = sampleOld();
    const m = try oldToModern(&o, d2s.version_114d, &.{});
    const back = try modernToOld(&m, 0x57, 319, 30, &.{});

    try testing.expectEqualStrings("Sorc", back.header.nameSlice());
    try testing.expectEqual(o.header.class, back.header.class);
    try testing.expectEqual(o.header.difficulty, back.header.difficulty);
    try testing.expectEqual(o.quests.head, back.quests.head);
    try testing.expectEqual(o.quests.blocks, back.quests.blocks);
    try testing.expectEqual(o.waypoints.head, back.waypoints.head);
    try testing.expectEqual(o.waypoints.blocks, back.waypoints.blocks);
    try testing.expectEqual(o.attributes.present, back.attributes.present);
    for (0..old_sections.attribute_stat_count) |i| {
        try testing.expectEqual(o.attributes.get(@intCast(i)), back.attributes.get(@intCast(i)));
    }
    try testing.expectEqualSlices(u8, o.skills.slice(), back.skills.slice());
}

test "the attribute re-encode is exact, not a copy" {
    const o = sampleOld();
    const m = try oldToModern(&o, d2s.version_114d, &.{});
    // Same stats, now as 9-bit ids with per-stat widths.
    try testing.expectEqual(@as(u8, 4), m.attributes.count);
    try testing.expectEqual(@as(u32, 30), m.attributes.raw(0));
    try testing.expectEqual(@as(u32, 25), m.attributes.raw(2));
    try testing.expectEqual(@as(u32, 1234), m.attributes.raw(6));
    // Ascending id order, which is what the engine writes.
    var prev: u8 = 0;
    for (m.attributes.slice(), 0..) |e, i| {
        if (i > 0) try testing.expect(e.id > prev);
        prev = e.id;
    }
    // And it survives a real encode/decode through the modern bit-stream.
    var buf: [64]u8 = undefined;
    const n = m.attributes.writeInto(&buf);
    const again = attributes.parseSection(buf[0..n]).?;
    try testing.expectEqual(@as(u32, 1234), again.raw(6));
}

test "a stat too wide for the modern stream is refused, not truncated" {
    var o = sampleOld();
    // Strength is 10 bits there. 1024 is legal in the old i32 and unrepresentable here.
    o.attributes.values[0] = 1024;
    try testing.expectError(error.ValueTooWide, oldToModern(&o, d2s.version_114d, &.{}));
    o.attributes.values[0] = 1023;
    _ = try oldToModern(&o, d2s.version_114d, &.{});
    // Negative likewise: the modern stream is unsigned per stat.
    o.attributes.values[0] = -1;
    try testing.expectError(error.ValueNegative, oldToModern(&o, d2s.version_114d, &.{}));
}

test "items are refused across the era boundary and allowed within it" {
    const o = sampleOld();
    const junk = "JM\x00\x00";
    // 0x57 -> 0x60 crosses 0x5c, and the item format is selected by save version.
    try testing.expectError(error.ItemsNotConvertible, oldToModern(&o, d2s.version_114d, junk));
    // An empty item list has nothing to reinterpret, so it converts.
    _ = try oldToModern(&o, d2s.version_114d, &.{});
    try testing.expect(!itemsCompatible(0x57, 0x60));
    try testing.expect(itemsCompatible(0x47, 0x59)); // both old
    try testing.expect(itemsCompatible(0x5c, 0x60)); // both modern
}

test "the waypoint tail exists only on the modern side" {
    const o = sampleOld();
    const m = try oldToModern(&o, d2s.version_114d, &.{});
    try testing.expectEqual(@as(u8, 0), m.waypoints.tail);
    // Going back drops it, and the head bytes survive intact.
    var m2 = m;
    m2.waypoints.tail = 0xff;
    const back = try modernToOld(&m2, 0x57, 319, 30, &.{});
    try testing.expectEqual(o.waypoints.head, back.waypoints.head);
}
