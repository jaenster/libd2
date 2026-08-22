//! The body of a pre-1.09 `.d2s` — the sections 1.00 through 1.08 wrote after their 0x82 header.
//!
//! Same idea as `sections.zig` and mostly the same markers, but it is a different file format and
//! not a variant of one. Read off 1.14d's own old-save loader, which still ships the whole reader:
//! `SEVER_loadFrom_Old_Savegame` (Game.exe 0x00534020) walks the file with one function per
//! section, each returning how many bytes it consumed.
//!
//!   0x082  quests      0x12a   "Woo!"  _oldSaveGameLoadingPart2 @0x00532be0
//!   0x1ac  waypoints   0x50    "WS"    _oldSaveGameLoadingPart3 @0x00532c70
//!   0x1fc  npc intros  0x34    01 77   _oldSaveGameLoadingPart4 @0x00532d00
//!   0x230  attributes  5+4N    "gf"    _oldSaveGameLoadingPart5 @0x00532da0
//!          skills      2+S     "if"    _oldSaveGameLoadingPart6 @0x00532e90
//!          items       to EOF  "JM"    PLRSAVE_DispatchItemLoadByFormat
//!
//! Where it differs from the modern body, and each difference is one the engine enforces:
//!
//!   * Quests are byte-identical — same marker, same 6-byte head, same three 96-byte blocks.
//!   * Waypoints are 80 bytes, not 81: the modern section has a trailing byte and this one does
//!     not. Reading 81 here eats the first byte of the NPC marker.
//!   * NPC intros are 52 bytes and start `01 77`, NOT the modern `w4`.
//!   * Attributes share the "gf" marker and nothing else. Modern packs 16 stats as a bit-stream
//!     with a per-stat width; this is a 16-bit presence bitmap at +2 followed by plain i32 values
//!     from +5, one per set bit, in stat-id order. Far simpler, and completely incompatible.
//!   * Skills are "if" plus ONE BYTE PER CLASS SKILL, sized by the character's class rather than
//!     the modern fixed 30.

const std = @import("std");
const formats = @import("d2-formats");
const sections = @import("sections.zig");

pub const d2s = formats.d2s;
pub const old_header = formats.d2s.old;

/// Reused wholesale — the old quest section has the same layout as the modern one.
pub const Quests = sections.Quests;
pub const Items = sections.Items;
pub const Difficulty = sections.Difficulty;

pub const quest_marker = sections.quest_marker;
pub const quest_len = sections.quest_len;
pub const waypoint_marker = sections.waypoint_marker;
/// 80, not the modern 81: there is no trailing byte after the third block.
pub const waypoint_len = 0x50;
/// Measured, and deliberately not "w4": `_oldSaveGameLoadingPart4` compares the first i16 against
/// 0x7701, which is the bytes 01 77.
pub const npc_marker = "\x01\x77";
pub const npc_len = 0x34;
pub const attribute_marker = "gf";
pub const skill_marker = "if";
pub const item_marker = sections.item_marker;

/// The engine passes 0x10 to the attribute reader as the stat count, so the bitmap is 16 bits and
/// the stats are ids 0..15 — the same set the modern bit-stream carries.
pub const attribute_stat_count = 16;
/// "gf" + u16 bitmap + one byte, before the first value.
pub const attribute_head_len = 5;

pub const ParseError = sections.ParseError || error{BadAttributeLayout};

/// "WS" — three per-difficulty blocks and no trailing byte. `head` is everything between the
/// marker and the first block; the engine only requires each block to open with 0, 0x101 or 0x102.
pub const Waypoints = struct {
    head: [6]u8 = @splat(0),
    blocks: [3][0x18]u8 = @splat(@splat(0)),

    pub fn isSet(self: *const Waypoints, diff: Difficulty, idx: u6) bool {
        if (idx >= 39) return false;
        const bits = self.blocks[@intFromEnum(diff)][2..7];
        return bits[idx >> 3] & (@as(u8, 1) << @intCast(idx & 7)) != 0;
    }
};

/// `01 77` — per-difficulty NPC intro/greeting data. Carried verbatim; the engine hands each block
/// straight to PLAYERINTRO_CopyIntroData without interpreting it here.
pub const Npcs = struct {
    body: [npc_len - npc_marker.len]u8 = @splat(0),
};

/// "gf" — a presence bitmap and a packed run of i32 values.
///
/// Only stats whose bit is set have a value in the file, and they appear in stat-id order, so the
/// bitmap is what makes the section's length knowable. A stat that is absent reads as zero.
pub const Attributes = struct {
    present: u16 = 0,
    /// The byte between the bitmap and the first value. Carried so a round trip is byte-exact.
    unk_0x04: u8 = 0,
    values: [attribute_stat_count]i32 = @splat(0),

    pub fn has(self: *const Attributes, stat: u4) bool {
        return self.present & (@as(u16, 1) << stat) != 0;
    }
    pub fn get(self: *const Attributes, stat: u4) i32 {
        return if (self.has(stat)) self.values[stat] else 0;
    }
    pub fn count(self: *const Attributes) usize {
        return @popCount(self.present);
    }
    pub fn byteLen(self: *const Attributes) usize {
        return attribute_head_len + self.count() * 4;
    }
};

/// "if" — one byte per skill the character's class has. The engine reads
/// `AmountOfSkillsByClassId(class)` of them, so the length is a property of the class and not of
/// the file; a reader that assumed the modern 30 would mis-locate the item list on any build whose
/// class tables differ.
pub const Skills = struct {
    levels: [64]u8 = @splat(0),
    len: u8 = 0,

    pub fn byteLen(self: *const Skills) usize {
        return skill_marker.len + self.len;
    }
    pub fn slice(self: *const Skills) []const u8 {
        return self.levels[0..self.len];
    }
};

pub const Save = struct {
    header: old_header.Header = .{},
    quests: Quests = .{},
    waypoints: Waypoints = .{},
    npcs: Npcs = .{},
    attributes: Attributes = .{},
    skills: Skills = .{},
    items: Items = .{},

    pub fn byteLen(self: *const Save) usize {
        return old_header.header_size + quest_len + waypoint_len + npc_len +
            self.attributes.byteLen() + self.skills.byteLen() + self.items.bytes.len;
    }

    /// Emit the whole save. No checksum is fixed up on the way out, and that is not an omission:
    /// the old header has no checksum field — `name[16]` covers the offset the modern one keeps it
    /// at — so writing one would corrupt the name.
    pub fn writeInto(self: *const Save, out: []u8) ParseError![]u8 {
        const total = self.byteLen();
        if (out.len < total) return error.BufferTooSmall;

        old_header.write(&self.header, out[0..old_header.header_size]);
        var p: usize = old_header.header_size;

        @memcpy(out[p..][0..quest_marker.len], quest_marker);
        @memcpy(out[p + 4 ..][0..6], &self.quests.head);
        for (self.quests.blocks, 0..) |blk, i| @memcpy(out[p + 10 + i * 96 ..][0..96], &blk);
        p += quest_len;

        @memcpy(out[p..][0..waypoint_marker.len], waypoint_marker);
        @memcpy(out[p + 2 ..][0..6], &self.waypoints.head);
        for (self.waypoints.blocks, 0..) |blk, i| @memcpy(out[p + 8 + i * 0x18 ..][0..0x18], &blk);
        p += waypoint_len;

        @memcpy(out[p..][0..npc_marker.len], npc_marker);
        @memcpy(out[p + npc_marker.len ..][0..self.npcs.body.len], &self.npcs.body);
        p += npc_len;

        @memcpy(out[p..][0..attribute_marker.len], attribute_marker);
        std.mem.writeInt(u16, out[p + 2 ..][0..2], self.attributes.present, .little);
        out[p + 4] = self.attributes.unk_0x04;
        var v: usize = 0;
        for (0..attribute_stat_count) |stat| {
            if (!self.attributes.has(@intCast(stat))) continue;
            std.mem.writeInt(i32, out[p + attribute_head_len + v * 4 ..][0..4], self.attributes.values[stat], .little);
            v += 1;
        }
        p += self.attributes.byteLen();

        @memcpy(out[p..][0..skill_marker.len], skill_marker);
        @memcpy(out[p + skill_marker.len ..][0..self.skills.len], self.skills.slice());
        p += self.skills.byteLen();

        @memcpy(out[p..][0..self.items.bytes.len], self.items.bytes);
        p += self.items.bytes.len;

        std.debug.assert(p == total);
        return out[0..total];
    }
};

fn expectMarker(data: []const u8, off: usize, m: []const u8, e: ParseError) ParseError!void {
    if (off + m.len > data.len or !std.mem.eql(u8, data[off..][0..m.len], m)) return e;
}

/// Decode a played pre-1.09 `.d2s`.
///
/// `class_skill_count` is how many skills the character's class has — the engine gets it from
/// `AmountOfSkillsByClassId` and it decides where the item list begins. It is a parameter because
/// this package has no class tables and must not grow a dependency on them to read a header.
pub fn parse(data: []const u8, class_skill_count: u8) ParseError!Save {
    var s = Save{};
    s.header = old_header.parse(data) orelse return error.TooShort;
    if (s.header.signature != old_header.signature) return error.BadSignature;

    var p: usize = old_header.header_size;

    try expectMarker(data, p, quest_marker, error.BadQuestMarker);
    if (p + quest_len > data.len) return error.TooShort;
    @memcpy(&s.quests.head, data[p + 4 ..][0..6]);
    for (&s.quests.blocks, 0..) |*blk, i| @memcpy(blk, data[p + 10 + i * 96 ..][0..96]);
    p += quest_len;

    try expectMarker(data, p, waypoint_marker, error.BadWaypointMarker);
    if (p + waypoint_len > data.len) return error.TooShort;
    @memcpy(&s.waypoints.head, data[p + 2 ..][0..6]);
    for (&s.waypoints.blocks, 0..) |*blk, i| @memcpy(blk, data[p + 8 + i * 0x18 ..][0..0x18]);
    p += waypoint_len;

    try expectMarker(data, p, npc_marker, error.BadNpcMarker);
    if (p + npc_len > data.len) return error.TooShort;
    @memcpy(&s.npcs.body, data[p + npc_marker.len ..][0..s.npcs.body.len]);
    p += npc_len;

    try expectMarker(data, p, attribute_marker, error.BadAttributeMarker);
    if (p + attribute_head_len > data.len) return error.TooShort;
    s.attributes.present = std.mem.readInt(u16, data[p + 2 ..][0..2], .little);
    s.attributes.unk_0x04 = data[p + 4];
    if (p + s.attributes.byteLen() > data.len) return error.TooShort;
    var v: usize = 0;
    for (0..attribute_stat_count) |stat| {
        if (!s.attributes.has(@intCast(stat))) continue;
        s.attributes.values[stat] = std.mem.readInt(i32, data[p + attribute_head_len + v * 4 ..][0..4], .little);
        v += 1;
    }
    p += s.attributes.byteLen();

    try expectMarker(data, p, skill_marker, error.BadSkillMarker);
    if (class_skill_count > s.skills.levels.len) return error.BadAttributeLayout;
    if (p + skill_marker.len + class_skill_count > data.len) return error.TooShort;
    s.skills.len = class_skill_count;
    @memcpy(s.skills.levels[0..class_skill_count], data[p + skill_marker.len ..][0..class_skill_count]);
    p += s.skills.byteLen();

    try expectMarker(data, p, item_marker, error.BadItemMarker);
    s.items = .{ .bytes = data[p..] };
    return s;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Assemble a synthetic old save with every section present and every byte distinct, so a field
/// that is dropped or mis-sized shows up as a difference rather than as a zero that matched.
fn buildOldSave(buf: []u8, present: u16, skill_count: u8, item_tail: []const u8) []u8 {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    var p: usize = 0;

    // header
    @memset(buf[0..old_header.header_size], 0);
    std.mem.writeInt(u32, buf[0..4], old_header.signature, .little);
    std.mem.writeInt(u32, buf[4..8], 0x57, .little);
    @memcpy(buf[old_header.off_name..][0.."Bartuc".len], "Bartuc");
    std.mem.writeInt(u16, buf[0x20..0x22], @intCast(old_header.header_size), .little);
    buf[0x1e] = 0x10;
    p = old_header.header_size;

    @memcpy(buf[p..][0..4], quest_marker);
    p += quest_len;

    @memcpy(buf[p..][0..2], waypoint_marker);
    // Each block must open with a version the engine accepts, or the real loader refuses it.
    for (0..3) |i| std.mem.writeInt(u16, buf[p + 8 + i * 0x18 ..][0..2], 0x102, .little);
    p += waypoint_len;

    @memcpy(buf[p..][0..2], npc_marker);
    p += npc_len;

    @memcpy(buf[p..][0..2], attribute_marker);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], present, .little);
    buf[p + 4] = 0xAB;
    var v: usize = 0;
    for (0..attribute_stat_count) |stat| {
        if (present & (@as(u16, 1) << @intCast(stat)) == 0) continue;
        std.mem.writeInt(i32, buf[p + attribute_head_len + v * 4 ..][0..4], @intCast(1000 + stat), .little);
        v += 1;
    }
    p += attribute_head_len + v * 4;

    @memcpy(buf[p..][0..2], skill_marker);
    for (0..skill_count) |i| buf[p + 2 + i] = @intCast(i % 20);
    p += 2 + skill_count;

    @memcpy(buf[p..][0..item_tail.len], item_tail);
    p += item_tail.len;
    return buf[0..p];
}

test "an old save survives parse -> write byte for byte" {
    var buf: [2048]u8 = undefined;
    const src = buildOldSave(&buf, 0b1010_1100_0011_0101, 30, "JM\x00\x00");
    const save = try parse(src, 30);
    var out: [2048]u8 = undefined;
    const written = try save.writeInto(&out);
    try testing.expectEqualSlices(u8, src, written);
}

test "the sections sit where the engine's cursor puts them" {
    var buf: [2048]u8 = undefined;
    const src = buildOldSave(&buf, 0xffff, 30, "JM");
    // 0x82 + 0x12a + 0x50 + 0x34 — the fixed prefix, before anything variable.
    try testing.expectEqualSlices(u8, quest_marker, src[0x082..][0..4]);
    try testing.expectEqualSlices(u8, waypoint_marker, src[0x1ac..][0..2]);
    try testing.expectEqualSlices(u8, npc_marker, src[0x1fc..][0..2]);
    try testing.expectEqualSlices(u8, attribute_marker, src[0x230..][0..2]);
}

test "waypoints are 80 bytes here, and 81 would eat the NPC marker" {
    var buf: [2048]u8 = undefined;
    const src = buildOldSave(&buf, 0x0001, 30, "JM");
    const wp = 0x1ac;
    try testing.expectEqual(@as(usize, 0x50), waypoint_len);
    // The modern section is 81. Reading that many here starts the next section one byte late.
    try testing.expectEqualSlices(u8, npc_marker, src[wp + waypoint_len ..][0..2]);
    try testing.expect(!std.mem.eql(u8, npc_marker, src[wp + 81 ..][0..2]));
}

test "the NPC marker is 01 77, not the modern w4" {
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x77 }, npc_marker);
    try testing.expect(!std.mem.eql(u8, "w4", npc_marker));
}

test "only stats the bitmap names have a value, and absent ones read as zero" {
    var buf: [2048]u8 = undefined;
    const present: u16 = 0b0000_0000_0000_1011; // stats 0, 1, 3
    const src = buildOldSave(&buf, present, 30, "JM");
    const save = try parse(src, 30);

    try testing.expectEqual(@as(usize, 3), save.attributes.count());
    try testing.expectEqual(@as(usize, attribute_head_len + 12), save.attributes.byteLen());
    try testing.expectEqual(@as(i32, 1000), save.attributes.get(0));
    try testing.expectEqual(@as(i32, 1001), save.attributes.get(1));
    try testing.expectEqual(@as(i32, 1003), save.attributes.get(3));
    try testing.expect(!save.attributes.has(2));
    try testing.expectEqual(@as(i32, 0), save.attributes.get(2));

    // Pinned against LITERAL offsets, not against `attribute_head_len`. The builder above uses the
    // same constant the parser does, so writing these in terms of it would only prove the constant
    // agrees with itself — a head length of 4 passed every other assertion here.
    //
    // The engine reports `nStatValueCount * 4 + 5` consumed (_oldSaveGameLoadingPart5 @0x00532da0),
    // so: marker at +0, bitmap at +2, one byte at +4, first value at +5.
    const gf = 0x230;
    try testing.expectEqualSlices(u8, attribute_marker, src[gf..][0..2]);
    try testing.expectEqual(present, std.mem.readInt(u16, src[gf + 2 ..][0..2], .little));
    try testing.expectEqual(save.attributes.unk_0x04, src[gf + 4]);
    try testing.expectEqual(save.attributes.get(0), std.mem.readInt(i32, src[gf + 5 ..][0..4], .little));
    try testing.expectEqual(save.attributes.get(1), std.mem.readInt(i32, src[gf + 9 ..][0..4], .little));
    // Stat 2 is absent, so the third value in the file is stat 3 — the packing is by set bit, not
    // by stat id.
    try testing.expectEqual(save.attributes.get(3), std.mem.readInt(i32, src[gf + 13 ..][0..4], .little));
    // And the skill section starts right after the last value.
    try testing.expectEqualSlices(u8, skill_marker, src[gf + 5 + 3 * 4 ..][0..2]);
}

test "the skill section is sized by the class, and that moves the item list" {
    // The engine reads AmountOfSkillsByClassId(class) bytes. Get it wrong and `items` starts in the
    // middle of the skill list, which is why it is a parameter rather than the modern constant 30.
    var buf: [2048]u8 = undefined;
    // A tail long enough that reading 14 skills too many stays IN BOUNDS — otherwise the wrong
    // count is caught by the length check and the mis-location this test is about never happens.
    const tail = "JM" ++ ("\xee" ** 40);
    const src = buildOldSave(&buf, 0x000f, 16, tail);
    const save = try parse(src, 16);
    try testing.expectEqual(@as(u8, 16), save.skills.len);
    try testing.expectEqualSlices(u8, tail, save.items.bytes);
    // Asking for the modern 30 consumes the "JM" as skill levels and lands on filler.
    try testing.expectError(error.BadItemMarker, parse(src, 30));
    // And when the wrong count also runs off the end, the length check catches it first.
    const short = buildOldSave(&buf, 0x000f, 16, "JMhere");
    try testing.expectError(error.TooShort, parse(short, 30));
}

test "every marker is checked, and each has its own error" {
    var buf: [2048]u8 = undefined;
    const Case = struct { off: usize, err: ParseError };
    for ([_]Case{
        .{ .off = 0x082, .err = error.BadQuestMarker },
        .{ .off = 0x1ac, .err = error.BadWaypointMarker },
        .{ .off = 0x1fc, .err = error.BadNpcMarker },
        .{ .off = 0x230, .err = error.BadAttributeMarker },
    }) |c| {
        const src = buildOldSave(&buf, 0x0001, 30, "JM");
        src[c.off] ^= 0xff;
        try testing.expectError(c.err, parse(src, 30));
    }
}

test "a truncated save is refused rather than read past" {
    var buf: [2048]u8 = undefined;
    const src = buildOldSave(&buf, 0xffff, 30, "JM");
    try testing.expectError(error.TooShort, parse(src[0 .. src.len - 8], 30));
    try testing.expectError(error.TooShort, parse(src[0..0x100], 30));
    try testing.expectError(error.TooShort, parse(src[0..4], 30));
}
