//! Character persistence data model — pure record types + Unit mapping + sidecar codec.
//!
//! The host owns file I/O (open/read/write/mkdir) and the byte-exact .d2s header; this module
//! holds the PURE, libc-free pieces: the quest-completion bitfield, the CharSave record the
//! host loads on join / writes on leave, the CharSave<->Unit stat mapping, and the compact
//! sidecar byte codec (buffer in / buffer out — no filesystem). Mirrors the lib rule "state
//! as params, return a decision": applyToUnit mutates only the passed Unit; the codec touches
//! only the caller's buffer.

const std = @import("std");
const unit = @import("unit.zig");
const Unit = unit.Unit;
const Stat = @import("stat.zig").Stat;

/// Number of quest-completion flags modelled: 3 difficulties x 32 slots. D2's real quest
/// record is a per-act bitfield; this flat index is enough for a completion framework.
pub const NUM_QUESTS = 96;

/// A character's quest-completion bitfield (one bit per quest slot). This is the quest
/// framework's persisted state; game logic toggles a flag on quest completion.
pub const QuestState = struct {
    bits: [NUM_QUESTS / 8]u8 = [_]u8{0} ** (NUM_QUESTS / 8),

    pub fn isDone(self: QuestState, id: u16) bool {
        if (id >= NUM_QUESTS) return false;
        return (self.bits[id / 8] & (@as(u8, 1) << @intCast(id % 8))) != 0;
    }
    pub fn setDone(self: *QuestState, id: u16, done: bool) void {
        if (id >= NUM_QUESTS) return;
        const mask = @as(u8, 1) << @intCast(id % 8);
        if (done) self.bits[id / 8] |= mask else self.bits[id / 8] &= ~mask;
    }
    pub fn count(self: QuestState) u32 {
        var n: u32 = 0;
        for (self.bits) |b| n += @popCount(b);
        return n;
    }
};

/// The persisted per-character state the game host loads on join and writes on leave.
/// Defaults are the fresh level-1 sorceress the join path uses when no save exists.
pub const CharSave = struct {
    level: u8 = 1,
    class: u8 = 1,
    status: u8 = 0x21, // expansion | mandatory
    strength: u16 = 30,
    dexterity: u16 = 30,
    vitality: u16 = 20,
    energy: u16 = 20,
    max_hp: u16 = 100,
    quests: QuestState = .{},
    waypoints: u64 = 0,
};

pub const SIDECAR_MAGIC: u32 = 0x53474432; // "D2GS" (LE)
pub const SIDECAR_VERSION: u8 = 1;
pub const SIDECAR_LEN = 26 + (NUM_QUESTS / 8);

/// Serialize a CharSave into the fixed-size sidecar blob (no filesystem).
pub fn writeSidecar(out: *[SIDECAR_LEN]u8, cs: CharSave) void {
    std.mem.writeInt(u32, out[0..4], SIDECAR_MAGIC, .little);
    out[4] = SIDECAR_VERSION;
    out[5] = cs.level;
    out[6] = cs.class;
    out[7] = cs.status;
    std.mem.writeInt(u16, out[8..10], cs.strength, .little);
    std.mem.writeInt(u16, out[10..12], cs.dexterity, .little);
    std.mem.writeInt(u16, out[12..14], cs.vitality, .little);
    std.mem.writeInt(u16, out[14..16], cs.energy, .little);
    std.mem.writeInt(u16, out[16..18], cs.max_hp, .little);
    std.mem.writeInt(u64, out[18..26], cs.waypoints, .little);
    @memcpy(out[26..SIDECAR_LEN], &cs.quests.bits);
}

/// Overlay a sidecar blob onto `cs` (leaves `cs` untouched if the blob is short / mismatched).
pub fn readSidecar(blob: []const u8, cs: *CharSave) void {
    if (blob.len < SIDECAR_LEN) return;
    if (std.mem.readInt(u32, blob[0..4], .little) != SIDECAR_MAGIC) return;
    if (blob[4] != SIDECAR_VERSION) return;
    cs.level = blob[5];
    cs.class = blob[6];
    cs.status = blob[7];
    cs.strength = std.mem.readInt(u16, blob[8..10], .little);
    cs.dexterity = std.mem.readInt(u16, blob[10..12], .little);
    cs.vitality = std.mem.readInt(u16, blob[12..14], .little);
    cs.energy = std.mem.readInt(u16, blob[14..16], .little);
    cs.max_hp = std.mem.readInt(u16, blob[16..18], .little);
    cs.waypoints = std.mem.readInt(u64, blob[18..26], .little);
    @memcpy(&cs.quests.bits, blob[26..SIDECAR_LEN]);
}

/// Overlay a loaded CharSave onto a live player Unit (the join path's applySave).
pub fn applyToUnit(u: *Unit, cs: CharSave) void {
    u.set(.level, cs.level);
    u.class_id = cs.class;
    u.set(.strength, cs.strength);
    u.set(.dexterity, cs.dexterity);
    u.set(.vitality, cs.vitality);
    u.set(.energy, cs.energy);
    u.set(.maxhp, cs.max_hp);
    u.setLife(cs.max_hp);
}

/// Capture a player Unit's persistable stats into a CharSave with the given quest state (the
/// leave path). Waypoints are not sourced from the Unit (the host carries them separately).
pub fn fromUnit(u: *const Unit, quests: QuestState) CharSave {
    return .{
        .level = @intCast(@max(1, @min(99, u.get(.level)))),
        .class = @intCast(@min(6, u.class_id)),
        .status = 0x21,
        .strength = statU16(u, .strength),
        .dexterity = statU16(u, .dexterity),
        .vitality = statU16(u, .vitality),
        .energy = statU16(u, .energy),
        .max_hp = statU16(u, .maxhp),
        .quests = quests,
    };
}

fn statU16(u: *const Unit, s: Stat) u16 {
    return @intCast(@max(0, @min(0xFFFF, u.get(s))));
}

const testing = std.testing;

test "quest bitfield set/clear/count" {
    var q = QuestState{};
    try testing.expect(!q.isDone(5));
    q.setDone(5, true);
    q.setDone(40, true);
    try testing.expect(q.isDone(5));
    try testing.expect(q.isDone(40));
    try testing.expectEqual(@as(u32, 2), q.count());
    q.setDone(5, false);
    try testing.expect(!q.isDone(5));
    try testing.expectEqual(@as(u32, 1), q.count());
}

test "sidecar round-trips stats, waypoints and quests" {
    var cs = CharSave{ .level = 30, .class = 2, .strength = 111, .max_hp = 640, .waypoints = 0x1234 };
    cs.quests.setDone(1, true);
    cs.quests.setDone(50, true);
    var blob: [SIDECAR_LEN]u8 = undefined;
    writeSidecar(&blob, cs);

    var out = CharSave{};
    readSidecar(&blob, &out);
    try testing.expectEqual(@as(u8, 30), out.level);
    try testing.expectEqual(@as(u8, 2), out.class);
    try testing.expectEqual(@as(u16, 111), out.strength);
    try testing.expectEqual(@as(u16, 640), out.max_hp);
    try testing.expectEqual(@as(u64, 0x1234), out.waypoints);
    try testing.expect(out.quests.isDone(1));
    try testing.expect(out.quests.isDone(50));
    try testing.expect(!out.quests.isDone(2));
}

test "readSidecar ignores a bad magic / short blob" {
    var cs = CharSave{ .level = 7 };
    readSidecar(&[_]u8{ 1, 2, 3 }, &cs); // too short
    try testing.expectEqual(@as(u8, 7), cs.level);
    var blob: [SIDECAR_LEN]u8 = [_]u8{0} ** SIDECAR_LEN; // zero magic
    readSidecar(&blob, &cs);
    try testing.expectEqual(@as(u8, 7), cs.level);
}

test "applyToUnit / fromUnit map the persisted stats onto a Unit and back" {
    var cs = CharSave{ .level = 42, .class = 1, .strength = 77, .dexterity = 55, .vitality = 33, .energy = 22, .max_hp = 500 };
    cs.quests.setDone(3, true);

    var u = Unit.init(.player);
    applyToUnit(&u, cs);
    try testing.expectEqual(@as(i32, 42), u.get(.level));
    try testing.expectEqual(@as(u32, 1), u.class_id);
    try testing.expectEqual(@as(i32, 77), u.get(.strength));
    try testing.expectEqual(@as(i32, 500), u.get(.maxhp));
    try testing.expectEqual(@as(i32, 500), u.life());

    const back = fromUnit(&u, cs.quests);
    try testing.expectEqual(@as(u8, 42), back.level);
    try testing.expectEqual(@as(u16, 77), back.strength);
    try testing.expectEqual(@as(u16, 500), back.max_hp);
    try testing.expect(back.quests.isDone(3));
}

test "fromUnit clamps level to [1,99] and class to <=6" {
    var u = Unit.init(.player);
    u.set(.level, 250);
    u.class_id = 99;
    const cs = fromUnit(&u, .{});
    try testing.expectEqual(@as(u8, 99), cs.level);
    try testing.expectEqual(@as(u8, 6), cs.class);
}
