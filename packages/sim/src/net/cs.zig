//! Client -> server game commands (the D2GS "Recv" / SCMD_0xNN opcode space, 1.14d).
//!
//! Wire layouts are ported byte-exact from the Ghidra-typed `D2GSPacketClt0xNN_*` structs in
//! `/Diablo2/NETWORK/D2GS/SERVERSIDE/Recv` (session 62fbfe69). The server dispatches these in
//! `SCMD_ProcessIncomingPacketBuffer @0x0045FA40` / `NET_D2GS_CLIENT_PacketHandle`. Every packet
//! begins with a 1-byte opcode (`nCmd`); multi-byte integers are little-endian (x86).
//!
//! "attack" is NOT a distinct opcode: an attack is `LeftSkillOnEntity (0x06)` (or right-skill
//! 0x0D) carrying the attack skill against a target unit. See DESIGN note at the bottom.

const std = @import("std");

/// Client->server opcodes (subset the sim models). Names/values from the 1.14d Recv structs.
pub const Op = enum(u8) {
    walk_to_location = 0x01, // D2GSPacketClt0x01_WalkToLocation (5)
    walk_to_entity = 0x02, // D2GSPacketClt0x02_WalkToEntity   (9)
    run_to_location = 0x03, // D2GSPacketClt0x03_RunToLocation  (5)
    run_to_entity = 0x04, // D2GSPacketClt0x04_RunToEntity    (9)
    left_skill_on_location = 0x05, // D2GSPacketClt0x05 (5)
    left_skill_on_entity = 0x06, // D2GSPacketClt0x06 (9)  <- "attack" lives here
    right_skill_on_location = 0x0C, // D2GSPacketClt0x0C (5)
    right_skill_on_entity = 0x0D, // D2GSPacketClt0x0D (9)
    interact_with_entity = 0x13, // D2GSPacketClt0x13_InteractWithEntity (9)
    select_skill = 0x3C, // D2GSPacketClt0x3C_SetSkill (9)  <- picks the hand's active skill
    chat_message = 0x15, // D2GSPacketClt0x15_ChatMessage (variable)
    _,
};

const DecodeError = error{ ShortBuffer, WrongOpcode };

/// A command that targets a map coordinate: `[nCmd u8][wX u16][wY u16]` (5 bytes).
/// Shared shape of Clt 0x01/0x03/0x05/0x08/0x0C/0x0F (all "…OnLocation").
pub fn CoordCmd(comptime op: Op) type {
    return struct {
        const Self = @This();
        pub const OPCODE: u8 = @intFromEnum(op);
        pub const SIZE: usize = 5;

        x: u16 = 0,
        y: u16 = 0,

        pub fn encode(self: Self, out: []u8) []u8 {
            std.debug.assert(out.len >= SIZE);
            out[0] = OPCODE;
            std.mem.writeInt(u16, out[1..3], self.x, .little);
            std.mem.writeInt(u16, out[3..5], self.y, .little);
            return out[0..SIZE];
        }

        pub fn decode(buf: []const u8) DecodeError!Self {
            if (buf.len < SIZE) return error.ShortBuffer;
            if (buf[0] != OPCODE) return error.WrongOpcode;
            return .{
                .x = std.mem.readInt(u16, buf[1..3], .little),
                .y = std.mem.readInt(u16, buf[3..5], .little),
            };
        }
    };
}

/// A command that targets a unit: `[nCmd u8][eUnitType u32][dwUnitGUID u32]` (9 bytes).
/// Shared shape of Clt 0x02/0x04/0x06/0x07/0x0D/0x13 (all "…OnEntity" / Interact).
pub fn EntityCmd(comptime op: Op) type {
    return struct {
        const Self = @This();
        pub const OPCODE: u8 = @intFromEnum(op);
        pub const SIZE: usize = 9;

        unit_type: u32 = 0, // eD2UnitType (0=player,1=monster,2=object,3=missile,4=item,5=warp)
        guid: u32 = 0,

        pub fn encode(self: Self, out: []u8) []u8 {
            std.debug.assert(out.len >= SIZE);
            out[0] = OPCODE;
            std.mem.writeInt(u32, out[1..5], self.unit_type, .little);
            std.mem.writeInt(u32, out[5..9], self.guid, .little);
            return out[0..SIZE];
        }

        pub fn decode(buf: []const u8) DecodeError!Self {
            if (buf.len < SIZE) return error.ShortBuffer;
            if (buf[0] != OPCODE) return error.WrongOpcode;
            return .{
                .unit_type = std.mem.readInt(u32, buf[1..5], .little),
                .guid = std.mem.readInt(u32, buf[5..9], .little),
            };
        }
    };
}

pub const WalkToLocation = CoordCmd(.walk_to_location);
pub const RunToLocation = CoordCmd(.run_to_location);
pub const LeftSkillOnLocation = CoordCmd(.left_skill_on_location);
pub const RightSkillOnLocation = CoordCmd(.right_skill_on_location);

/// 0x3C SetSkill — the client selecting the active skill for a hand. Wire layout
/// `[nCmd u8][dwSkill u32][dwItemGUID u32]` (9): the top bit of dwSkill (0x80000000)
/// marks the LEFT hand (else right), the low bits are the eD2SkillId; dwItemGUID is
/// the granting item (0xFFFFFFFF = a natural/class skill). Cross-checked against the
/// client sender in d2gs engine/d2/functions.zig `sendSelectSkill` (0x3C emit). The
/// server records this as the player's per-hand active skill; a later left/right
/// skill-on-location/entity cast (0x05/0x06/0x0C/0x0D) uses it — those carry NO skill
/// id themselves.
pub const SelectSkill = struct {
    pub const OPCODE: u8 = @intFromEnum(Op.select_skill);
    pub const SIZE: usize = 9;
    pub const LEFT_BIT: u32 = 0x8000_0000;

    skill_id: u16 = 0,
    left: bool = false,
    item_guid: u32 = 0xFFFF_FFFF,

    pub fn encode(self: SelectSkill, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        var skill_val: u32 = self.skill_id;
        if (self.left) skill_val |= LEFT_BIT;
        std.mem.writeInt(u32, out[1..5], skill_val, .little);
        std.mem.writeInt(u32, out[5..9], self.item_guid, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!SelectSkill {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const skill_val = std.mem.readInt(u32, buf[1..5], .little);
        return .{
            .skill_id = @truncate(skill_val & ~LEFT_BIT),
            .left = (skill_val & LEFT_BIT) != 0,
            .item_guid = std.mem.readInt(u32, buf[5..9], .little),
        };
    }
};

pub const WalkToEntity = EntityCmd(.walk_to_entity);
pub const RunToEntity = EntityCmd(.run_to_entity);
pub const LeftSkillOnEntity = EntityCmd(.left_skill_on_entity);
pub const RightSkillOnEntity = EntityCmd(.right_skill_on_entity);
pub const InteractWithEntity = EntityCmd(.interact_with_entity);

/// 0x15 ChatMessage — D2GSPacketClt0x15_ChatMessage. Fixed 4-byte header then the message
/// string (max 256) followed by the target name string (max 16), each NUL-terminated. An empty
/// target => broadcast to the game; a non-empty target => whisper. Wire size is variable:
/// 4 + msg.len+1 + target.len+1.
pub const ChatMessage = struct {
    pub const OPCODE: u8 = @intFromEnum(Op.chat_message);
    pub const HEADER: usize = 4;
    pub const MAX_MSG: usize = 256;
    pub const MAX_TARGET: usize = 16;

    msg_id: u8 = 0,
    msg_type: u8 = 0,
    locale: u8 = 0,
    msg: []const u8 = "",
    target: []const u8 = "", // empty = broadcast, else whisper recipient name

    pub fn wireLen(self: ChatMessage) usize {
        return HEADER + self.msg.len + 1 + self.target.len + 1;
    }

    pub fn encode(self: ChatMessage, out: []u8) []u8 {
        std.debug.assert(self.msg.len < MAX_MSG and self.target.len < MAX_TARGET);
        const n = self.wireLen();
        std.debug.assert(out.len >= n);
        out[0] = OPCODE;
        out[1] = self.msg_id;
        out[2] = self.msg_type;
        out[3] = self.locale;
        var i: usize = HEADER;
        @memcpy(out[i..][0..self.msg.len], self.msg);
        i += self.msg.len;
        out[i] = 0;
        i += 1;
        @memcpy(out[i..][0..self.target.len], self.target);
        i += self.target.len;
        out[i] = 0;
        return out[0..n];
    }

    /// Decode borrows the message/target slices out of `buf` (no allocation).
    pub fn decode(buf: []const u8) DecodeError!ChatMessage {
        if (buf.len < HEADER + 2) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const msg_end = std.mem.indexOfScalarPos(u8, buf, HEADER, 0) orelse return error.ShortBuffer;
        const tgt_start = msg_end + 1;
        const tgt_end = std.mem.indexOfScalarPos(u8, buf, tgt_start, 0) orelse return error.ShortBuffer;
        return .{
            .msg_id = buf[1],
            .msg_type = buf[2],
            .locale = buf[3],
            .msg = buf[HEADER..msg_end],
            .target = buf[tgt_start..tgt_end],
        };
    }
};

test "CoordCmd 0x01 walk-to-location round-trips byte-exact" {
    const p = WalkToLocation{ .x = 5000, .y = 6001 };
    var buf: [8]u8 = undefined;
    const wire = p.encode(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x88, 0x13, 0x71, 0x17 }, wire);
    const d = try WalkToLocation.decode(wire);
    try std.testing.expectEqual(p, d);
}

test "run-to-location uses opcode 0x03, right-skill 0x0C" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 0x03), RunToLocation.encode(.{ .x = 1, .y = 2 }, &buf)[0]);
    try std.testing.expectEqual(@as(u8, 0x0C), RightSkillOnLocation.encode(.{ .x = 1, .y = 2 }, &buf)[0]);
}

test "EntityCmd 0x02 walk-to-entity round-trips (type u32, guid u32, LE)" {
    const p = WalkToEntity{ .unit_type = 1, .guid = 0xDEADBEEF };
    var buf: [12]u8 = undefined;
    const wire = p.encode(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 1, 0, 0, 0, 0xEF, 0xBE, 0xAD, 0xDE }, wire);
    try std.testing.expectEqual(p, try WalkToEntity.decode(wire));
}

test "interact 0x13 + attack==left-skill-on-entity 0x06" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqual(@as(u8, 0x13), InteractWithEntity.encode(.{ .unit_type = 1, .guid = 7 }, &buf)[0]);
    // an attack is a left-skill cast against a unit:
    const atk = LeftSkillOnEntity{ .unit_type = 1, .guid = 0x1234 };
    const wire = atk.encode(&buf);
    try std.testing.expectEqual(@as(u8, 0x06), wire[0]);
    try std.testing.expectEqual(atk, try LeftSkillOnEntity.decode(wire));
}

test "SelectSkill 0x3C round-trips with the left-hand bit" {
    var buf: [12]u8 = undefined;
    const left = SelectSkill{ .skill_id = 36, .left = true };
    const wl = left.encode(&buf);
    try std.testing.expectEqual(@as(u8, 0x3C), wl[0]);
    try std.testing.expectEqual(@as(usize, 9), wl.len);
    const dl = try SelectSkill.decode(wl);
    try std.testing.expectEqual(@as(u16, 36), dl.skill_id);
    try std.testing.expect(dl.left);
    // right-hand: top bit clear
    const right = SelectSkill{ .skill_id = 6, .left = false, .item_guid = 0 };
    const dr = try SelectSkill.decode(right.encode(&buf));
    try std.testing.expectEqual(@as(u16, 6), dr.skill_id);
    try std.testing.expect(!dr.left);
}

test "chat broadcast + whisper round-trip (variable length)" {
    var buf: [300]u8 = undefined;
    const b = ChatMessage{ .msg = "hello world", .msg_id = 1 };
    const wb = b.encode(&buf);
    try std.testing.expectEqual(@as(usize, 4 + 11 + 1 + 0 + 1), wb.len);
    const db = try ChatMessage.decode(wb);
    try std.testing.expectEqualStrings("hello world", db.msg);
    try std.testing.expectEqualStrings("", db.target);
    try std.testing.expectEqual(@as(u8, 1), db.msg_id);

    const w = ChatMessage{ .msg = "hi", .target = "Bob" };
    const ww = w.encode(&buf);
    const dw = try ChatMessage.decode(ww);
    try std.testing.expectEqualStrings("hi", dw.msg);
    try std.testing.expectEqualStrings("Bob", dw.target);
}

test "decode rejects wrong opcode and short buffers" {
    try std.testing.expectError(error.WrongOpcode, WalkToLocation.decode(&[_]u8{ 0x02, 0, 0, 0, 0 }));
    try std.testing.expectError(error.ShortBuffer, WalkToEntity.decode(&[_]u8{ 0x02, 0, 0 }));
}
