//! The marker-delimited body of a `.d2s`, decoded and re-emittable.
//!
//! A played 1.14d save is the fixed 335-byte header (owned by d2-formats) followed by a fixed
//! run of sections, in this order and at these sizes:
//!
//!   "Woo!" quests      298 bytes  — 6-byte header + 3 x 96 per-difficulty quest blocks
//!   "WS"   waypoints    81 bytes  — u32 version + u16 size + 3 x 24 per-difficulty blocks + 1
//!   "w4"   NPC intros   51 bytes  — per-NPC intro/greeting bits
//!   "gf"   attributes    varies   — the stat bit-stream (see attributes.zig)
//!   "if"   skills       32 bytes  — 30 skill levels, class-relative
//!   "JM"   items        to EOF    — player list, then corpse, mercenary ("jf") and golem ("kf")
//!
//! Sections we have a field-level model for are decoded; the runs whose meaning is not yet RE'd
//! are carried verbatim so `writeInto` reproduces the source file byte-for-byte. The item tail is
//! kept as raw bytes on purpose: the per-item codec (d2-core `wire`) has documented gaps on the
//! write side (rare-name affixes, ear/personalization blocks, grouped damage stats), so a save
//! writer that re-encoded items would not be byte-exact. Read them with `items.iterator`.

const std = @import("std");
const formats = @import("d2-formats");
const core = @import("d2-core");
const attributes = @import("attributes.zig");

pub const d2s = formats.d2s;
pub const wire = core.wire;

pub const quest_marker = "Woo!";
pub const quest_len = 298;
pub const waypoint_marker = "WS";
pub const waypoint_len = 81;
pub const npc_marker = "w4";
pub const npc_len = 51;
pub const skill_marker = "if";
pub const skill_len = 32;
pub const item_marker = "JM";

pub const Difficulty = enum(u2) { normal = 0, nightmare = 1, hell = 2 };

pub const ParseError = error{
    TooShort,
    BadSignature,
    BadQuestMarker,
    BadWaypointMarker,
    BadNpcMarker,
    BadAttributeMarker,
    BadSkillMarker,
    BadItemMarker,
    BufferTooSmall,
};

/// "Woo!" — the quest section. `head` is the 6-byte section header (06 00 00 00 2a 01 on every
/// save seen); each difficulty gets a 96-byte block of per-quest flag words.
pub const Quests = struct {
    head: [6]u8 = [_]u8{0} ** 6,
    blocks: [3][96]u8 = [_][96]u8{[_]u8{0} ** 96} ** 3,

    pub fn block(self: *const Quests, diff: Difficulty) *const [96]u8 {
        return &self.blocks[@intFromEnum(diff)];
    }
};

/// "WS" — waypoints. Per difficulty: 2 lead bytes (02 01), a 5-byte bitfield covering the 39
/// waypoints, then 17 unused. `tail` is the single trailing byte after the third block.
pub const Waypoints = struct {
    version: u32 = 0,
    size: u16 = 0,
    blocks: [3][24]u8 = [_][24]u8{[_]u8{0} ** 24} ** 3,
    tail: u8 = 0,

    /// True when waypoint `idx` (0..38, act order) is activated on `diff`.
    pub fn isSet(self: *const Waypoints, diff: Difficulty, idx: u6) bool {
        if (idx >= 39) return false;
        const bits = self.blocks[@intFromEnum(diff)][2..7];
        return bits[idx >> 3] & (@as(u8, 1) << @intCast(idx & 7)) != 0;
    }

    pub fn set(self: *Waypoints, diff: Difficulty, idx: u6, on: bool) void {
        if (idx >= 39) return;
        const bits = self.blocks[@intFromEnum(diff)][2..7];
        const mask = @as(u8, 1) << @intCast(idx & 7);
        if (on) bits[idx >> 3] |= mask else bits[idx >> 3] &= ~mask;
    }
};

/// "w4" — the NPC intro/greeting bitfields. Not field-decoded yet; carried verbatim.
pub const Npcs = struct {
    body: [npc_len - npc_marker.len]u8 = [_]u8{0} ** (npc_len - npc_marker.len),
};

/// "if" — 30 skill levels in class-relative order (the class's first skill id is the header's
/// class row in the engine's skill table).
pub const Skills = struct {
    levels: [skill_len - skill_marker.len]u8 = [_]u8{0} ** (skill_len - skill_marker.len),
};

/// The raw item tail: the player's "JM" list header onward, through the corpse, mercenary and
/// golem blocks, to EOF.
pub const Items = struct {
    bytes: []const u8 = &.{},

    /// The u16 item count of the player's list.
    pub fn playerCount(self: *const Items) u16 {
        if (self.bytes.len < 4) return 0;
        return std.mem.readInt(u16, self.bytes[2..4], .little);
    }

    /// Walk the player's item list. Each record is byte-aligned and starts with "JM", so the
    /// iterator resyncs to the next marker after every decode (the decoder consumes exactly one
    /// record but nested socketed items follow their host).
    pub fn iterator(self: *const Items) Iterator {
        return .{ .bytes = self.bytes, .remaining = self.playerCount(), .pos = 4 };
    }

    pub const Iterator = struct {
        bytes: []const u8,
        remaining: u16,
        pos: usize,

        pub fn next(self: *Iterator) ?wire.Item {
            if (self.remaining == 0) return null;
            while (self.pos + item_marker.len <= self.bytes.len and
                !std.mem.eql(u8, self.bytes[self.pos..][0..item_marker.len], item_marker)) : (self.pos += 1)
            {}
            if (self.pos + item_marker.len > self.bytes.len) return null;
            var r = core.bitreader.BitReader.init(self.bytes[self.pos..]);
            const it = wire.parseSave(&r);
            self.pos += (r.bit_pos + 7) / 8;
            self.remaining -= 1;
            return it;
        }
    };
};

/// A parsed `.d2s`. Section values are owned by value except `items`, which borrows the source
/// buffer.
pub const Save = struct {
    header: d2s.Header = .{},
    quests: Quests = .{},
    waypoints: Waypoints = .{},
    npcs: Npcs = .{},
    attributes: attributes.Section = .{},
    skills: Skills = .{},
    items: Items = .{},

    /// Total encoded length, which `writeInto` also stamps into the header's file-size field.
    pub fn byteLen(self: *const Save) usize {
        return d2s.header_size + quest_len + waypoint_len + npc_len +
            self.attributes.byteLen() + skill_len + self.items.bytes.len;
    }

    /// Emit the whole save into `out`, stamping the file size and fixing the checksum. Returns
    /// the written slice. Byte-exact against the source for an unmodified `parse` result.
    pub fn writeInto(self: *const Save, out: []u8) ParseError![]u8 {
        const total = self.byteLen();
        if (out.len < total) return error.BufferTooSmall;

        var h = self.header;
        h.file_size = @intCast(total);
        d2s.writeHeader(&h, out[0..d2s.header_size]);
        var p: usize = d2s.header_size;

        @memcpy(out[p..][0..quest_marker.len], quest_marker);
        @memcpy(out[p + 4 ..][0..6], &self.quests.head);
        for (self.quests.blocks, 0..) |blk, i| @memcpy(out[p + 10 + i * 96 ..][0..96], &blk);
        p += quest_len;

        @memcpy(out[p..][0..waypoint_marker.len], waypoint_marker);
        std.mem.writeInt(u32, out[p + 2 ..][0..4], self.waypoints.version, .little);
        std.mem.writeInt(u16, out[p + 6 ..][0..2], self.waypoints.size, .little);
        for (self.waypoints.blocks, 0..) |blk, i| @memcpy(out[p + 8 + i * 24 ..][0..24], &blk);
        out[p + 80] = self.waypoints.tail;
        p += waypoint_len;

        @memcpy(out[p..][0..npc_marker.len], npc_marker);
        @memcpy(out[p + npc_marker.len ..][0..self.npcs.body.len], &self.npcs.body);
        p += npc_len;

        p += self.attributes.writeInto(out[p..]);

        @memcpy(out[p..][0..skill_marker.len], skill_marker);
        @memcpy(out[p + skill_marker.len ..][0..self.skills.levels.len], &self.skills.levels);
        p += skill_len;

        @memcpy(out[p..][0..self.items.bytes.len], self.items.bytes);
        p += self.items.bytes.len;

        std.debug.assert(p == total);
        d2s.fixChecksum(out[0..total]);
        return out[0..total];
    }
};

fn expectMarker(data: []const u8, off: usize, m: []const u8, e: ParseError) ParseError!void {
    if (off + m.len > data.len or !std.mem.eql(u8, data[off..][0..m.len], m)) return e;
}

/// Decode a full played `.d2s`. The sections sit at fixed offsets after the header, so this is a
/// positional walk with a marker check at every step rather than a scan.
pub fn parse(data: []const u8) ParseError!Save {
    var s = Save{};
    s.header = d2s.parseHeader(data) orelse return error.TooShort;
    if (s.header.signature != d2s.signature) return error.BadSignature;

    var p: usize = d2s.header_size;

    try expectMarker(data, p, quest_marker, error.BadQuestMarker);
    if (p + quest_len > data.len) return error.TooShort;
    @memcpy(&s.quests.head, data[p + 4 ..][0..6]);
    for (&s.quests.blocks, 0..) |*blk, i| @memcpy(blk, data[p + 10 + i * 96 ..][0..96]);
    p += quest_len;

    try expectMarker(data, p, waypoint_marker, error.BadWaypointMarker);
    if (p + waypoint_len > data.len) return error.TooShort;
    s.waypoints.version = std.mem.readInt(u32, data[p + 2 ..][0..4], .little);
    s.waypoints.size = std.mem.readInt(u16, data[p + 6 ..][0..2], .little);
    for (&s.waypoints.blocks, 0..) |*blk, i| @memcpy(blk, data[p + 8 + i * 24 ..][0..24]);
    s.waypoints.tail = data[p + 80];
    p += waypoint_len;

    try expectMarker(data, p, npc_marker, error.BadNpcMarker);
    if (p + npc_len > data.len) return error.TooShort;
    @memcpy(&s.npcs.body, data[p + npc_marker.len ..][0..s.npcs.body.len]);
    p += npc_len;

    s.attributes = attributes.parseSection(data[p..]) orelse return error.BadAttributeMarker;
    p += s.attributes.byteLen();

    try expectMarker(data, p, skill_marker, error.BadSkillMarker);
    if (p + skill_len > data.len) return error.TooShort;
    @memcpy(&s.skills.levels, data[p + skill_marker.len ..][0..s.skills.levels.len]);
    p += skill_len;

    try expectMarker(data, p, item_marker, error.BadItemMarker);
    s.items = .{ .bytes = data[p..] };
    return s;
}
