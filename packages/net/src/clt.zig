//! Client -> server game commands, 1.14d — every command the server dispatches.
//!
//! One struct per `SCMD_0xNN_*` handler, laid out from the `D2GSPacketClt0xNN_*` packet
//! structs recovered in Ghidra (session 62fbfe69, Game.exe 1.14d). Field offsets are the
//! recovered ones, so `encode` produces exactly the bytes the server's handler reads and
//! `decode` accepts exactly what it accepts. Generated — see scripts/gen_clt.py.
//!
//! Every packet exposes `OPCODE`, `SIZE` (wire size including the opcode byte), an
//! `encode(out) []u8` and a `decode(buf) !Self`. Trailing-string packets carry a `text`
//! slice instead of a fixed SIZE and expose `wireLen()`.

const std = @import("std");

pub const DecodeError = error{ ShortBuffer, WrongOpcode };

/// 0x01 — SCMD_0x01_WalkToLocation. `D2GSPacketClt0x01_WalkToLocation`.
pub const WalkToLocation = struct {
    pub const OPCODE: u8 = 0x01;
    pub const SIZE: usize = 5;
    x: u16 = 0, // +0x01
    y: u16 = 0, // +0x03

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.x, .little);
        std.mem.writeInt(u16, out[3..][0..2], self.y, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .x = std.mem.readInt(u16, buf[1..][0..2], .little),
            .y = std.mem.readInt(u16, buf[3..][0..2], .little),
        };
    }
};

/// 0x02 — SCMD_0x02_WalkToEntity. `D2GSPacketClt0x02_WalkToEntity`.
pub const WalkToEntity = struct {
    pub const OPCODE: u8 = 0x02;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    unit_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.unit_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .unit_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x03 — SCMD_0x03_RunToLocation. `D2GSPacketClt0x03_RunToLocation`.
pub const RunToLocation = struct {
    pub const OPCODE: u8 = 0x03;
    pub const SIZE: usize = 5;
    x: u16 = 0, // +0x01
    y: u16 = 0, // +0x03

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.x, .little);
        std.mem.writeInt(u16, out[3..][0..2], self.y, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .x = std.mem.readInt(u16, buf[1..][0..2], .little),
            .y = std.mem.readInt(u16, buf[3..][0..2], .little),
        };
    }
};

/// 0x04 — SCMD_0x04_RunToEntity. `D2GSPacketClt0x04_RunToEntity`.
pub const RunToEntity = struct {
    pub const OPCODE: u8 = 0x04;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    unit_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.unit_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .unit_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x05 — SCMD_0x05_LeftSkillOnLocation. `D2GSPacketClt0x05_LeftSkillOnLocation`.
pub const LeftSkillOnLocation = struct {
    pub const OPCODE: u8 = 0x05;
    pub const SIZE: usize = 5;
    x: u16 = 0, // +0x01
    y: u16 = 0, // +0x03

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.x, .little);
        std.mem.writeInt(u16, out[3..][0..2], self.y, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .x = std.mem.readInt(u16, buf[1..][0..2], .little),
            .y = std.mem.readInt(u16, buf[3..][0..2], .little),
        };
    }
};

/// 0x06 — SCMD_0x06_LeftSkillOnEntity. `D2GSPacketClt0x06_LeftSkillOnEntity`.
pub const LeftSkillOnEntity = struct {
    pub const OPCODE: u8 = 0x06;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    unit_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.unit_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .unit_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x07 — SCMD_0x07_LeftSkillOnEntityEx. `D2GSPacketClt0x07_LeftSkillOnEntityEx`.
pub const LeftSkillOnEntityEx = struct {
    pub const OPCODE: u8 = 0x07;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    unit_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.unit_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .unit_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x08 — SCMD_0x08_LeftSkillOnLocationEx. `D2GSPacketClt0x08_LeftSkillOnLocationEx`.
pub const LeftSkillOnLocationEx = struct {
    pub const OPCODE: u8 = 0x08;
    pub const SIZE: usize = 5;
    x: u16 = 0, // +0x01
    y: u16 = 0, // +0x03

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.x, .little);
        std.mem.writeInt(u16, out[3..][0..2], self.y, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .x = std.mem.readInt(u16, buf[1..][0..2], .little),
            .y = std.mem.readInt(u16, buf[3..][0..2], .little),
        };
    }
};

/// 0x09 — SCMD_0x09_LeftSkillOnEntityEx2. `D2GSPacketClt0x09_LeftSkillOnEntityEx2`.
pub const LeftSkillOnEntityEx2 = struct {
    pub const OPCODE: u8 = 0x09;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    unit_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.unit_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .unit_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x0A — SCMD_0x0A_LeftSkillOnEntityEx3. `D2GSPacketClt0x0A_LeftSkillOnEntityEx3`.
pub const LeftSkillOnEntityEx3 = struct {
    pub const OPCODE: u8 = 0x0a;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    unit_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.unit_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .unit_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x0B — SCMD_0x0B_Keepalive. `D2GSPacketClt0x0B_Keepalive`.
pub const Keepalive = struct {
    pub const OPCODE: u8 = 0x0b;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x0C — SCMD_0x0C_RightSkillOnLocation. `D2GSPacketClt0x0C_RightSkillOnLocation`.
pub const RightSkillOnLocation = struct {
    pub const OPCODE: u8 = 0x0c;
    pub const SIZE: usize = 5;
    x: u16 = 0, // +0x01
    y: u16 = 0, // +0x03

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.x, .little);
        std.mem.writeInt(u16, out[3..][0..2], self.y, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .x = std.mem.readInt(u16, buf[1..][0..2], .little),
            .y = std.mem.readInt(u16, buf[3..][0..2], .little),
        };
    }
};

/// 0x0D — SCMD_0x0D_RightSkillOnEntity. `D2GSPacketClt0x0D_RightSkillOnEntity`.
pub const RightSkillOnEntity = struct {
    pub const OPCODE: u8 = 0x0d;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x0E — SCMD_0x0E_RightSkillOnEntityEx. `D2GSPacketClt0x0E_RightSkillOnEntityEx`.
pub const RightSkillOnEntityEx = struct {
    pub const OPCODE: u8 = 0x0e;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x0F — SCMD_0x0F_RightSkillOnLocationEx. `D2GSPacketClt0x0F_RightSkillOnLocationEx`.
pub const RightSkillOnLocationEx = struct {
    pub const OPCODE: u8 = 0x0f;
    pub const SIZE: usize = 5;
    x: u16 = 0, // +0x01
    y: u16 = 0, // +0x03

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.x, .little);
        std.mem.writeInt(u16, out[3..][0..2], self.y, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .x = std.mem.readInt(u16, buf[1..][0..2], .little),
            .y = std.mem.readInt(u16, buf[3..][0..2], .little),
        };
    }
};

/// 0x10 — SCMD_0x10_RightSkillOnEntityEx2. `D2GSPacketClt0x10_RightSkillOnEntityEx2`.
pub const RightSkillOnEntityEx2 = struct {
    pub const OPCODE: u8 = 0x10;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x11 — SCMD_0x11_RightSkillOnEntityEx3. `D2GSPacketClt0x11_RightSkillOnEntityEx3`.
pub const RightSkillOnEntityEx3 = struct {
    pub const OPCODE: u8 = 0x11;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x12 — SCMD_0x12_CancelChanneledSkill. `D2GSPacketClt0x12_CancelChanneledSkill`.
pub const CancelChanneledSkill = struct {
    pub const OPCODE: u8 = 0x12;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x13 — SCMD_0x13_InteractWithEntity. `D2GSPacketClt0x13_InteractWithEntity`.
pub const InteractWithEntity = struct {
    pub const OPCODE: u8 = 0x13;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x14 — SCMD_0x14_OverheadMessage. `D2GSPacketClt0x14_OverheadMessage`.
pub const OverheadMessage = struct {
    pub const OPCODE: u8 = 0x14;
    pub const HEADER: usize = 3;
    unk1: u8 = 0, // +0x01
    lang_code: u8 = 0, // +0x02
    msg: []const u8 = "", // +0x03, NUL-terminated on the wire

    pub fn wireLen(self: @This()) usize {
        return HEADER + self.msg.len + 1;
    }

    pub fn encode(self: @This(), out: []u8) []u8 {
        const n = self.wireLen();
        std.debug.assert(out.len >= n);
        @memset(out[0..HEADER], 0);
        out[0] = OPCODE;
        out[1] = self.unk1;
        out[2] = self.lang_code;
        @memcpy(out[HEADER..][0..self.msg.len], self.msg);
        out[HEADER + self.msg.len] = 0;
        return out[0..n];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < HEADER) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const rest = buf[HEADER..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        return .{
            .unk1 = buf[1],
            .lang_code = buf[2],
            .msg = rest[0..end],
        };
    }
};

/// 0x15 — SCMD_0x15_ChatMessage. `D2GSPacketClt0x15_ChatMessage`.
pub const ChatMessage = struct {
    pub const OPCODE: u8 = 0x15;
    pub const HEADER: usize = 4;
    msg_id: u8 = 0, // +0x01
    msg_type: u8 = 0, // +0x02
    locale: u8 = 0, // +0x03
    msg: []const u8 = "", // +0x04, NUL-terminated on the wire

    pub fn wireLen(self: @This()) usize {
        return HEADER + self.msg.len + 1;
    }

    pub fn encode(self: @This(), out: []u8) []u8 {
        const n = self.wireLen();
        std.debug.assert(out.len >= n);
        @memset(out[0..HEADER], 0);
        out[0] = OPCODE;
        out[1] = self.msg_id;
        out[2] = self.msg_type;
        out[3] = self.locale;
        @memcpy(out[HEADER..][0..self.msg.len], self.msg);
        out[HEADER + self.msg.len] = 0;
        return out[0..n];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < HEADER) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const rest = buf[HEADER..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        return .{
            .msg_id = buf[1],
            .msg_type = buf[2],
            .locale = buf[3],
            .msg = rest[0..end],
        };
    }
};

/// 0x16 — SCMD_0x16_InteractWithEntityEx. `D2GSPacketClt0x16_PickUpItem`.
pub const InteractWithEntityEx = struct {
    pub const OPCODE: u8 = 0x16;
    pub const SIZE: usize = 13;
    unit_type: u32 = 0, // +0x01
    target_guid: u32 = 0, // +0x05
    param: i32 = 0, // +0x09

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.target_guid, .little);
        std.mem.writeInt(i32, out[9..][0..4], self.param, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .target_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
            .param = std.mem.readInt(i32, buf[9..][0..4], .little),
        };
    }
};

/// 0x17 — SCMD_0x17_DropItem. `D2GSPacketClt0x17_DropItem`.
pub const DropItem = struct {
    pub const OPCODE: u8 = 0x17;
    pub const SIZE: usize = 5;
    item_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x18 — SCMD_0x18_ItemToInventory. `D2GSPacketClt0x18_InsertItemToBuffer`.
pub const ItemToInventory = struct {
    pub const OPCODE: u8 = 0x18;
    pub const SIZE: usize = 17;
    item_guid: u32 = 0, // +0x01
    x: i32 = 0, // +0x05
    y: i32 = 0, // +0x09
    buffer_id: u32 = 0, // +0x0d

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(i32, out[5..][0..4], self.x, .little);
        std.mem.writeInt(i32, out[9..][0..4], self.y, .little);
        std.mem.writeInt(u32, out[13..][0..4], self.buffer_id, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .x = std.mem.readInt(i32, buf[5..][0..4], .little),
            .y = std.mem.readInt(i32, buf[9..][0..4], .little),
            .buffer_id = std.mem.readInt(u32, buf[13..][0..4], .little),
        };
    }
};

/// 0x19 — SCMD_0x19_PickUpToCursor. `D2GSPacketClt0x19_RemoveItemFromBuffer`.
pub const PickUpToCursor = struct {
    pub const OPCODE: u8 = 0x19;
    pub const SIZE: usize = 5;
    item_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x1A — SCMD_0x1A_EquipItem. `D2GSPacketClt0x1A_EquipItem`.
pub const EquipItem = struct {
    pub const OPCODE: u8 = 0x1a;
    pub const SIZE: usize = 9;
    item_guid: u32 = 0, // +0x01
    body_loc: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.body_loc, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .body_loc = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x1B — SCMD_0x1B_EquipToSwapSlot. `D2GSPacketClt0x1B_UnequipItem`.
pub const EquipToSwapSlot = struct {
    pub const OPCODE: u8 = 0x1b;
    pub const SIZE: usize = 9;
    item_guid: u32 = 0, // +0x01
    body_loc: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.body_loc, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .body_loc = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x1C — SCMD_0x1C_UnequipToInventory. `D2GSPacketClt0x1C_SwapEquippedItem`.
pub const UnequipToInventory = struct {
    pub const OPCODE: u8 = 0x1c;
    pub const SIZE: usize = 3;
    body_loc: u16 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.body_loc, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .body_loc = std.mem.readInt(u16, buf[1..][0..2], .little),
        };
    }
};

/// 0x1D — SCMD_0x1D_SwapBodyItem. `D2GSPacketClt0x1D_Swap2HandItem`.
pub const SwapBodyItem = struct {
    pub const OPCODE: u8 = 0x1d;
    pub const SIZE: usize = 9;
    item_guid: u32 = 0, // +0x01
    body_loc: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.body_loc, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .body_loc = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x1E — SCMD_0x1E_EquipToWeaponSwap. `D2GSPacketClt0x1E_RemoveItemFromBelt`.
pub const EquipToWeaponSwap = struct {
    pub const OPCODE: u8 = 0x1e;
    pub const SIZE: usize = 9;
    item_guid: u32 = 0, // +0x01
    belt_slot: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.belt_slot, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .belt_slot = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x1F — SCMD_0x1F_UseItem. `D2GSPacketClt0x1F_UseItem`.
pub const UseItem = struct {
    pub const OPCODE: u8 = 0x1f;
    pub const SIZE: usize = 17;
    cursor_item_guid: u32 = 0, // +0x01
    target_item_guid: u32 = 0, // +0x05
    target_unit_guid: u32 = 0, // +0x09
    arg: i32 = 0, // +0x0d

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.cursor_item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.target_item_guid, .little);
        std.mem.writeInt(u32, out[9..][0..4], self.target_unit_guid, .little);
        std.mem.writeInt(i32, out[13..][0..4], self.arg, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .cursor_item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .target_item_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
            .target_unit_guid = std.mem.readInt(u32, buf[9..][0..4], .little),
            .arg = std.mem.readInt(i32, buf[13..][0..4], .little),
        };
    }
};

/// 0x20 — SCMD_0x20_UseItemAtLocation. `D2GSPacketClt0x20_StackItem`.
pub const UseItemAtLocation = struct {
    pub const OPCODE: u8 = 0x20;
    pub const SIZE: usize = 13;
    item_guid: u32 = 0, // +0x01
    x: i32 = 0, // +0x05
    y: i32 = 0, // +0x09

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(i32, out[5..][0..4], self.x, .little);
        std.mem.writeInt(i32, out[9..][0..4], self.y, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .x = std.mem.readInt(i32, buf[5..][0..4], .little),
            .y = std.mem.readInt(i32, buf[9..][0..4], .little),
        };
    }
};

/// 0x21 — SCMD_0x21_MergeStackables. `D2GSPacketClt0x21_RemoveStackItem`.
pub const MergeStackables = struct {
    pub const OPCODE: u8 = 0x21;
    pub const SIZE: usize = 9;
    item_guid1: u32 = 0, // +0x01
    item_guid2: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid1, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.item_guid2, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid1 = std.mem.readInt(u32, buf[1..][0..4], .little),
            .item_guid2 = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x22 — SCMD_0x22_UnstackItemStub. `D2GSPacketClt0x22_ItemToBelt`.
pub const UnstackItemStub = struct {
    pub const OPCODE: u8 = 0x22;
    pub const SIZE: usize = 5;
    item_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x23 — SCMD_0x23_ItemToBelt. `D2GSPacketClt0x23_ItemFromBelt`.
pub const ItemToBelt = struct {
    pub const OPCODE: u8 = 0x23;
    pub const SIZE: usize = 9;
    item_guid: u32 = 0, // +0x01
    belt_slot_or_index: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.belt_slot_or_index, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .belt_slot_or_index = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x24 — SCMD_0x24_ItemFromBelt. `D2GSPacketClt0x24_SwapBeltItem`.
pub const ItemFromBelt = struct {
    pub const OPCODE: u8 = 0x24;
    pub const SIZE: usize = 5;
    item_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x25 — SCMD_0x25_SwapBeltItem. `D2GSPacketClt0x25_UseScroll`.
pub const SwapBeltItem = struct {
    pub const OPCODE: u8 = 0x25;
    pub const SIZE: usize = 9;
    item_guid: u32 = 0, // +0x01
    target_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.target_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .target_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x26 — SCMD_0x26_UseItemAtPlayerCoords. `D2GSPacketClt0x26_ItemToCube`.
pub const UseItemAtPlayerCoords = struct {
    pub const OPCODE: u8 = 0x26;
    pub const SIZE: usize = 13;
    item_guid: u32 = 0, // +0x01
    arg: i32 = 0, // +0x05
    unused: u32 = 0, // +0x09

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        std.mem.writeInt(i32, out[5..][0..4], self.arg, .little);
        std.mem.writeInt(u32, out[9..][0..4], self.unused, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .arg = std.mem.readInt(i32, buf[5..][0..4], .little),
            .unused = std.mem.readInt(u32, buf[9..][0..4], .little),
        };
    }
};

/// 0x27 — SCMD_0x27_UseItemOnItem. `D2GSPacketClt0x27_UseItemOnItem`.
pub const UseItemOnItem = struct {
    pub const OPCODE: u8 = 0x27;
    pub const SIZE: usize = 9;
    target_item_guid: u32 = 0, // +0x01
    scroll_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.target_item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.scroll_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .target_item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .scroll_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x28 — SCMD_0x28_SocketItem. `D2GSPacketClt0x28_SocketItem`.
pub const SocketItem = struct {
    pub const OPCODE: u8 = 0x28;
    pub const SIZE: usize = 9;
    gem_guid: u32 = 0, // +0x01
    socketable_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.gem_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.socketable_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .gem_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .socketable_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x29 — SCMD_0x29_ScrollIntoBook. `D2GSPacketClt0x29_ScrollIntoBook`.
pub const ScrollIntoBook = struct {
    pub const OPCODE: u8 = 0x29;
    pub const SIZE: usize = 9;
    scroll_guid: u32 = 0, // +0x01
    book_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.scroll_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.book_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .scroll_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .book_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x2A — SCMD_0x2A_ItemToCube. `D2GSPacketClt0x2A_ItemToCube`.
pub const ItemToCube = struct {
    pub const OPCODE: u8 = 0x2a;
    pub const SIZE: usize = 9;
    cursor_item_guid: u32 = 0, // +0x01
    cube_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.cursor_item_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.cube_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .cursor_item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .cube_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x2C — SCMD_0x2C_DeadStub. `D2GSPacketClt0x2C_DeadStub`.
pub const DeadStub = struct {
    pub const OPCODE: u8 = 0x2c;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x2D — SCMD_0x2D_DeadStub2D. `D2GSPacketClt0x2D_DeadStub`.
pub const DeadStub2D = struct {
    pub const OPCODE: u8 = 0x2d;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x2E — SCMD_0x2E_DeadStub2E. `D2GSPacketClt0x2E_DeadStub`.
///
/// Three bytes, not one. The struct is empty because the handler is a stub that reads nothing,
/// which is a fact about the HANDLER; the framer is a separate table and it sizes 0x2E at 3. Those
/// two disagreeing is how a one-byte packet gets read as three and takes the next two with it.
pub const DeadStub2E = struct {
    pub const OPCODE: u8 = 0x2e;
    pub const SIZE: usize = 3;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x2F — SCMD_0x2F_NpcInteract. `D2GSPacketClt0x2F_NpcRepair`.
pub const NpcInteract = struct {
    pub const OPCODE: u8 = 0x2f;
    pub const SIZE: usize = 9;
    unused: u32 = 0, // +0x01
    npc_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unused, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.npc_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unused = std.mem.readInt(u32, buf[1..][0..4], .little),
            .npc_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x30 — SCMD_0x30_NpcCancelDialog. `D2GSPacketClt0x30_NpcCancelDialog`.
pub const NpcCancelDialog = struct {
    pub const OPCODE: u8 = 0x30;
    pub const SIZE: usize = 9;
    pad: u32 = 0, // +0x01
    npc_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.pad, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.npc_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .pad = std.mem.readInt(u32, buf[1..][0..4], .little),
            .npc_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x31 — SCMD_0x31_NpcGossip. `D2GSPacketClt0x31_NpcGossip`.
pub const NpcGossip = struct {
    pub const OPCODE: u8 = 0x31;
    pub const SIZE: usize = 9;
    npc_guid: u32 = 0, // +0x01
    gossip_id: u16 = 0, // +0x05
    unused: u16 = 0, // +0x07

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.npc_guid, .little);
        std.mem.writeInt(u16, out[5..][0..2], self.gossip_id, .little);
        std.mem.writeInt(u16, out[7..][0..2], self.unused, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .gossip_id = std.mem.readInt(u16, buf[5..][0..2], .little),
            .unused = std.mem.readInt(u16, buf[7..][0..2], .little),
        };
    }
};

/// 0x32 — SCMD_0x32_NpcBuyConfirm. `D2GSPacketClt0x32_NpcBuyConfirm`.
pub const NpcBuyConfirm = struct {
    pub const OPCODE: u8 = 0x32;
    pub const SIZE: usize = 17;
    npc_guid: u32 = 0, // +0x01
    item_guid: u32 = 0, // +0x05
    flags: u32 = 0, // +0x09
    cost: u32 = 0, // +0x0d

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.npc_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.item_guid, .little);
        std.mem.writeInt(u32, out[9..][0..4], self.flags, .little);
        std.mem.writeInt(u32, out[13..][0..4], self.cost, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .item_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
            .flags = std.mem.readInt(u32, buf[9..][0..4], .little),
            .cost = std.mem.readInt(u32, buf[13..][0..4], .little),
        };
    }
};

/// 0x33 — SCMD_0x33_NpcSell. `D2GSPacketClt0x33_NpcSell`.
pub const NpcSell = struct {
    pub const OPCODE: u8 = 0x33;
    pub const SIZE: usize = 17;
    npc_guid: i32 = 0, // +0x01
    item_guid: i32 = 0, // +0x05
    mode: u16 = 0, // +0x09
    unused: u16 = 0, // +0x0b
    unused_at_0d: u32 = 0, // +0x0d

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(i32, out[1..][0..4], self.npc_guid, .little);
        std.mem.writeInt(i32, out[5..][0..4], self.item_guid, .little);
        std.mem.writeInt(u16, out[9..][0..2], self.mode, .little);
        std.mem.writeInt(u16, out[11..][0..2], self.unused, .little);
        std.mem.writeInt(u32, out[13..][0..4], self.unused_at_0d, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_guid = std.mem.readInt(i32, buf[1..][0..4], .little),
            .item_guid = std.mem.readInt(i32, buf[5..][0..4], .little),
            .mode = std.mem.readInt(u16, buf[9..][0..2], .little),
            .unused = std.mem.readInt(u16, buf[11..][0..2], .little),
            .unused_at_0d = std.mem.readInt(u32, buf[13..][0..4], .little),
        };
    }
};

/// 0x34 — SCMD_0x34_CainIdentify. `D2GSPacketClt0x34_CainIdentify`.
pub const CainIdentify = struct {
    pub const OPCODE: u8 = 0x34;
    pub const SIZE: usize = 5;
    npc_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.npc_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x35 — SCMD_0x35_NpcGamble. `D2GSPacketClt0x35_NpcGamble`.
pub const NpcGamble = struct {
    pub const OPCODE: u8 = 0x35;
    pub const SIZE: usize = 17;
    npc_guid: u32 = 0, // +0x01
    item_guid: u32 = 0, // +0x05
    param1: u16 = 0, // +0x09
    pad: u16 = 0, // +0x0b
    param2: u32 = 0, // +0x0d

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.npc_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.item_guid, .little);
        std.mem.writeInt(u16, out[9..][0..2], self.param1, .little);
        std.mem.writeInt(u16, out[11..][0..2], self.pad, .little);
        std.mem.writeInt(u32, out[13..][0..4], self.param2, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .item_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
            .param1 = std.mem.readInt(u16, buf[9..][0..2], .little),
            .pad = std.mem.readInt(u16, buf[11..][0..2], .little),
            .param2 = std.mem.readInt(u32, buf[13..][0..4], .little),
        };
    }
};

/// 0x36 — SCMD_0x36_HireMerc. `D2GSPacketClt0x36_HireMerc`.
pub const HireMerc = struct {
    pub const OPCODE: u8 = 0x36;
    pub const SIZE: usize = 9;
    npc_guid: i32 = 0, // +0x01
    merc_id: u16 = 0, // +0x05
    _pad: u16 = 0, // +0x07

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(i32, out[1..][0..4], self.npc_guid, .little);
        std.mem.writeInt(u16, out[5..][0..2], self.merc_id, .little);
        std.mem.writeInt(u16, out[7..][0..2], self._pad, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_guid = std.mem.readInt(i32, buf[1..][0..4], .little),
            .merc_id = std.mem.readInt(u16, buf[5..][0..2], .little),
            ._pad = std.mem.readInt(u16, buf[7..][0..2], .little),
        };
    }
};

/// 0x37 — SCMD_0x37_GambleConfirm. `D2GSPacketClt0x37_GambleConfirm`.
pub const GambleConfirm = struct {
    pub const OPCODE: u8 = 0x37;
    pub const SIZE: usize = 5;
    item_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x38 — SCMD_0x38_NpcMenuSelect. `D2GSPacketClt0x38_NpcMenuSelect`.
pub const NpcMenuSelect = struct {
    pub const OPCODE: u8 = 0x38;
    pub const SIZE: usize = 13;
    npc_guid: u32 = 0, // +0x01
    menu_id: u32 = 0, // +0x05
    params: u32 = 0, // +0x09

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.npc_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.menu_id, .little);
        std.mem.writeInt(u32, out[9..][0..4], self.params, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .menu_id = std.mem.readInt(u32, buf[5..][0..4], .little),
            .params = std.mem.readInt(u32, buf[9..][0..4], .little),
        };
    }
};

/// 0x39 — SCMD_0x39_DeadStub39. `(no packet struct)`.
pub const DeadStub39 = struct {
    pub const OPCODE: u8 = 0x39;
    pub const SIZE: usize = 5;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x3A — SCMD_0x3A_AllocStatPoint. `D2GSPacketClt0x3A_AllocStatPoint`.
pub const AllocStatPoint = struct {
    pub const OPCODE: u8 = 0x3a;
    pub const SIZE: usize = 3;
    stat_id: u8 = 0, // +0x01
    repeat_count: u8 = 0, // +0x02

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        out[1] = self.stat_id;
        out[2] = self.repeat_count;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .stat_id = buf[1],
            .repeat_count = buf[2],
        };
    }
};

/// 0x3B — SCMD_0x3B_AllocSkillPoint. `D2GSPacketClt0x3B_AllocSkillPoint`.
pub const AllocSkillPoint = struct {
    pub const OPCODE: u8 = 0x3b;
    pub const SIZE: usize = 3;
    skill_id: u16 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.skill_id, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .skill_id = std.mem.readInt(u16, buf[1..][0..2], .little),
        };
    }
};

/// 0x3C — SCMD_0x3C_SelectSkill. `D2GSPacketClt0x3C_SelectSkill`.
pub const SelectSkill = struct {
    pub const OPCODE: u8 = 0x3c;
    pub const SIZE: usize = 9;
    skill_id_with_hand: u32 = 0, // +0x01
    owner_id: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.skill_id_with_hand, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.owner_id, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .skill_id_with_hand = std.mem.readInt(u32, buf[1..][0..4], .little),
            .owner_id = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x3D — SCMD_0x3D_ActivateObject. `D2GSPacketClt0x3D_ActivateObject`.
pub const ActivateObject = struct {
    pub const OPCODE: u8 = 0x3d;
    pub const SIZE: usize = 5;
    object_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.object_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .object_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x3E — SCMD_0x3E_QuestItemPickup. `D2GSPacketClt0x3E_QuestItemPickup`.
pub const QuestItemPickup = struct {
    pub const OPCODE: u8 = 0x3e;
    pub const SIZE: usize = 5;
    unit_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x3F — SCMD_0x3F_PlayEmote. `D2GSPacketClt0x3F_PlayEmote`.
pub const PlayEmote = struct {
    pub const OPCODE: u8 = 0x3f;
    pub const SIZE: usize = 3;
    emote_id: u16 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.emote_id, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .emote_id = std.mem.readInt(u16, buf[1..][0..2], .little),
        };
    }
};

/// 0x40 — SCMD_0x40_RefreshQuestData. `D2GSPacketClt0x40_RefreshQuestData`.
pub const RefreshQuestData = struct {
    pub const OPCODE: u8 = 0x40;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x41 — SCMD_0x41_Resurrect. `D2GSPacketClt0x41_Resurrect`.
pub const Resurrect = struct {
    pub const OPCODE: u8 = 0x41;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x42 — SCMD_0x42_StaffInOrifice1. `(no packet struct)`.
pub const StaffInOrifice1 = struct {
    pub const OPCODE: u8 = 0x42;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x43 — SCMD_0x43_StaffInOrifice2. `(no packet struct)`.
pub const StaffInOrifice2 = struct {
    pub const OPCODE: u8 = 0x43;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x44 — SCMD_0x44_StaffInOrifice. `D2GSPacketClt0x44_StaffInOrifice`.
pub const StaffInOrifice = struct {
    pub const OPCODE: u8 = 0x44;
    pub const HEADER: usize = 15;
    object_guid: u32 = 0, // +0x05
    staff_guid: u32 = 0, // +0x09
    item_id: i16 = 0, // +0x0d
    _pad2: []const u8 = "", // +0x0f, NUL-terminated on the wire

    pub fn wireLen(self: @This()) usize {
        return HEADER + self._pad2.len + 1;
    }

    pub fn encode(self: @This(), out: []u8) []u8 {
        const n = self.wireLen();
        std.debug.assert(out.len >= n);
        @memset(out[0..HEADER], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[5..][0..4], self.object_guid, .little);
        std.mem.writeInt(u32, out[9..][0..4], self.staff_guid, .little);
        std.mem.writeInt(i16, out[13..][0..2], self.item_id, .little);
        @memcpy(out[HEADER..][0..self._pad2.len], self._pad2);
        out[HEADER + self._pad2.len] = 0;
        return out[0..n];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < HEADER) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const rest = buf[HEADER..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        return .{
            .object_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
            .staff_guid = std.mem.readInt(u32, buf[9..][0..4], .little),
            .item_id = std.mem.readInt(i16, buf[13..][0..2], .little),
            ._pad2 = rest[0..end],
        };
    }
};

/// 0x45 — SCMD_0x45_Unused. `(no packet struct)`.
pub const Unused = struct {
    pub const OPCODE: u8 = 0x45;
    pub const SIZE: usize = 9;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x46 — SCMD_0x46_NpcInteractMerc. `D2GSPacketClt0x46_NpcInteractMerc`.
pub const NpcInteractMerc = struct {
    pub const OPCODE: u8 = 0x46;
    pub const SIZE: usize = 13;
    npc_guid: u32 = 0, // +0x01
    merc_guid: u32 = 0, // +0x05
    unit_type: u32 = 0, // +0x09

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.npc_guid, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.merc_guid, .little);
        std.mem.writeInt(u32, out[9..][0..4], self.unit_type, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .merc_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
            .unit_type = std.mem.readInt(u32, buf[9..][0..4], .little),
        };
    }
};

/// 0x47 — SCMD_0x47_CommandMercenary. `D2GSPacketClt0x47_CommandMercenary`.
pub const CommandMercenary = struct {
    pub const OPCODE: u8 = 0x47;
    pub const HEADER: usize = 11;
    merc_guid: u32 = 0, // +0x01
    target_x: u16 = 0, // +0x05
    target_y: u16 = 0, // +0x09
    _pad2: []const u8 = "", // +0x0b, NUL-terminated on the wire

    pub fn wireLen(self: @This()) usize {
        return HEADER + self._pad2.len + 1;
    }

    pub fn encode(self: @This(), out: []u8) []u8 {
        const n = self.wireLen();
        std.debug.assert(out.len >= n);
        @memset(out[0..HEADER], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.merc_guid, .little);
        std.mem.writeInt(u16, out[5..][0..2], self.target_x, .little);
        std.mem.writeInt(u16, out[9..][0..2], self.target_y, .little);
        @memcpy(out[HEADER..][0..self._pad2.len], self._pad2);
        out[HEADER + self._pad2.len] = 0;
        return out[0..n];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < HEADER) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const rest = buf[HEADER..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        return .{
            .merc_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .target_x = std.mem.readInt(u16, buf[5..][0..2], .little),
            .target_y = std.mem.readInt(u16, buf[9..][0..2], .little),
            ._pad2 = rest[0..end],
        };
    }
};

/// 0x48 — SCMD_0x48_ConfirmTradeTick. `D2GSPacketClt0x48_TransmogrifyItem`.
pub const ConfirmTradeTick = struct {
    pub const OPCODE: u8 = 0x48;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x49 — SCMD_0x49_TakeWaypoint. `D2GSPacketClt0x49_TakeWaypoint`.
///
/// FIXED at nine bytes, which `NET_D2GS_CLIENT_OUTGOING_SIZE[0x49]` is the authority on. It was
/// written here as a seven-byte header plus a NUL-terminated tail, which encodes to eight — and a
/// short C->S packet is not rejected, it is FRAMED AT NINE ANYWAY. The server swallows the first
/// byte of whatever follows, every command after it is read at an offset, and the connection is
/// eventually dropped with nothing said. That cost a live game and a join that reported
/// "game name and password don't match", three layers from the cause.
pub const TakeWaypoint = struct {
    pub const OPCODE: u8 = 0x49;
    pub const SIZE: usize = 9;
    waypoint_guid: u32 = 0, // +0x01
    waypoint_id: u16 = 0, // +0x05
    _unknown: u16 = 0, // +0x07 — zero on every capture

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.waypoint_guid, .little);
        std.mem.writeInt(u16, out[5..][0..2], self.waypoint_id, .little);
        std.mem.writeInt(u16, out[7..][0..2], self._unknown, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .waypoint_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
            .waypoint_id = std.mem.readInt(u16, buf[5..][0..2], .little),
            ._unknown = std.mem.readInt(u16, buf[7..][0..2], .little),
        };
    }
};

/// 0x4B — SCMD_0x4B_ForceUnitUpdate. `D2GSPacketClt0x4B_ForceUnitUpdate`.
pub const ForceUnitUpdate = struct {
    pub const OPCODE: u8 = 0x4b;
    pub const SIZE: usize = 9;
    unit_type: u32 = 0, // +0x01
    unit_guid: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.unit_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .unit_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x4C — SCMD_0x4C_TransmogrifyItem2. `D2GSPacketClt0x4C_TransmogrifyItem2`.
pub const TransmogrifyItem2 = struct {
    pub const OPCODE: u8 = 0x4c;
    pub const SIZE: usize = 5;
    item_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x4D — SCMD_0x4D_ResetNpcIntroFlag. `D2GSPacketClt0x4D_ResetNpcIntroFlag`.
pub const ResetNpcIntroFlag = struct {
    pub const OPCODE: u8 = 0x4d;
    pub const SIZE: usize = 3;
    npc_id: u16 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.npc_id, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .npc_id = std.mem.readInt(u16, buf[1..][0..2], .little),
        };
    }
};

/// 0x4F — SCMD_0x4F_GoToTownFolk. `D2GSPacketClt0x4F_ClickButton`.
pub const GoToTownFolk = struct {
    pub const OPCODE: u8 = 0x4f;
    pub const SIZE: usize = 7;
    button: u16 = 0, // +0x01
    param: u32 = 0, // +0x03

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.button, .little);
        std.mem.writeInt(u32, out[3..][0..4], self.param, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .button = std.mem.readInt(u16, buf[1..][0..2], .little),
            .param = std.mem.readInt(u32, buf[3..][0..4], .little),
        };
    }
};

/// 0x50 — SCMD_0x50_DropGold. `D2GSPacketClt0x50_DropGold`.
pub const DropGold = struct {
    pub const OPCODE: u8 = 0x50;
    pub const SIZE: usize = 9;
    unit_id: u32 = 0, // +0x01
    gold_amount: u32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_id, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.gold_amount, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_id = std.mem.readInt(u32, buf[1..][0..4], .little),
            .gold_amount = std.mem.readInt(u32, buf[5..][0..4], .little),
        };
    }
};

/// 0x51 — SCMD_0x51_SetHotkey. `D2GSPacketClt0x51_SetHotkey`.
pub const SetHotkey = struct {
    pub const OPCODE: u8 = 0x51;
    pub const SIZE: usize = 9;
    skill_and_hotkey_index: u32 = 0, // +0x01
    skill_level: i32 = 0, // +0x05

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.skill_and_hotkey_index, .little);
        std.mem.writeInt(i32, out[5..][0..4], self.skill_level, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .skill_and_hotkey_index = std.mem.readInt(u32, buf[1..][0..4], .little),
            .skill_level = std.mem.readInt(i32, buf[5..][0..4], .little),
        };
    }
};

/// 0x52 — SCMD_0x52_Unused52. `D2GSPacketClt0x52_Unused`.
pub const Unused52 = struct {
    pub const OPCODE: u8 = 0x52;
    pub const SIZE: usize = 5;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x53 — SCMD_0x53_GamepadInput. `D2GSPacketClt0x53_GamepadInput`.
pub const GamepadInput = struct {
    pub const OPCODE: u8 = 0x53;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x54 — SCMD_0x54_StopRunning. `D2GSPacketClt0x54_StackMerge`.
pub const StopRunning = struct {
    pub const OPCODE: u8 = 0x54;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x58 — SCMD_0x58_MarkQuestDone. `D2GSPacketClt0x58_MarkQuestDone`.
pub const MarkQuestDone = struct {
    pub const OPCODE: u8 = 0x58;
    pub const SIZE: usize = 3;
    quest_id: u16 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.quest_id, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .quest_id = std.mem.readInt(u16, buf[1..][0..2], .little),
        };
    }
};

/// 0x59 — SCMD_0x59_CommandNPC. `D2GSPacketClt0x59_CommandNPC`.
pub const CommandNPC = struct {
    pub const OPCODE: u8 = 0x59;
    pub const SIZE: usize = 17;
    unit_type: u32 = 0, // +0x01
    unit_guid: u32 = 0, // +0x05
    y: u32 = 0, // +0x09
    x: u32 = 0, // +0x0d

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.unit_type, .little);
        std.mem.writeInt(u32, out[5..][0..4], self.unit_guid, .little);
        std.mem.writeInt(u32, out[9..][0..4], self.y, .little);
        std.mem.writeInt(u32, out[13..][0..4], self.x, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = std.mem.readInt(u32, buf[1..][0..4], .little),
            .unit_guid = std.mem.readInt(u32, buf[5..][0..4], .little),
            .y = std.mem.readInt(u32, buf[9..][0..4], .little),
            .x = std.mem.readInt(u32, buf[13..][0..4], .little),
        };
    }
};

/// 0x5D — SCMD_0x5D_CubeRecipeCheck. `D2GSPacketClt0x5D_CubeRecipeCheck`.
pub const CubeRecipeCheck = struct {
    pub const OPCODE: u8 = 0x5d;
    pub const SIZE: usize = 7;
    param0: u8 = 0, // +0x01
    param1: u8 = 0, // +0x02
    param2: u32 = 0, // +0x03

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        out[1] = self.param0;
        out[2] = self.param1;
        std.mem.writeInt(u32, out[3..][0..4], self.param2, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .param0 = buf[1],
            .param1 = buf[2],
            .param2 = std.mem.readInt(u32, buf[3..][0..4], .little),
        };
    }
};

/// 0x5E — SCMD_0x5E_CubeApply. `D2GSPacketClt0x5E_CubeApply`.
pub const CubeApply = struct {
    pub const OPCODE: u8 = 0x5e;
    pub const SIZE: usize = 6;
    param0: u8 = 0, // +0x01
    param1: u32 = 0, // +0x02

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        out[1] = self.param0;
        std.mem.writeInt(u32, out[2..][0..4], self.param1, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .param0 = buf[1],
            .param1 = std.mem.readInt(u32, buf[2..][0..4], .little),
        };
    }
};

/// 0x5F — SCMD_0x5F_SyncPosition. `(no packet struct)`.
pub const SyncPosition = struct {
    pub const OPCODE: u8 = 0x5f;
    pub const SIZE: usize = 5;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x60 — SCMD_0x60_WeaponSwap. `D2GSPacketClt0x60_WeaponSwap`.
pub const WeaponSwap = struct {
    pub const OPCODE: u8 = 0x60;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// 0x61 — SCMD_0x61_MercEquipItem. `D2GSPacketClt0x61_MercEquipItem`.
pub const MercEquipItem = struct {
    pub const OPCODE: u8 = 0x61;
    pub const SIZE: usize = 3;
    body_loc: u16 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u16, out[1..][0..2], self.body_loc, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .body_loc = std.mem.readInt(u16, buf[1..][0..2], .little),
        };
    }
};

/// 0x62 — SCMD_0x62_NpcSellExpansion. `D2GSPacketClt0x62_NpcSellExpansion`.
pub const NpcSellExpansion = struct {
    pub const OPCODE: u8 = 0x62;
    pub const SIZE: usize = 5;
    item_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x63 — SCMD_0x63_ItemToBeltAuto. `D2GSPacketClt0x63_ItemToBeltAuto`.
pub const ItemToBeltAuto = struct {
    pub const OPCODE: u8 = 0x63;
    pub const SIZE: usize = 5;
    item_guid: u32 = 0, // +0x01

    pub fn encode(self: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..][0..4], self.item_guid, .little);
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .item_guid = std.mem.readInt(u32, buf[1..][0..4], .little),
        };
    }
};

/// 0x66 — SCMD_0x66_WardenStub. `D2GSPacketClt0x66_WardenStub`.
pub const WardenStub = struct {
    pub const OPCODE: u8 = 0x66;
    pub const SIZE: usize = 1;

    pub fn encode(_: @This(), out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        out[0] = OPCODE;
        return out[0..SIZE];
    }

    pub fn decode(buf: []const u8) DecodeError!@This() {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
        };
    }
};

/// Every client->server opcode the 1.14d server dispatches, with the name of its handler.
pub fn name(op: u8) ?[]const u8 {
    return switch (op) {
        0x01 => "WalkToLocation",
        0x02 => "WalkToEntity",
        0x03 => "RunToLocation",
        0x04 => "RunToEntity",
        0x05 => "LeftSkillOnLocation",
        0x06 => "LeftSkillOnEntity",
        0x07 => "LeftSkillOnEntityEx",
        0x08 => "LeftSkillOnLocationEx",
        0x09 => "LeftSkillOnEntityEx2",
        0x0a => "LeftSkillOnEntityEx3",
        0x0b => "Keepalive",
        0x0c => "RightSkillOnLocation",
        0x0d => "RightSkillOnEntity",
        0x0e => "RightSkillOnEntityEx",
        0x0f => "RightSkillOnLocationEx",
        0x10 => "RightSkillOnEntityEx2",
        0x11 => "RightSkillOnEntityEx3",
        0x12 => "CancelChanneledSkill",
        0x13 => "InteractWithEntity",
        0x14 => "OverheadMessage",
        0x15 => "ChatMessage",
        0x16 => "InteractWithEntityEx",
        0x17 => "DropItem",
        0x18 => "ItemToInventory",
        0x19 => "PickUpToCursor",
        0x1a => "EquipItem",
        0x1b => "EquipToSwapSlot",
        0x1c => "UnequipToInventory",
        0x1d => "SwapBodyItem",
        0x1e => "EquipToWeaponSwap",
        0x1f => "UseItem",
        0x20 => "UseItemAtLocation",
        0x21 => "MergeStackables",
        0x22 => "UnstackItemStub",
        0x23 => "ItemToBelt",
        0x24 => "ItemFromBelt",
        0x25 => "SwapBeltItem",
        0x26 => "UseItemAtPlayerCoords",
        0x27 => "UseItemOnItem",
        0x28 => "SocketItem",
        0x29 => "ScrollIntoBook",
        0x2a => "ItemToCube",
        0x2c => "DeadStub",
        0x2d => "DeadStub2D",
        0x2e => "DeadStub2E",
        0x2f => "NpcInteract",
        0x30 => "NpcCancelDialog",
        0x31 => "NpcGossip",
        0x32 => "NpcBuyConfirm",
        0x33 => "NpcSell",
        0x34 => "CainIdentify",
        0x35 => "NpcGamble",
        0x36 => "HireMerc",
        0x37 => "GambleConfirm",
        0x38 => "NpcMenuSelect",
        0x39 => "DeadStub39",
        0x3a => "AllocStatPoint",
        0x3b => "AllocSkillPoint",
        0x3c => "SelectSkill",
        0x3d => "ActivateObject",
        0x3e => "QuestItemPickup",
        0x3f => "PlayEmote",
        0x40 => "RefreshQuestData",
        0x41 => "Resurrect",
        0x42 => "StaffInOrifice1",
        0x43 => "StaffInOrifice2",
        0x44 => "StaffInOrifice",
        0x45 => "Unused",
        0x46 => "NpcInteractMerc",
        0x47 => "CommandMercenary",
        0x48 => "ConfirmTradeTick",
        0x49 => "TakeWaypoint",
        0x4b => "ForceUnitUpdate",
        0x4c => "TransmogrifyItem2",
        0x4d => "ResetNpcIntroFlag",
        0x4f => "GoToTownFolk",
        0x50 => "DropGold",
        0x51 => "SetHotkey",
        0x52 => "Unused52",
        0x53 => "GamepadInput",
        0x54 => "StopRunning",
        0x58 => "MarkQuestDone",
        0x59 => "CommandNPC",
        0x5d => "CubeRecipeCheck",
        0x5e => "CubeApply",
        0x5f => "SyncPosition",
        0x60 => "WeaponSwap",
        0x61 => "MercEquipItem",
        0x62 => "NpcSellExpansion",
        0x63 => "ItemToBeltAuto",
        0x66 => "WardenStub",
        else => null,
    };
}

/// Wire size of a fixed-size command, or null when the command carries a trailing string
/// (its size depends on that string — build it with `encode`).
pub fn size(op: u8) ?usize {
    return switch (op) {
        0x01 => WalkToLocation.SIZE,
        0x02 => WalkToEntity.SIZE,
        0x03 => RunToLocation.SIZE,
        0x04 => RunToEntity.SIZE,
        0x05 => LeftSkillOnLocation.SIZE,
        0x06 => LeftSkillOnEntity.SIZE,
        0x07 => LeftSkillOnEntityEx.SIZE,
        0x08 => LeftSkillOnLocationEx.SIZE,
        0x09 => LeftSkillOnEntityEx2.SIZE,
        0x0a => LeftSkillOnEntityEx3.SIZE,
        0x0b => Keepalive.SIZE,
        0x0c => RightSkillOnLocation.SIZE,
        0x0d => RightSkillOnEntity.SIZE,
        0x0e => RightSkillOnEntityEx.SIZE,
        0x0f => RightSkillOnLocationEx.SIZE,
        0x10 => RightSkillOnEntityEx2.SIZE,
        0x11 => RightSkillOnEntityEx3.SIZE,
        0x12 => CancelChanneledSkill.SIZE,
        0x13 => InteractWithEntity.SIZE,
        0x14 => null,
        0x15 => null,
        0x16 => InteractWithEntityEx.SIZE,
        0x17 => DropItem.SIZE,
        0x18 => ItemToInventory.SIZE,
        0x19 => PickUpToCursor.SIZE,
        0x1a => EquipItem.SIZE,
        0x1b => EquipToSwapSlot.SIZE,
        0x1c => UnequipToInventory.SIZE,
        0x1d => SwapBodyItem.SIZE,
        0x1e => EquipToWeaponSwap.SIZE,
        0x1f => UseItem.SIZE,
        0x20 => UseItemAtLocation.SIZE,
        0x21 => MergeStackables.SIZE,
        0x22 => UnstackItemStub.SIZE,
        0x23 => ItemToBelt.SIZE,
        0x24 => ItemFromBelt.SIZE,
        0x25 => SwapBeltItem.SIZE,
        0x26 => UseItemAtPlayerCoords.SIZE,
        0x27 => UseItemOnItem.SIZE,
        0x28 => SocketItem.SIZE,
        0x29 => ScrollIntoBook.SIZE,
        0x2a => ItemToCube.SIZE,
        0x2c => DeadStub.SIZE,
        0x2d => DeadStub2D.SIZE,
        0x2e => DeadStub2E.SIZE,
        0x2f => NpcInteract.SIZE,
        0x30 => NpcCancelDialog.SIZE,
        0x31 => NpcGossip.SIZE,
        0x32 => NpcBuyConfirm.SIZE,
        0x33 => NpcSell.SIZE,
        0x34 => CainIdentify.SIZE,
        0x35 => NpcGamble.SIZE,
        0x36 => HireMerc.SIZE,
        0x37 => GambleConfirm.SIZE,
        0x38 => NpcMenuSelect.SIZE,
        0x39 => DeadStub39.SIZE,
        0x3a => AllocStatPoint.SIZE,
        0x3b => AllocSkillPoint.SIZE,
        0x3c => SelectSkill.SIZE,
        0x3d => ActivateObject.SIZE,
        0x3e => QuestItemPickup.SIZE,
        0x3f => PlayEmote.SIZE,
        0x40 => RefreshQuestData.SIZE,
        0x41 => Resurrect.SIZE,
        0x42 => StaffInOrifice1.SIZE,
        0x43 => StaffInOrifice2.SIZE,
        0x44 => null,
        0x45 => Unused.SIZE,
        0x46 => NpcInteractMerc.SIZE,
        0x47 => null,
        0x48 => ConfirmTradeTick.SIZE,
        0x49 => null,
        0x4b => ForceUnitUpdate.SIZE,
        0x4c => TransmogrifyItem2.SIZE,
        0x4d => ResetNpcIntroFlag.SIZE,
        0x4f => GoToTownFolk.SIZE,
        0x50 => DropGold.SIZE,
        0x51 => SetHotkey.SIZE,
        0x52 => Unused52.SIZE,
        0x53 => GamepadInput.SIZE,
        0x54 => StopRunning.SIZE,
        0x58 => MarkQuestDone.SIZE,
        0x59 => CommandNPC.SIZE,
        0x5d => CubeRecipeCheck.SIZE,
        0x5e => CubeApply.SIZE,
        0x5f => SyncPosition.SIZE,
        0x60 => WeaponSwap.SIZE,
        0x61 => MercEquipItem.SIZE,
        0x62 => NpcSellExpansion.SIZE,
        0x63 => ItemToBeltAuto.SIZE,
        0x66 => WardenStub.SIZE,
        else => null,
    };
}

test "every command round-trips through encode/decode" {
    var buf: [512]u8 = undefined;
    {
        const p = WalkToLocation{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, WalkToLocation.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x01), wire[0]);
        try std.testing.expectEqual(p, try WalkToLocation.decode(wire));
    }
    {
        const p = WalkToEntity{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, WalkToEntity.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x02), wire[0]);
        try std.testing.expectEqual(p, try WalkToEntity.decode(wire));
    }
    {
        const p = RunToLocation{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RunToLocation.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x03), wire[0]);
        try std.testing.expectEqual(p, try RunToLocation.decode(wire));
    }
    {
        const p = RunToEntity{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RunToEntity.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x04), wire[0]);
        try std.testing.expectEqual(p, try RunToEntity.decode(wire));
    }
    {
        const p = LeftSkillOnLocation{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, LeftSkillOnLocation.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x05), wire[0]);
        try std.testing.expectEqual(p, try LeftSkillOnLocation.decode(wire));
    }
    {
        const p = LeftSkillOnEntity{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, LeftSkillOnEntity.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x06), wire[0]);
        try std.testing.expectEqual(p, try LeftSkillOnEntity.decode(wire));
    }
    {
        const p = LeftSkillOnEntityEx{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, LeftSkillOnEntityEx.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x07), wire[0]);
        try std.testing.expectEqual(p, try LeftSkillOnEntityEx.decode(wire));
    }
    {
        const p = LeftSkillOnLocationEx{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, LeftSkillOnLocationEx.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x08), wire[0]);
        try std.testing.expectEqual(p, try LeftSkillOnLocationEx.decode(wire));
    }
    {
        const p = LeftSkillOnEntityEx2{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, LeftSkillOnEntityEx2.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x09), wire[0]);
        try std.testing.expectEqual(p, try LeftSkillOnEntityEx2.decode(wire));
    }
    {
        const p = LeftSkillOnEntityEx3{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, LeftSkillOnEntityEx3.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x0a), wire[0]);
        try std.testing.expectEqual(p, try LeftSkillOnEntityEx3.decode(wire));
    }
    {
        const p = Keepalive{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, Keepalive.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x0b), wire[0]);
        try std.testing.expectEqual(p, try Keepalive.decode(wire));
    }
    {
        const p = RightSkillOnLocation{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RightSkillOnLocation.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x0c), wire[0]);
        try std.testing.expectEqual(p, try RightSkillOnLocation.decode(wire));
    }
    {
        const p = RightSkillOnEntity{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RightSkillOnEntity.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x0d), wire[0]);
        try std.testing.expectEqual(p, try RightSkillOnEntity.decode(wire));
    }
    {
        const p = RightSkillOnEntityEx{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RightSkillOnEntityEx.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x0e), wire[0]);
        try std.testing.expectEqual(p, try RightSkillOnEntityEx.decode(wire));
    }
    {
        const p = RightSkillOnLocationEx{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RightSkillOnLocationEx.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x0f), wire[0]);
        try std.testing.expectEqual(p, try RightSkillOnLocationEx.decode(wire));
    }
    {
        const p = RightSkillOnEntityEx2{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RightSkillOnEntityEx2.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x10), wire[0]);
        try std.testing.expectEqual(p, try RightSkillOnEntityEx2.decode(wire));
    }
    {
        const p = RightSkillOnEntityEx3{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RightSkillOnEntityEx3.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x11), wire[0]);
        try std.testing.expectEqual(p, try RightSkillOnEntityEx3.decode(wire));
    }
    {
        const p = CancelChanneledSkill{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, CancelChanneledSkill.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x12), wire[0]);
        try std.testing.expectEqual(p, try CancelChanneledSkill.decode(wire));
    }
    {
        const p = InteractWithEntity{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, InteractWithEntity.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x13), wire[0]);
        try std.testing.expectEqual(p, try InteractWithEntity.decode(wire));
    }
    {
        const p = InteractWithEntityEx{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, InteractWithEntityEx.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x16), wire[0]);
        try std.testing.expectEqual(p, try InteractWithEntityEx.decode(wire));
    }
    {
        const p = DropItem{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, DropItem.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x17), wire[0]);
        try std.testing.expectEqual(p, try DropItem.decode(wire));
    }
    {
        const p = ItemToInventory{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ItemToInventory.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x18), wire[0]);
        try std.testing.expectEqual(p, try ItemToInventory.decode(wire));
    }
    {
        const p = PickUpToCursor{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, PickUpToCursor.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x19), wire[0]);
        try std.testing.expectEqual(p, try PickUpToCursor.decode(wire));
    }
    {
        const p = EquipItem{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, EquipItem.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x1a), wire[0]);
        try std.testing.expectEqual(p, try EquipItem.decode(wire));
    }
    {
        const p = EquipToSwapSlot{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, EquipToSwapSlot.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x1b), wire[0]);
        try std.testing.expectEqual(p, try EquipToSwapSlot.decode(wire));
    }
    {
        const p = UnequipToInventory{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, UnequipToInventory.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x1c), wire[0]);
        try std.testing.expectEqual(p, try UnequipToInventory.decode(wire));
    }
    {
        const p = SwapBodyItem{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, SwapBodyItem.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x1d), wire[0]);
        try std.testing.expectEqual(p, try SwapBodyItem.decode(wire));
    }
    {
        const p = EquipToWeaponSwap{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, EquipToWeaponSwap.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x1e), wire[0]);
        try std.testing.expectEqual(p, try EquipToWeaponSwap.decode(wire));
    }
    {
        const p = UseItem{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, UseItem.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x1f), wire[0]);
        try std.testing.expectEqual(p, try UseItem.decode(wire));
    }
    {
        const p = UseItemAtLocation{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, UseItemAtLocation.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x20), wire[0]);
        try std.testing.expectEqual(p, try UseItemAtLocation.decode(wire));
    }
    {
        const p = MergeStackables{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, MergeStackables.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x21), wire[0]);
        try std.testing.expectEqual(p, try MergeStackables.decode(wire));
    }
    {
        const p = UnstackItemStub{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, UnstackItemStub.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x22), wire[0]);
        try std.testing.expectEqual(p, try UnstackItemStub.decode(wire));
    }
    {
        const p = ItemToBelt{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ItemToBelt.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x23), wire[0]);
        try std.testing.expectEqual(p, try ItemToBelt.decode(wire));
    }
    {
        const p = ItemFromBelt{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ItemFromBelt.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x24), wire[0]);
        try std.testing.expectEqual(p, try ItemFromBelt.decode(wire));
    }
    {
        const p = SwapBeltItem{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, SwapBeltItem.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x25), wire[0]);
        try std.testing.expectEqual(p, try SwapBeltItem.decode(wire));
    }
    {
        const p = UseItemAtPlayerCoords{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, UseItemAtPlayerCoords.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x26), wire[0]);
        try std.testing.expectEqual(p, try UseItemAtPlayerCoords.decode(wire));
    }
    {
        const p = UseItemOnItem{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, UseItemOnItem.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x27), wire[0]);
        try std.testing.expectEqual(p, try UseItemOnItem.decode(wire));
    }
    {
        const p = SocketItem{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, SocketItem.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x28), wire[0]);
        try std.testing.expectEqual(p, try SocketItem.decode(wire));
    }
    {
        const p = ScrollIntoBook{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ScrollIntoBook.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x29), wire[0]);
        try std.testing.expectEqual(p, try ScrollIntoBook.decode(wire));
    }
    {
        const p = ItemToCube{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ItemToCube.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x2a), wire[0]);
        try std.testing.expectEqual(p, try ItemToCube.decode(wire));
    }
    {
        const p = DeadStub{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, DeadStub.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x2c), wire[0]);
        try std.testing.expectEqual(p, try DeadStub.decode(wire));
    }
    {
        const p = DeadStub2D{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, DeadStub2D.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x2d), wire[0]);
        try std.testing.expectEqual(p, try DeadStub2D.decode(wire));
    }
    {
        const p = DeadStub2E{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, DeadStub2E.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x2e), wire[0]);
        try std.testing.expectEqual(p, try DeadStub2E.decode(wire));
    }
    {
        const p = NpcInteract{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcInteract.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x2f), wire[0]);
        try std.testing.expectEqual(p, try NpcInteract.decode(wire));
    }
    {
        const p = NpcCancelDialog{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcCancelDialog.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x30), wire[0]);
        try std.testing.expectEqual(p, try NpcCancelDialog.decode(wire));
    }
    {
        const p = NpcGossip{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcGossip.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x31), wire[0]);
        try std.testing.expectEqual(p, try NpcGossip.decode(wire));
    }
    {
        const p = NpcBuyConfirm{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcBuyConfirm.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x32), wire[0]);
        try std.testing.expectEqual(p, try NpcBuyConfirm.decode(wire));
    }
    {
        const p = NpcSell{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcSell.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x33), wire[0]);
        try std.testing.expectEqual(p, try NpcSell.decode(wire));
    }
    {
        const p = CainIdentify{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, CainIdentify.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x34), wire[0]);
        try std.testing.expectEqual(p, try CainIdentify.decode(wire));
    }
    {
        const p = NpcGamble{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcGamble.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x35), wire[0]);
        try std.testing.expectEqual(p, try NpcGamble.decode(wire));
    }
    {
        const p = HireMerc{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, HireMerc.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x36), wire[0]);
        try std.testing.expectEqual(p, try HireMerc.decode(wire));
    }
    {
        const p = GambleConfirm{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, GambleConfirm.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x37), wire[0]);
        try std.testing.expectEqual(p, try GambleConfirm.decode(wire));
    }
    {
        const p = NpcMenuSelect{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcMenuSelect.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x38), wire[0]);
        try std.testing.expectEqual(p, try NpcMenuSelect.decode(wire));
    }
    {
        const p = DeadStub39{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, DeadStub39.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x39), wire[0]);
        try std.testing.expectEqual(p, try DeadStub39.decode(wire));
    }
    {
        const p = AllocStatPoint{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, AllocStatPoint.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x3a), wire[0]);
        try std.testing.expectEqual(p, try AllocStatPoint.decode(wire));
    }
    {
        const p = AllocSkillPoint{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, AllocSkillPoint.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x3b), wire[0]);
        try std.testing.expectEqual(p, try AllocSkillPoint.decode(wire));
    }
    {
        const p = SelectSkill{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, SelectSkill.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x3c), wire[0]);
        try std.testing.expectEqual(p, try SelectSkill.decode(wire));
    }
    {
        const p = ActivateObject{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ActivateObject.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x3d), wire[0]);
        try std.testing.expectEqual(p, try ActivateObject.decode(wire));
    }
    {
        const p = QuestItemPickup{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, QuestItemPickup.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x3e), wire[0]);
        try std.testing.expectEqual(p, try QuestItemPickup.decode(wire));
    }
    {
        const p = PlayEmote{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, PlayEmote.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x3f), wire[0]);
        try std.testing.expectEqual(p, try PlayEmote.decode(wire));
    }
    {
        const p = RefreshQuestData{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, RefreshQuestData.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x40), wire[0]);
        try std.testing.expectEqual(p, try RefreshQuestData.decode(wire));
    }
    {
        const p = Resurrect{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, Resurrect.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x41), wire[0]);
        try std.testing.expectEqual(p, try Resurrect.decode(wire));
    }
    {
        const p = StaffInOrifice1{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, StaffInOrifice1.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x42), wire[0]);
        try std.testing.expectEqual(p, try StaffInOrifice1.decode(wire));
    }
    {
        const p = StaffInOrifice2{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, StaffInOrifice2.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x43), wire[0]);
        try std.testing.expectEqual(p, try StaffInOrifice2.decode(wire));
    }
    {
        const p = Unused{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, Unused.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x45), wire[0]);
        try std.testing.expectEqual(p, try Unused.decode(wire));
    }
    {
        const p = NpcInteractMerc{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcInteractMerc.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x46), wire[0]);
        try std.testing.expectEqual(p, try NpcInteractMerc.decode(wire));
    }
    {
        const p = ConfirmTradeTick{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ConfirmTradeTick.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x48), wire[0]);
        try std.testing.expectEqual(p, try ConfirmTradeTick.decode(wire));
    }
    {
        const p = ForceUnitUpdate{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ForceUnitUpdate.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x4b), wire[0]);
        try std.testing.expectEqual(p, try ForceUnitUpdate.decode(wire));
    }
    {
        const p = TransmogrifyItem2{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, TransmogrifyItem2.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x4c), wire[0]);
        try std.testing.expectEqual(p, try TransmogrifyItem2.decode(wire));
    }
    {
        const p = ResetNpcIntroFlag{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ResetNpcIntroFlag.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x4d), wire[0]);
        try std.testing.expectEqual(p, try ResetNpcIntroFlag.decode(wire));
    }
    {
        const p = GoToTownFolk{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, GoToTownFolk.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x4f), wire[0]);
        try std.testing.expectEqual(p, try GoToTownFolk.decode(wire));
    }
    {
        const p = DropGold{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, DropGold.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x50), wire[0]);
        try std.testing.expectEqual(p, try DropGold.decode(wire));
    }
    {
        const p = SetHotkey{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, SetHotkey.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x51), wire[0]);
        try std.testing.expectEqual(p, try SetHotkey.decode(wire));
    }
    {
        const p = Unused52{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, Unused52.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x52), wire[0]);
        try std.testing.expectEqual(p, try Unused52.decode(wire));
    }
    {
        const p = GamepadInput{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, GamepadInput.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x53), wire[0]);
        try std.testing.expectEqual(p, try GamepadInput.decode(wire));
    }
    {
        const p = StopRunning{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, StopRunning.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x54), wire[0]);
        try std.testing.expectEqual(p, try StopRunning.decode(wire));
    }
    {
        const p = MarkQuestDone{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, MarkQuestDone.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x58), wire[0]);
        try std.testing.expectEqual(p, try MarkQuestDone.decode(wire));
    }
    {
        const p = CommandNPC{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, CommandNPC.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x59), wire[0]);
        try std.testing.expectEqual(p, try CommandNPC.decode(wire));
    }
    {
        const p = CubeRecipeCheck{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, CubeRecipeCheck.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x5d), wire[0]);
        try std.testing.expectEqual(p, try CubeRecipeCheck.decode(wire));
    }
    {
        const p = CubeApply{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, CubeApply.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x5e), wire[0]);
        try std.testing.expectEqual(p, try CubeApply.decode(wire));
    }
    {
        const p = SyncPosition{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, SyncPosition.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x5f), wire[0]);
        try std.testing.expectEqual(p, try SyncPosition.decode(wire));
    }
    {
        const p = WeaponSwap{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, WeaponSwap.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x60), wire[0]);
        try std.testing.expectEqual(p, try WeaponSwap.decode(wire));
    }
    {
        const p = MercEquipItem{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, MercEquipItem.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x61), wire[0]);
        try std.testing.expectEqual(p, try MercEquipItem.decode(wire));
    }
    {
        const p = NpcSellExpansion{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, NpcSellExpansion.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x62), wire[0]);
        try std.testing.expectEqual(p, try NpcSellExpansion.decode(wire));
    }
    {
        const p = ItemToBeltAuto{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, ItemToBeltAuto.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x63), wire[0]);
        try std.testing.expectEqual(p, try ItemToBeltAuto.decode(wire));
    }
    {
        const p = WardenStub{};
        const wire = p.encode(&buf);
        try std.testing.expectEqual(@as(usize, WardenStub.SIZE), wire.len);
        try std.testing.expectEqual(@as(u8, 0x66), wire[0]);
        try std.testing.expectEqual(p, try WardenStub.decode(wire));
    }
}

test "opcode table covers every generated command" {
    var n: usize = 0;
    var op: u16 = 0;
    while (op <= 0xff) : (op += 1) {
        if (name(@intCast(op)) != null) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 91), n);
}

test "the command set is the server's dispatch table, not the struct names" {
    // Regression: deriving the opcode set from `D2GSPacketClt0xNN_*` struct names produced
    // the right COUNT (91) but the wrong SET — it invented five commands the server never
    // dispatches and dropped five it does. Both halves are pinned here.
    for ([_]u8{ 0x39, 0x42, 0x43, 0x45, 0x5f }) |op| {
        if (name(op) == null) return error.MissingDispatchedCommand;
    }
    for ([_]u8{ 0x67, 0x68, 0x6b, 0x6d, 0x89 }) |op| {
        if (name(op) != null) return error.CommandIsNotDispatched;
    }
    try std.testing.expectEqualStrings("SyncPosition", name(0x5f).?);
    try std.testing.expectEqualStrings("StaffInOrifice1", name(0x42).?);
}

test "generated commands match the hand-written cs.zig byte-for-byte" {
    const cs = @import("cs.zig");
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    try std.testing.expectEqualSlices(u8,
        cs.WalkToLocation.encode(.{ .x = 5000, .y = 6001 }, &a),
        WalkToLocation.encode(.{ .x = 5000, .y = 6001 }, &b));
    try std.testing.expectEqualSlices(u8,
        cs.RunToLocation.encode(.{ .x = 1, .y = 2 }, &a),
        RunToLocation.encode(.{ .x = 1, .y = 2 }, &b));
    try std.testing.expectEqualSlices(u8,
        cs.WalkToEntity.encode(.{ .unit_type = 1, .guid = 0xDEADBEEF }, &a),
        WalkToEntity.encode(.{ .unit_type = 1, .unit_guid = 0xDEADBEEF }, &b));
    try std.testing.expectEqualSlices(u8,
        cs.InteractWithEntity.encode(.{ .unit_type = 1, .guid = 7 }, &a),
        InteractWithEntity.encode(.{ .unit_type = 1, .guid = 7 }, &b));
}

test "every command is the length the engine's own outgoing table says it is" {
    // The server frames C->S by NET_D2GS_CLIENT_OUTGOING_SIZE, exactly as the client does. So a
    // command encoded one byte short is NOT rejected — it is sized at the table's length anyway,
    // swallowing the start of whatever follows. Every command after it is then read at an offset
    // and the connection goes quiet: no error, no disconnect, just a server that stops obeying.
    //
    // That failure has now cost three separate debugging sessions (the 0x6d keep-alive at 5 bytes
    // instead of 13, the 0x49 waypoint at 8 instead of 9), and each time it surfaced as something
    // else entirely — a bot that would not walk, a game destroyed before anyone could join. This
    // asserts the whole table at once so there is no fourth.
    const cs = @import("cs.zig");
    var buf: [512]u8 = undefined;

    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const T = @field(@This(), decl.name);
        if (@TypeOf(T) != type) continue;
        if (@typeInfo(T) != .@"struct") continue;
        if (!@hasDecl(T, "OPCODE") or !@hasDecl(T, "SIZE")) continue;

        const op: u8 = T.OPCODE;
        const expected = cs.OUTGOING_SIZE[op];
        if (expected < 0) continue; // variable-length: sized by content, not by the table
        // A table entry of ZERO is not "empty packet" — it is an opcode the engine refuses to
        // frame at all, so writing one to a socket is itself the framing error. `DeadStub` (0x2c)
        // is the only such struct; it exists for completeness and must never be sent.
        if (expected == 0) continue;

        const wire = (T{}).encode(&buf);
        if (wire.len != @as(usize, @intCast(expected))) {
            std.debug.print(
                "clt.{s} (0x{x:0>2}) encodes {d} bytes, the engine frames it at {d}\n",
                .{ decl.name, op, wire.len, expected },
            );
            return error.CommandLengthDisagreesWithEngine;
        }
        try std.testing.expectEqual(op, wire[0]);
    }
}
