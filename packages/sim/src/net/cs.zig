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
    pick_up_item = 0x16, // D2GSPacketClt0x16_PickUpItem (13)  <- SCMD_0x16 pick/interact-ext
    select_skill = 0x3C, // D2GSPacketClt0x3C_SetSkill (9)  <- picks the hand's active skill
    chat_message = 0x15, // D2GSPacketClt0x15_ChatMessage (variable)
    _,
};

const DecodeError = error{ ShortBuffer, WrongOpcode };

/// Authoritative C->S (client->server) fixed packet-size table, ported byte-exact from the 1.14d
/// engine global `NET_D2GS_CLIENT_OUTGOING_SIZE @0x00730dc0` (indexed by opcode, int32 stride) —
/// consumed by `NET_D2GS_CLIENT_GetOutgoingPacketSizeFromTableAndVariableSize @0x0052...`. This is
/// the SERVER's incoming framing table: given the leading opcode byte, it yields the total wire
/// size of the packet including the opcode. A value of -1 means the packet is variable-length and
/// must be scanned (see `sizeOf`); 0 means the opcode has no fixed size / is unused (the engine
/// treats that as a framing error). Range is 0x00..0x70 inclusive (113 entries); opcode 0xFF is a
/// special 16-byte control packet the engine sizes outside this table.
///
/// Do NOT hand-edit individual values: they are the exact bytes from Game.exe. If the engine ever
/// disagrees, re-dump `NET_D2GS_CLIENT_OUTGOING_SIZE` and replace the whole array.
pub const OUTGOING_SIZE = [113]i16{
    0,  5,  9,  5,  9,  5,  9,  9, // 0x00-0x07
    5,  9,  9,  1,  5,  9,  9,  5, // 0x08-0x0F
    9,  9,  1,  9,  -1, -1, 13, 5, // 0x10-0x17
    17, 5,  9,  9,  3,  9,  9,  17, // 0x18-0x1F
    13, 9,  5,  9,  5,  9,  13, 9, // 0x20-0x27
    9,  9,  9,  0,  0,  1,  3,  9, // 0x28-0x2F
    9,  9,  17, 17, 5,  17, 9,  5, // 0x30-0x37
    13, 5,  3,  3,  9,  5,  5,  3, // 0x38-0x3F
    1,  1,  1,  1,  17, 9,  13, 13, // 0x40-0x47
    1,  9,  0,  9,  5,  3,  0,  7, // 0x48-0x4F
    9,  9,  5,  1,  1,  0,  0,  0, // 0x50-0x57
    3,  17, 0,  0,  0,  7,  6,  5, // 0x58-0x5F
    1,  3,  5,  5,  0,  0,  -1, 46, // 0x60-0x67
    37, 1,  1,  1,  -1, 13, 1,  0, // 0x68-0x6F
    1, // 0x70
};

/// Size a C->S packet by its leading opcode, mirroring the engine's incoming framer exactly.
/// Returns:
///   - `null`  — the full packet is not present in `buf` yet (need more bytes).
///   - `0`     — genuinely unknown/unframeable opcode (a framing/desync error); caller decides.
///   - `n>0`   — the total packet byte length (opcode included).
///
/// Fixed sizes come straight from `OUTGOING_SIZE`. The four variable-length opcodes are scanned
/// like the engine's switch (`GetOutgoingPacketSizeFromTableAndVariableSize`):
///   - 0x14 OverheadMessage / 0x15 ChatMessage: 4-byte header + NUL-terminated msg + NUL-terminated
///     target string.
///   - 0x66 (warden/data): `3 + u16@1` (length prefix at offset 1, capped at 0x1FD).
///   - 0x6C (variable NPC/skill): `7 + u16@1`.
/// Opcode 0xFF is the engine's 16-byte control packet.
pub fn sizeOf(buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const op = buf[0];
    if (op == 0xFF) return if (buf.len < 16) null else 16;
    if (op > 0x70) return 0;
    const entry = OUTGOING_SIZE[op];
    if (entry > 0) {
        const n: usize = @intCast(entry);
        return if (buf.len < n) null else n;
    }
    if (entry == 0) return 0; // unknown/unused opcode
    // entry == -1: variable-length, scan per-opcode.
    return switch (op) {
        0x14, 0x15 => scanStringPacket(buf), // overhead / chat: header + two NUL-terminated strings
        0x66 => scanLenPrefixed(buf, 1, 3, 0x1FD),
        0x6C => scanLenPrefixed(buf, 1, 7, null),
        else => 0,
    };
}

/// Scan a `[op][3-byte header][msg\0][target\0]` variable packet (0x14/0x15). The header is a fixed
/// 4 bytes total (opcode + 3), then the message string, then the target string, each NUL-terminated.
fn scanStringPacket(buf: []const u8) ?usize {
    const HDR = 4;
    if (buf.len < HDR + 1) return null; // need at least header + one NUL to look for a terminator
    const msg_end = std.mem.indexOfScalarPos(u8, buf, HDR, 0) orelse return null;
    const tgt_end = std.mem.indexOfScalarPos(u8, buf, msg_end + 1, 0) orelse return null;
    return tgt_end + 1;
}

/// Scan a length-prefixed variable packet: total = `overhead + u16@lenoff`, capped at `cap` if given.
fn scanLenPrefixed(buf: []const u8, lenoff: usize, overhead: usize, cap: ?u16) ?usize {
    if (buf.len < lenoff + 2) return null;
    var body = std.mem.readInt(u16, buf[lenoff..][0..2], .little);
    if (cap) |c| {
        if (body > c) body = 0;
    }
    const n = overhead + @as(usize, body);
    return if (buf.len < n) null else n;
}

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

/// 0x16 PickUpItem — D2GSPacketClt0x16_PickUpItem. The extended pick/interact command:
/// `[nCmd u8][eUnitType u32][dwTargetGUID u32][bParam u32]` (13 bytes). Server dispatch is
/// SCMD_0x16_InteractWithEntityEx @0x54aad0 -> SERVER_InteractOrPick(unit, type, guid,
/// bParam): for an ITEM target it picks the item up (`bParam` = to-cursor flag), for an
/// OBJECT it operates it, for an NPC it opens interaction. Self-interaction on a player is
/// rejected. Distinct from 0x13 InteractWithEntity (9 bytes) which the host uses for warps.
pub const PickUpItem = struct {
    pub const OPCODE: u8 = @intFromEnum(Op.pick_up_item);
    pub const SIZE: usize = 13;

    unit_type: u32 = 0, // eD2UnitType of the target (4 = item)
    guid: u32 = 0, // dwTargetGUID
    to_cursor: u32 = 1, // bParam: pick to cursor (1) vs place directly (0)

    pub fn encode(self: PickUpItem, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..5], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..9], self.guid, .little);
        std.mem.writeInt(u32, out[9..13], self.to_cursor, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!PickUpItem {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..5], .little),
            .guid = std.mem.readInt(u32, buf[5..9], .little),
            .to_cursor = std.mem.readInt(u32, buf[9..13], .little),
        };
    }
};

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

test "PickUpItem 0x16 round-trips byte-exact (13 bytes)" {
    var buf: [16]u8 = undefined;
    const p = PickUpItem{ .unit_type = 4, .guid = 0xCAFEBABE, .to_cursor = 1 };
    const wire = p.encode(&buf);
    try std.testing.expectEqual(@as(usize, 13), wire.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x16, 4, 0, 0, 0, 0xBE, 0xBA, 0xFE, 0xCA, 1, 0, 0, 0 }, wire);
    try std.testing.expectEqual(p, try PickUpItem.decode(wire));
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

test "sizeOf: fixed opcodes match the engine size table exactly" {
    const many = 128; // plenty of trailing bytes so sizeOf never returns null for a present packet
    var buf: [many]u8 = undefined;
    // A representative spread of fixed sizes across the whole 0x00..0x70 range.
    const cases = [_]struct { op: u8, size: usize }{
        .{ .op = 0x01, .size = 5 }, // walk-to-location
        .{ .op = 0x02, .size = 9 }, // walk-to-entity
        .{ .op = 0x06, .size = 9 }, // left-skill-on-entity (attack)
        .{ .op = 0x0B, .size = 1 }, // keepalive
        .{ .op = 0x16, .size = 13 }, // pick-up-item
        .{ .op = 0x18, .size = 17 },
        .{ .op = 0x3C, .size = 9 }, // select-skill
        .{ .op = 0x4F, .size = 7 },
        .{ .op = 0x5E, .size = 6 },
        .{ .op = 0x67, .size = 46 },
        .{ .op = 0x68, .size = 37 }, // GAMELOGON
        .{ .op = 0x69, .size = 1 },
        .{ .op = 0x6A, .size = 1 }, // ping
        .{ .op = 0x6B, .size = 1 }, // ENTERGAME
        .{ .op = 0x6D, .size = 13 },
        .{ .op = 0x70, .size = 1 },
    };
    for (cases) |c| {
        buf[0] = c.op;
        try std.testing.expectEqual(@as(?usize, c.size), sizeOf(buf[0..]));
    }
}

test "sizeOf: 0xFF control packet is 16 bytes, out-of-range/unused opcodes are unknown (0)" {
    var buf: [16]u8 = [_]u8{0} ** 16;
    buf[0] = 0xFF;
    try std.testing.expectEqual(@as(?usize, 16), sizeOf(buf[0..]));
    // out of table range
    buf[0] = 0x71;
    try std.testing.expectEqual(@as(?usize, 0), sizeOf(buf[0..]));
    buf[0] = 0xF0;
    try std.testing.expectEqual(@as(?usize, 0), sizeOf(buf[0..]));
    // in-range but unused (table entry 0)
    buf[0] = 0x2B;
    try std.testing.expectEqual(@as(?usize, 0), sizeOf(buf[0..]));
}

test "sizeOf: variable-length opcodes scan correctly (chat 0x15, 0x66, 0x6C)" {
    // 0x15 chat: [op][3 hdr][msg\0][target\0]
    const chat = [_]u8{ 0x15, 1, 2, 3 } ++ "hi\x00" ++ "Bob\x00";
    const chat_slice: []const u8 = chat[0..];
    try std.testing.expectEqual(@as(?usize, chat.len), sizeOf(chat_slice));
    // truncated chat (no target terminator yet) => need more bytes
    try std.testing.expectEqual(@as(?usize, null), sizeOf(chat_slice[0 .. chat.len - 1]));
    // 0x66: total = 3 + u16@1
    const p66 = [_]u8{ 0x66, 4, 0 } ++ [_]u8{0xAB} ** 4;
    try std.testing.expectEqual(@as(?usize, 7), sizeOf(p66[0..]));
    // 0x6C: total = 7 + u16@1
    const p6c = [_]u8{ 0x6C, 2, 0 } ++ [_]u8{0} ** 6;
    try std.testing.expectEqual(@as(?usize, 9), sizeOf(p6c[0..]));
}

test "sizeOf: incomplete fixed packet returns null (need more bytes)" {
    // 0x68 GAMELOGON wants 37 bytes; give it 10.
    var buf: [10]u8 = [_]u8{0} ** 10;
    buf[0] = 0x68;
    try std.testing.expectEqual(@as(?usize, null), sizeOf(buf[0..]));
}

test "sizeOf: a realistic C->S join handshake buffer frames cleanly and reaches ENTERGAME" {
    // Reproduce the shape the real 1.14d client sends on join: GAMELOGON (0x68, 37) then a run of
    // fixed-size C->S packets, then the ping (0x6A) + ENTERGAME (0x6B). Prior to the full table these
    // interior opcodes returned 0 and nuked the whole buffer (dropping ENTERGAME). Walk the buffer the
    // way server.zig does and assert every packet frames and the last opcode is ENTERGAME.
    const alloc = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    // GAMELOGON (0x68 = 37)
    try bytes.append(alloc, 0x68);
    try bytes.appendNTimes(alloc, 0, 36);
    // A plausible run of join-time fixed packets (opcodes the client emits post-logon):
    const interior = [_]u8{ 0x4B, 0x40, 0x53, 0x60, 0x59 }; // 9,1,1,1,17
    for (interior) |op| {
        const n: usize = @intCast(OUTGOING_SIZE[op]);
        try bytes.append(alloc, op);
        try bytes.appendNTimes(alloc, 0, n - 1);
    }
    // ping + ENTERGAME
    try bytes.append(alloc, 0x6A);
    try bytes.append(alloc, 0x6B);
    const items = bytes.items;
    var off: usize = 0;
    var last_op: u8 = 0;
    while (off < items.len) {
        const n = sizeOf(items[off..]) orelse return error.NeedMoreBytes;
        try std.testing.expect(n != 0); // no desync anywhere in the handshake
        last_op = items[off];
        off += n;
    }
    try std.testing.expectEqual(items.len, off); // consumed exactly, no leftover
    try std.testing.expectEqual(@as(u8, 0x6B), last_op); // ENTERGAME survived to the end
}
