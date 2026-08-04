//! .d2s — the fixed header of a Diablo II character save file (1.14d, version 0x60).
//!
//! Sibling to the other binary-format parsers here (ds1/dt1/dc6/dcc) and, like them, a PURE
//! reader over a byte slice: no filesystem, no runtime model, no dependencies. Scope is
//! deliberately the 335-byte `D2SaveFileHeaderStrc` ONLY — name, class, level, status flags,
//! appearance, mercenary block, and the save checksum. That is exactly what a realm server
//! needs to list characters, so listing them must not drag in the item bit-codec or the excel
//! tables. The marker-delimited sections after the header (quests "Woo!", waypoints "WS", NPCs
//! "w4", attributes "gf", skills "if", items "JM") are owned by d2-save.

const std = @import("std");

/// A fresh character's `.d2s` is the header alone; the engine materializes starting
/// stats/skills/items from CharStats.txt on first play and grows the file on save.
pub const header_size: usize = 0x14f; // 335
pub const signature: u32 = 0xaa55aa55;
pub const version_114d: u32 = 0x60;
pub const name_max = 15;

/// Byte offsets inside the header (1.14d `D2SaveFileHeaderStrc`).
pub const off_signature = 0x00; // u32 0xaa55aa55
pub const off_version = 0x04; // u32 0x60
pub const off_filesize = 0x08; // u32 = total .d2s length
pub const off_checksum = 0x0c; // u32 (Game.exe CalculateChecksum @0x411130)
pub const off_name = 0x14; // char[16], NUL-terminated, 15 chars max
pub const off_status = 0x24; // u8 0x01 mandatory, 0x04 hardcore, 0x08 died, 0x20 expansion
pub const off_class = 0x28; // u8 nPlayerClassId
pub const off_level = 0x2b; // u8 bCharacterLevel

const off_progression = 0x25;
const off_const16 = 0x29; // u8 nConst16 = 0x10
const off_maxskills = 0x2a; // u8 nMaxSkillsCount = 0x1e
const off_createtime = 0x2c; // u32 nCreateTime
const off_time32 = 0x30; // u32 nTime32
const off_hotkeys = 0x38; // u32[16] assigned skills
const off_appearance1 = 0x88; // char[16] menu appearance (equip graphics)
const off_appearance2 = 0x98; // char[16] component color transforms
const off_difficulty = 0xa8; // u8[3] per-difficulty act + active bit
const off_mapid = 0xab; // u32
const off_merc = 0xb1; // dead(u16) id(u32) name(u16) type(u16) experience(u32)
const off_tail = 0xbf; // 144 unclassified bytes out to header_size

const class_druid = 5;
const class_assassin = 6;

/// The decoded header. Every byte of the 335 is represented — the fields we have names for
/// plus the `unk_*` runs verbatim — so `writeInto` reproduces the source header byte-exactly.
pub const Header = struct {
    signature: u32 = 0,
    version: u32 = 0,
    file_size: u32 = 0,
    checksum: u32 = 0,
    active_weapon: u32 = 0,
    name: [16]u8 = [_]u8{0} ** 16,
    status: u8 = 0,
    progression: u8 = 0,
    unk_0x26: [2]u8 = [_]u8{0} ** 2,
    class: u8 = 0,
    const16: u8 = 0,
    max_skills: u8 = 0,
    level: u8 = 0,
    created: u32 = 0,
    last_played: u32 = 0,
    unk_0x34: [4]u8 = [_]u8{0} ** 4,
    hotkeys: [16]u32 = [_]u32{0} ** 16,
    left_skill: u32 = 0,
    right_skill: u32 = 0,
    alt_left_skill: u32 = 0,
    alt_right_skill: u32 = 0,
    appearance1: [16]u8 = [_]u8{0} ** 16,
    appearance2: [16]u8 = [_]u8{0} ** 16,
    difficulty: [3]u8 = [_]u8{0} ** 3,
    map_id: u32 = 0,
    unk_0xaf: [2]u8 = [_]u8{0} ** 2,
    merc_dead: u16 = 0,
    merc_id: u32 = 0,
    merc_name_id: u16 = 0,
    merc_type: u16 = 0,
    merc_experience: u32 = 0,
    unk_0xbf: [144]u8 = [_]u8{0} ** 144,

    /// The character name as a slice (NUL-terminated inside the 16-byte field).
    pub fn nameSlice(self: *const Header) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    pub fn hardcore(self: *const Header) bool {
        return self.status & 0x04 != 0;
    }
    pub fn died(self: *const Header) bool {
        return self.status & 0x08 != 0;
    }
    pub fn expansion(self: *const Header) bool {
        return self.status & 0x20 != 0;
    }
};

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn wr16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}

/// Decode the header from the front of a `.d2s`. Null when the buffer is shorter than the
/// header. Does NOT check the signature — use `validate` for that.
pub fn parseHeader(data: []const u8) ?Header {
    if (data.len < header_size) return null;
    var h = Header{
        .signature = rd32(data, off_signature),
        .version = rd32(data, off_version),
        .file_size = rd32(data, off_filesize),
        .checksum = rd32(data, off_checksum),
        .active_weapon = rd32(data, 0x10),
        .status = data[off_status],
        .progression = data[off_progression],
        .class = data[off_class],
        .const16 = data[off_const16],
        .max_skills = data[off_maxskills],
        .level = data[off_level],
        .created = rd32(data, off_createtime),
        .last_played = rd32(data, off_time32),
        .left_skill = rd32(data, 0x78),
        .right_skill = rd32(data, 0x7c),
        .alt_left_skill = rd32(data, 0x80),
        .alt_right_skill = rd32(data, 0x84),
        .map_id = rd32(data, off_mapid),
        .merc_dead = rd16(data, off_merc),
        .merc_id = rd32(data, off_merc + 2),
        .merc_name_id = rd16(data, off_merc + 6),
        .merc_type = rd16(data, off_merc + 8),
        .merc_experience = rd32(data, off_merc + 10),
    };
    @memcpy(&h.name, data[off_name..][0..16]);
    @memcpy(&h.unk_0x26, data[0x26..][0..2]);
    @memcpy(&h.unk_0x34, data[0x34..][0..4]);
    for (&h.hotkeys, 0..) |*k, i| k.* = rd32(data, off_hotkeys + i * 4);
    @memcpy(&h.appearance1, data[off_appearance1..][0..16]);
    @memcpy(&h.appearance2, data[off_appearance2..][0..16]);
    @memcpy(&h.difficulty, data[off_difficulty..][0..3]);
    @memcpy(&h.unk_0xaf, data[0xaf..][0..2]);
    @memcpy(&h.unk_0xbf, data[off_tail..][0..144]);
    return h;
}

/// Re-emit the header into `out`. Byte-exact inverse of `parseHeader` (including the
/// unclassified runs). The checksum field is written as held — fix it after the whole file
/// is assembled with `fixChecksum`.
pub fn writeHeader(h: *const Header, out: *[header_size]u8) void {
    @memset(out, 0);
    wr32(out, off_signature, h.signature);
    wr32(out, off_version, h.version);
    wr32(out, off_filesize, h.file_size);
    wr32(out, off_checksum, h.checksum);
    wr32(out, 0x10, h.active_weapon);
    @memcpy(out[off_name..][0..16], &h.name);
    out[off_status] = h.status;
    out[off_progression] = h.progression;
    @memcpy(out[0x26..][0..2], &h.unk_0x26);
    out[off_class] = h.class;
    out[off_const16] = h.const16;
    out[off_maxskills] = h.max_skills;
    out[off_level] = h.level;
    wr32(out, off_createtime, h.created);
    wr32(out, off_time32, h.last_played);
    @memcpy(out[0x34..][0..4], &h.unk_0x34);
    for (h.hotkeys, 0..) |k, i| wr32(out, off_hotkeys + i * 4, k);
    wr32(out, 0x78, h.left_skill);
    wr32(out, 0x7c, h.right_skill);
    wr32(out, 0x80, h.alt_left_skill);
    wr32(out, 0x84, h.alt_right_skill);
    @memcpy(out[off_appearance1..][0..16], &h.appearance1);
    @memcpy(out[off_appearance2..][0..16], &h.appearance2);
    @memcpy(out[off_difficulty..][0..3], &h.difficulty);
    wr32(out, off_mapid, h.map_id);
    @memcpy(out[0xaf..][0..2], &h.unk_0xaf);
    wr16(out, off_merc, h.merc_dead);
    wr32(out, off_merc + 2, h.merc_id);
    wr16(out, off_merc + 6, h.merc_name_id);
    wr16(out, off_merc + 8, h.merc_type);
    wr32(out, off_merc + 10, h.merc_experience);
    @memcpy(out[off_tail..][0..144], &h.unk_0xbf);
}

/// True when `data` looks like a 1.14d `.d2s`: long enough for the header, the 0xaa55aa55
/// signature, version 0x60, a declared file size that matches, and a self-consistent checksum.
pub fn validate(data: []const u8) bool {
    if (data.len < header_size) return false;
    if (rd32(data, off_signature) != signature) return false;
    if (rd32(data, off_version) != version_114d) return false;
    if (rd32(data, off_filesize) != data.len) return false;
    return verifyChecksum(data);
}

/// D2's rolling save checksum over the whole file (with the checksum field zeroed):
///   csum = byte + (1 if csum's high bit set) + csum*2   — all u32-wrapping.
/// Verified against real 1.14d saves (matches the client-accepted checksum exactly).
pub fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    for (data) |b| {
        const carry: u32 = @intFromBool(sum & 0x8000_0000 != 0);
        sum = @as(u32, b) +% carry +% (sum *% 2);
    }
    return sum;
}

/// Recompute the checksum over `data` treating the checksum field as zero, without mutating it,
/// and compare against the stored value.
pub fn verifyChecksum(data: []const u8) bool {
    if (data.len < off_checksum + 4) return false;
    const stored = rd32(data, off_checksum);
    var sum: u32 = 0;
    for (data, 0..) |b, i| {
        const byte: u32 = if (i >= off_checksum and i < off_checksum + 4) 0 else b;
        const carry: u32 = @intFromBool(sum & 0x8000_0000 != 0);
        sum = byte +% carry +% (sum *% 2);
    }
    return sum == stored;
}

/// Zero the checksum field, recompute over the whole buffer, and store it (LE) in place.
pub fn fixChecksum(data: []u8) void {
    if (data.len < off_checksum + 4) return;
    @memset(data[off_checksum..][0..4], 0);
    wr32(data, off_checksum, checksum(data));
}

/// Build a fresh level-1 `.d2s` into `out` (the 335-byte header). Mirrors
/// LAUNCHER_InitNewCharacterSaveFile @0x43c540: signature/version/size, name, status
/// (`flags | 1`, +0x20 expansion for Druid/Assassin), level 1, class, create time,
/// nConst16=0x10, nMaxSkillsCount=0x1e, appearance = all 0xFF (naked; the GS sets the
/// real look on first play). Fixes the checksum. False on a bad name/class.
pub fn newSave(out: *[header_size]u8, name: []const u8, class: u8, status_flags: u8, create_time: u32) bool {
    if (name.len == 0 or name.len > name_max or class > class_assassin) return false;
    @memset(out, 0);
    wr32(out, off_signature, signature);
    wr32(out, off_version, version_114d);
    wr32(out, off_filesize, header_size);
    @memcpy(out[off_name..][0..name.len], name);
    var st: u8 = status_flags | 0x01;
    if (class == class_druid or class == class_assassin) st |= 0x20;
    wr32(out, off_status, st);
    out[off_class] = class;
    out[off_const16] = 0x10;
    out[off_maxskills] = 0x1e;
    out[off_level] = 1;
    wr32(out, off_createtime, create_time);
    wr32(out, off_time32, create_time);
    @memset(out[off_appearance1..][0..16], 0xFF);
    @memset(out[off_appearance2..][0..16], 0xFF);
    fixChecksum(out);
    return true;
}

/// Rewrite the embedded character name (16-byte NUL-padded field). False if the name is
/// empty or too long. Does NOT fix the checksum — call `fixChecksum` after.
pub fn setName(data: []u8, name: []const u8) bool {
    if (data.len < off_name + 16) return false;
    if (name.len == 0 or name.len > name_max) return false;
    @memset(data[off_name..][0..16], 0);
    @memcpy(data[off_name..][0..name.len], name);
    return true;
}

/// The status flags byte, or null if the buffer is too short.
pub fn status(data: []const u8) ?u8 {
    if (data.len <= off_status) return null;
    return data[off_status];
}

/// Overwrite the status flags byte. Does NOT fix the checksum.
pub fn setStatus(data: []u8, v: u8) void {
    if (data.len > off_status) data[off_status] = v;
}

test "checksum round-trips and verifyChecksum agrees" {
    var buf = [_]u8{0} ** 64;
    buf[0] = 0x55;
    std.mem.writeInt(u32, buf[off_name..][0..4], 0xDEADBEEF, .little);
    fixChecksum(&buf);
    const stored = std.mem.readInt(u32, buf[off_checksum..][0..4], .little);
    var copy = buf;
    @memset(copy[off_checksum..][0..4], 0);
    try std.testing.expectEqual(stored, checksum(&copy));
    try std.testing.expect(verifyChecksum(&buf));
    buf[0x20] +%= 1;
    try std.testing.expect(!verifyChecksum(&buf));
}

test "newSave builds a valid 335-byte fresh character header" {
    var save: [header_size]u8 = undefined;
    try std.testing.expect(newSave(&save, "Freshie", 1, 0x20, 0x12345678)); // Sorceress, expansion
    try std.testing.expectEqual(signature, std.mem.readInt(u32, save[0..4], .little));
    try std.testing.expectEqual(version_114d, std.mem.readInt(u32, save[off_version..][0..4], .little));
    try std.testing.expectEqual(@as(u32, header_size), std.mem.readInt(u32, save[off_filesize..][0..4], .little));
    try std.testing.expectEqualStrings("Freshie", std.mem.sliceTo(save[off_name..][0..16], 0));
    try std.testing.expectEqual(@as(u8, 0x21), save[off_status]); // 0x20 expansion | 0x01 mandatory
    try std.testing.expectEqual(@as(u8, 1), save[off_class]);
    try std.testing.expectEqual(@as(u8, 1), save[off_level]);
    try std.testing.expectEqual(@as(u8, 0x1e), save[off_maxskills]);
    try std.testing.expect(validate(&save));
    // Druid (5) forces expansion even if not requested.
    try std.testing.expect(newSave(&save, "Treebeard", 5, 0, 0));
    try std.testing.expectEqual(@as(u8, 0x21), save[off_status]);
    // Bad inputs rejected.
    try std.testing.expect(!newSave(&save, "", 1, 0, 0));
    try std.testing.expect(!newSave(&save, "WayTooLongCharName", 1, 0, 0));
    try std.testing.expect(!newSave(&save, "Ok", 7, 0, 0)); // class out of range
}

test "parseHeader / writeHeader are byte-exact inverses" {
    var save: [header_size]u8 = undefined;
    try std.testing.expect(newSave(&save, "RoundTrip", 3, 0x04, 0xCAFEBABE));
    // Salt the unclassified runs so the round-trip has to carry them, not re-zero them.
    save[0x26] = 0x11;
    save[0x35] = 0x22;
    save[0xbf + 7] = 0x33;
    save[0x14e] = 0x44;
    const h = parseHeader(&save) orelse return error.NoHeader;
    try std.testing.expectEqualStrings("RoundTrip", h.nameSlice());
    try std.testing.expectEqual(@as(u8, 3), h.class);
    try std.testing.expect(h.hardcore());
    var out: [header_size]u8 = undefined;
    writeHeader(&h, &out);
    try std.testing.expectEqualSlices(u8, &save, &out);
    try std.testing.expect(parseHeader(save[0 .. header_size - 1]) == null);
}

test "setName rewrites the name field and rejects bad names" {
    var buf = [_]u8{0xAA} ** 64;
    try std.testing.expect(setName(&buf, "Cloney"));
    try std.testing.expectEqualStrings("Cloney", std.mem.sliceTo(buf[off_name..][0..16], 0));
    try std.testing.expect(!setName(&buf, "")); // empty
    try std.testing.expect(!setName(&buf, "ThisNameIsWayTooLong")); // > 15
}
