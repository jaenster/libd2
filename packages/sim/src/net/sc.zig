//! Server -> client game stream (the D2GS client-incoming opcode space, 1.14d).
//!
//! The stream is opcode-framed (`[opcode][payload…]`, not length-prefixed). Per-opcode wire size
//! comes from `NET_D2GS_CLIENT_INCOMING_SIZE @0x730AE8` (0x00..0xB4); `-1` = the size is derived
//! from header fields, mirroring `GetIncomingPacketSizeFromTableAndVariableSize @0x0052B920`.
//! Opcode -> handler routing mirrors the 175-entry table `NET_D2GS_CLIENT_INCOMING @0x007114D0`.
//!
//! The size table, `packetSize` and the `info`/`Cat` dispatch mirror are ported from the sibling
//! clientless world-decoder (src/game/packets.zig), which is capture-verified against a live
//! 1.14d server. Struct byte-layouts cite the individual handler addresses (see comments), and
//! 0x03 LoadAct is cross-checked against `D2GSPacketSrv0x03` and 0x26 chat against
//! `D2GSPacketSrv0x26` in Ghidra session 62fbfe69.

const std = @import("std");
const br = @import("bitreader.zig");
const BitReader = br.BitReader;
const BitWriter = br.BitWriter;

// NET_D2GS_CLIENT_INCOMING_SIZE @0x730AE8. >0 = fixed wire size (incl. the opcode byte); 0 =
// invalid/stub with no bytes; -1 = variable (derived in packetSize).
pub const SC_SIZE = [_]i16{
    1,  8,  1,  12, 1,  1,  1,  6,  6,  11, 6,  6,  9,  13, 12, 16, // 0x00
    16, 8,  26, 14, 18, 11, -1, 0,  15, 2,  2,  3,  5,  3,  4,  6, // 0x10
    10, 12, 12, 13, 90, 90, -1, 40, 103, 97, 15, 0,  8,  0,  0,  0, // 0x20
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  -1, 8, // 0x30
    13, 0,  6,  0,  0,  13, 0,  11, 11, 0,  0,  0,  16, 17, 7,  1, // 0x40
    15, 14, 42, 10, 3,  0,  0,  14, 7,  26, 40, -1, 5,  6,  38, 5, // 0x50
    7,  2,  7,  21, 0,  7,  7,  16, 21, 12, 12, 16, 16, 10, 1,  1, // 0x60
    1,  1,  1,  32, 10, 13, 6,  2,  21, 6,  13, 8,  6,  18, 5,  10, // 0x70
    0,  20, 29, 0,  0,  0,  0,  0,  0,  2,  6,  6,  11, 7,  10, 33, // 0x80
    13, 26, 6,  8,  -1, 13, 9,  1,  7,  16, 17, 7,  -1, -1, 7,  8, // 0x90
    10, 7,  8,  24, 3,  8,  -1, 7,  -1, 7,  -1, 7,  -1, 0,  -1, -1, // 0xA0
    1,  0,  53, -1, 5, // 0xB0..0xB4
};

pub const MAX_OPCODE = 0xB4;

/// Full wire size of the S->C packet at the front of `buf`, or null if the complete packet isn't
/// present yet. 0 = invalid opcode (desync). Mirrors GetIncomingPacketSizeFromTableAndVariableSize.
pub fn packetSize(buf: []const u8) ?usize {
    if (buf.len == 0) return null;
    const op = buf[0];
    if (op > MAX_OPCODE) return 0;
    const t = SC_SIZE[op];
    if (t == 0) return 0;
    if (t > 0) {
        const n: usize = @intCast(t);
        return if (buf.len >= n) n else null;
    }
    const sz: ?usize = switch (op) {
        0x16, 0x5b => if (buf.len > 2) @as(usize, std.mem.readInt(u16, buf[1..3], .little)) else null,
        0x3e => if (buf.len > 1) @as(usize, buf[1]) else null,
        0x94 => if (buf.len > 1) (@as(usize, buf[1]) + 2) * 3 else null,
        0x9c, 0x9d => if (buf.len > 2) @as(usize, buf[2]) else null,
        0xa6 => if (buf.len > 3) @as(usize, std.mem.readInt(u16, buf[2..4], .little)) else null,
        0xa8, 0xaa => if (buf.len > 6) @as(usize, buf[6]) else null,
        0xac => if (buf.len > 0xc) @as(usize, buf[0xc]) else null,
        0xae => if (buf.len > 2) blk: {
            var raw = std.mem.readInt(u16, buf[1..3], .little);
            if (raw > 0x1fd) raw = 0;
            break :blk @as(usize, raw) + 3;
        } else null,
        0xaf => if (buf.len > 1) (if (buf[1] == 0) @as(usize, 2) else @as(usize, buf[1]) + 1) else null,
        0xb3 => if (buf.len > 7) @as(usize, buf[1]) + 7 else null,
        0x26 => scanChat(buf), // event/chat message: fixed header + two NUL-terminated strings
        else => return 0,
    };
    const need = sz orelse return null;
    return if (buf.len >= need) need else null;
}

fn scanChat(buf: []const u8) ?usize {
    if (buf.len < Chat.HEADER + 2) return null;
    const name_end = std.mem.indexOfScalarPos(u8, buf, Chat.HEADER, 0) orelse return null;
    const msg_end = std.mem.indexOfScalarPos(u8, buf, name_end + 1, 0) orelse return null;
    return msg_end + 1;
}

/// Coarse category used to route a packet into a world model and decide how much to log.
pub const Cat = enum {
    control, level, unit_add, unit_remove, move, life, stat, state, skill, item, chat, roster, misc, unknown,
};

const Info = struct { name: []const u8, cat: Cat };

/// Opcode metadata mirroring the handler table `NET_D2GS_CLIENT_INCOMING @0x007114D0`. Names are
/// the 1.14d Ghidra handler symbol (short form). Ported from clientless src/game/packets.zig.
pub fn info(op: u8) Info {
    return switch (op) {
        0x00 => .{ .name = "Nop", .cat = .control },
        0x01 => .{ .name = "GameFlags", .cat = .control },
        0x02 => .{ .name = "LoadSuccess", .cat = .control },
        0x03 => .{ .name = "LoadAct", .cat = .level },
        0x04 => .{ .name = "LoadComplete", .cat = .control },
        0x05 => .{ .name = "UnloadComplete", .cat = .control },
        0x06 => .{ .name = "GameExit", .cat = .control },
        0x07 => .{ .name = "MapReveal", .cat = .level },
        0x08 => .{ .name = "MapHide", .cat = .level },
        0x09 => .{ .name = "AssignLevelWarp", .cat = .unit_add },
        0x0a => .{ .name = "RemoveObject", .cat = .unit_remove },
        0x0b => .{ .name = "HandShake", .cat = .control },
        0x0c => .{ .name = "NpcHit", .cat = .life },
        0x0d => .{ .name = "PlayerStop", .cat = .move },
        0x0e => .{ .name = "ObjectState", .cat = .state },
        0x0f => .{ .name = "PlayerMove", .cat = .move },
        0x10 => .{ .name = "CharacterToObject", .cat = .move },
        0x11 => .{ .name = "ReportKill", .cat = .misc },
        0x15 => .{ .name = "ReassignPlayer", .cat = .move },
        0x16 => .{ .name = "UnitUpdateBatch", .cat = .move },
        0x17 => .{ .name = "PlayerBeginCast", .cat = .skill },
        0x18 => .{ .name = "Life", .cat = .life },
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f => .{ .name = "ItemPageUpdate", .cat = .stat },
        0x22 => .{ .name = "SkillQuantity", .cat = .skill },
        0x23 => .{ .name = "SelectSkill", .cat = .skill },
        0x26 => .{ .name = "ChatMessage", .cat = .chat },
        0x27 => .{ .name = "OverheadText", .cat = .chat },
        0x28 => .{ .name = "NpcInteract", .cat = .misc },
        0x47, 0x48 => .{ .name = "RecalcEquippedItems", .cat = .misc },
        0x4c => .{ .name = "PlayerCast", .cat = .skill },
        0x4d => .{ .name = "PlayerCastTarget", .cat = .skill },
        0x51 => .{ .name = "CreateObject", .cat = .unit_add },
        0x59 => .{ .name = "CreatePlayer", .cat = .unit_add },
        0x5b => .{ .name = "RosterPlayer", .cat = .roster },
        0x5d => .{ .name = "QuestState", .cat = .roster },
        0x67 => .{ .name = "MonsterStop", .cat = .move },
        0x68 => .{ .name = "MonsterBeginCast", .cat = .skill },
        0x69 => .{ .name = "MonsterSpell", .cat = .skill },
        0x6a => .{ .name = "NpcStateToEntity", .cat = .state },
        0x6b => .{ .name = "MonsterBeginCastWalk", .cat = .move },
        0x6c => .{ .name = "MonsterCastStationary", .cat = .skill },
        0x73 => .{ .name = "WaypointInit", .cat = .roster },
        0x77 => .{ .name = "TradeWindow", .cat = .item },
        0x7b => .{ .name = "SetSkillSlot", .cat = .skill },
        0x7c => .{ .name = "ItemAction", .cat = .item },
        0x95 => .{ .name = "PlayerJoin", .cat = .life },
        0x96 => .{ .name = "PlayerLeave", .cat = .unit_remove },
        0x9c => .{ .name = "Item", .cat = .item },
        0x9e, 0x9f, 0xa0, 0xa1, 0xa2 => .{ .name = "MonsterStat", .cat = .stat },
        0xa7 => .{ .name = "State", .cat = .state },
        0xa8 => .{ .name = "StateStatList", .cat = .state },
        0xaa => .{ .name = "StateStat", .cat = .state },
        0xac => .{ .name = "AssignMonster", .cat = .unit_add },
        0xae => .{ .name = "Compressed", .cat = .control },
        else => .{ .name = "?", .cat = .unknown },
    };
}

const DecodeError = error{ ShortBuffer, WrongOpcode };

/// Concatenates several encoded S->C packets into one contiguous buffer for a single client flush.
/// The game host emits many packets per server tick (unit spawns, moves, ...); this appends their
/// `encode()` outputs back-to-back into a caller-owned buffer, ready to hand to the socket. Works
/// with any packet type in this module (fixed, variable or bit-packed) — they all expose
/// `encode(self, out) []u8`.
pub const PacketWriter = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) PacketWriter {
        return .{ .buf = buf };
    }

    /// Encode `pkt` at the current offset and advance. Asserts the remaining space is sufficient
    /// (the packet's own `encode` asserts `out.len >= wire size`).
    pub fn add(self: *PacketWriter, pkt: anytype) void {
        const wire = pkt.encode(self.buf[self.len..]);
        self.len += wire.len;
    }

    /// The concatenated bytes written so far.
    pub fn bytes(self: *const PacketWriter) []const u8 {
        return self.buf[0..self.len];
    }

    /// Free space remaining in the backing buffer.
    pub fn remaining(self: *const PacketWriter) usize {
        return self.buf.len - self.len;
    }

    pub fn reset(self: *PacketWriter) void {
        self.len = 0;
    }
};

// --- typed packets -------------------------------------------------------------------------

/// 0x03 LoadAct — CLIENT_AllocAct handler @0x0045C8E0. Cross-checked: D2GSPacketSrv0x03.
/// `[id][nAct u8][nMapSeed u32][nArea u16][nAutomap u32]` (12 bytes). Carries the DRLG map seed.
pub const LoadAct = struct {
    pub const OPCODE: u8 = 0x03;
    pub const SIZE: usize = 12;
    act: u8 = 0,
    map_seed: u32 = 0,
    area: u16 = 0,
    automap: u32 = 0,

    pub fn encode(self: LoadAct, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.act;
        std.mem.writeInt(u32, out[2..6], self.map_seed, .little);
        std.mem.writeInt(u16, out[6..8], self.area, .little);
        std.mem.writeInt(u32, out[8..12], self.automap, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!LoadAct {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .act = buf[1],
            .map_seed = std.mem.readInt(u32, buf[2..6], .little),
            .area = std.mem.readInt(u16, buf[6..8], .little),
            .automap = std.mem.readInt(u32, buf[8..12], .little),
        };
    }
};

/// 0x01 GameFlags @0x0045C860. `[id][difficulty u8][arena u32][expansion u8][ladder u8]` (8).
pub const GameFlags = struct {
    pub const OPCODE: u8 = 0x01;
    pub const SIZE: usize = 8;
    difficulty: u8 = 0,
    arena: u32 = 0,
    expansion: bool = false,
    ladder: bool = false,

    pub fn encode(self: GameFlags, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.difficulty;
        std.mem.writeInt(u32, out[2..6], self.arena, .little);
        out[6] = @intFromBool(self.expansion);
        out[7] = @intFromBool(self.ladder);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!GameFlags {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .difficulty = buf[1],
            .arena = std.mem.readInt(u32, buf[2..6], .little),
            .expansion = buf[6] != 0,
            .ladder = buf[7] != 0,
        };
    }
};

/// 0x09 AssignLevelWarp @0x0045CB90. `[id][type u8][guid u32][classId u8][x u16][y u16]` (11).
pub const AssignLevelWarp = struct {
    pub const OPCODE: u8 = 0x09;
    pub const SIZE: usize = 11;
    unit_type: u8 = 0,
    guid: u32 = 0,
    class_id: u8 = 0,
    x: u16 = 0,
    y: u16 = 0,

    pub fn encode(self: AssignLevelWarp, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.unit_type;
        std.mem.writeInt(u32, out[2..6], self.guid, .little);
        out[6] = self.class_id;
        std.mem.writeInt(u16, out[7..9], self.x, .little);
        std.mem.writeInt(u16, out[9..11], self.y, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!AssignLevelWarp {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = buf[1],
            .guid = std.mem.readInt(u32, buf[2..6], .little),
            .class_id = buf[6],
            .x = std.mem.readInt(u16, buf[7..9], .little),
            .y = std.mem.readInt(u16, buf[9..11], .little),
        };
    }
};

/// 0x0A RemoveObject @0x0045CC10 — a unit left view / was removed. `[id][unitType u8][guid u32]` (6).
pub const RemoveObject = struct {
    pub const OPCODE: u8 = 0x0a;
    pub const SIZE: usize = 6;
    unit_type: u8 = 0,
    guid: u32 = 0,

    pub fn encode(self: RemoveObject, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.unit_type;
        std.mem.writeInt(u32, out[2..6], self.guid, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!RemoveObject {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{ .unit_type = buf[1], .guid = std.mem.readInt(u32, buf[2..6], .little) };
    }
};

/// 0x0D PlayerStop @0x0045CCC0 — a unit stopped. The dispatcher pre-resolves the unit from
/// type@1/guid@2. `[id][type u8][guid u32][mode u8][x u16][y u16][targetType u8][hpPct u8]` (13).
/// `mode` is the unit-mode handed to Unit::HandleMessage; `x`/`y` land in the generic message's
/// nSkillId/nItemId slots (the stop location); `hpPct` updates the party roster (players only, when
/// type==0). Movement analogue of 0x0F PlayerMove / 0x15 ReassignPlayer.
pub const PlayerStop = struct {
    pub const OPCODE: u8 = 0x0d;
    pub const SIZE: usize = 13;
    unit_type: u8 = 0,
    guid: u32 = 0,
    mode: u8 = 0,
    x: u16 = 0,
    y: u16 = 0,
    target_type: u8 = 0,
    hp_pct: u8 = 0,

    pub fn encode(self: PlayerStop, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.unit_type;
        std.mem.writeInt(u32, out[2..6], self.guid, .little);
        out[6] = self.mode;
        std.mem.writeInt(u16, out[7..9], self.x, .little);
        std.mem.writeInt(u16, out[9..11], self.y, .little);
        out[0x0b] = self.target_type;
        out[0x0c] = self.hp_pct;
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!PlayerStop {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = buf[1],
            .guid = std.mem.readInt(u32, buf[2..6], .little),
            .mode = buf[6],
            .x = std.mem.readInt(u16, buf[7..9], .little),
            .y = std.mem.readInt(u16, buf[9..11], .little),
            .target_type = buf[0x0b],
            .hp_pct = buf[0x0c],
        };
    }
};

/// 0x0F PlayerMove @0x0045CD40 — a unit walking/running to a target. Unit pre-resolved from
/// type@1/guid@2. `[id][type u8][guid u32][mode u8][skillId u16][itemId u16][targetType u8]
/// [x u16][y u16]` (16). The move DESTINATION is x@0x0C/y@0x0E (PATH_MoveUnitToPoint); `skillId`@7
/// and `itemId`@9 are the generic Unit::HandleMessage message params (kept for byte-exactness).
pub const PlayerMove = struct {
    pub const OPCODE: u8 = 0x0f;
    pub const SIZE: usize = 16;
    unit_type: u8 = 0,
    guid: u32 = 0,
    mode: u8 = 0,
    skill_id: u16 = 0,
    item_id: u16 = 0,
    target_type: u8 = 0,
    x: u16 = 0,
    y: u16 = 0,

    pub fn encode(self: PlayerMove, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.unit_type;
        std.mem.writeInt(u32, out[2..6], self.guid, .little);
        out[6] = self.mode;
        std.mem.writeInt(u16, out[7..9], self.skill_id, .little);
        std.mem.writeInt(u16, out[9..11], self.item_id, .little);
        out[0x0b] = self.target_type;
        std.mem.writeInt(u16, out[0x0c..0x0e], self.x, .little);
        std.mem.writeInt(u16, out[0x0e..0x10], self.y, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!PlayerMove {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = buf[1],
            .guid = std.mem.readInt(u32, buf[2..6], .little),
            .mode = buf[6],
            .skill_id = std.mem.readInt(u16, buf[7..9], .little),
            .item_id = std.mem.readInt(u16, buf[9..11], .little),
            .target_type = buf[0x0b],
            .x = std.mem.readInt(u16, buf[0x0c..0x0e], .little),
            .y = std.mem.readInt(u16, buf[0x0e..0x10], .little),
        };
    }
};

/// 0x15 ReassignPlayer @0x0045D160. `[id][type u8][guid u32][x u16][y u16][moveFlag u8]` (11).
pub const ReassignPlayer = struct {
    pub const OPCODE: u8 = 0x15;
    pub const SIZE: usize = 11;
    unit_type: u8 = 0,
    guid: u32 = 0,
    x: u16 = 0,
    y: u16 = 0,
    move_flag: u8 = 0,

    pub fn encode(self: ReassignPlayer, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.unit_type;
        std.mem.writeInt(u32, out[2..6], self.guid, .little);
        std.mem.writeInt(u16, out[6..8], self.x, .little);
        std.mem.writeInt(u16, out[8..10], self.y, .little);
        out[10] = self.move_flag;
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!ReassignPlayer {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = buf[1],
            .guid = std.mem.readInt(u32, buf[2..6], .little),
            .x = std.mem.readInt(u16, buf[6..8], .little),
            .y = std.mem.readInt(u16, buf[8..10], .little),
            .move_flag = buf[10],
        };
    }
};

/// 0x51 CreateObject @0x0045CBD0. `[id][type u8][guid u32][classId u16][x u16][y u16][state u8]
/// [interaction u8]` (14).
pub const CreateObject = struct {
    pub const OPCODE: u8 = 0x51;
    pub const SIZE: usize = 14;
    unit_type: u8 = 0,
    guid: u32 = 0,
    class_id: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
    state: u8 = 0,
    interaction: u8 = 0,

    pub fn encode(self: CreateObject, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.unit_type;
        std.mem.writeInt(u32, out[2..6], self.guid, .little);
        std.mem.writeInt(u16, out[6..8], self.class_id, .little);
        std.mem.writeInt(u16, out[8..10], self.x, .little);
        std.mem.writeInt(u16, out[10..12], self.y, .little);
        out[12] = self.state;
        out[13] = self.interaction;
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!CreateObject {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .unit_type = buf[1],
            .guid = std.mem.readInt(u32, buf[2..6], .little),
            .class_id = std.mem.readInt(u16, buf[6..8], .little),
            .x = std.mem.readInt(u16, buf[8..10], .little),
            .y = std.mem.readInt(u16, buf[10..12], .little),
            .state = buf[12],
            .interaction = buf[13],
        };
    }
};

/// 0x59 CreatePlayer — UNIT_CreatePlayer @0x0045E4C0. `[id][guid u32][classId u8][name[16]]
/// [x u16][y u16]` (26). `name` is a fixed 16-byte, NUL-padded field.
pub const CreatePlayer = struct {
    pub const OPCODE: u8 = 0x59;
    pub const SIZE: usize = 26;
    guid: u32 = 0,
    class_id: u8 = 0,
    name: [16]u8 = [_]u8{0} ** 16,
    x: u16 = 0,
    y: u16 = 0,

    pub fn setName(self: *CreatePlayer, s: []const u8) void {
        self.name = [_]u8{0} ** 16;
        const n = @min(s.len, 15);
        @memcpy(self.name[0..n], s[0..n]);
    }
    pub fn nameSlice(self: *const CreatePlayer) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..end];
    }
    pub fn encode(self: CreatePlayer, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..5], self.guid, .little);
        out[5] = self.class_id;
        @memcpy(out[6..22], &self.name);
        std.mem.writeInt(u16, out[22..24], self.x, .little);
        std.mem.writeInt(u16, out[24..26], self.y, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!CreatePlayer {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        var p = CreatePlayer{
            .guid = std.mem.readInt(u32, buf[1..5], .little),
            .class_id = buf[5],
            .x = std.mem.readInt(u16, buf[22..24], .little),
            .y = std.mem.readInt(u16, buf[24..26], .little),
        };
        @memcpy(&p.name, buf[6..22]);
        return p;
    }
};

/// 0xAC AssignMonster @0x0045F190 — spawn/assign a monster unit; the monster analogue of 0x59
/// CreatePlayer / 0x09 AssignLevelWarp. Byte-aligned header then a Fog::BitBuffer body:
/// `[id][guid u32][monstatId i16][x u16][y u16][hpPct u8][pktLen u8]` (13 header) + a bitstream at
/// +0x0D whose length is `pktLen-13`. `pktLen`@0x0C is the TOTAL wire size and drives variable-size
/// framing (SC_SIZE[0xAC] = -1, `packetSize` reads buf[0x0C]). `monstatId` is a signed eD2MonStatsId
/// (-1 = none). `hpPct` is seeded as hitpoints `<<8`. The body carries unit-type, component bytes,
/// monster-type flags (Champion/Unique/SuperUnique/Minion/Ghostly), optional super-unique index +
/// name, nameId, owner GUID and a (statId,value) stat list — modelled here as opaque bytes (its
/// decode needs the MonStats2/ItemStatCost tables, out of scope for this wire layer).
pub const AssignMonster = struct {
    pub const OPCODE: u8 = 0xac;
    pub const HEADER: usize = 13;
    guid: u32 = 0,
    monster_class: i16 = 0, // monstatId @0x05 (eD2MonStatsId); signed, -1 = none
    x: u16 = 0,
    y: u16 = 0,
    hp_pct: u8 = 0, // @0x0B; hitpoints seeded as (hp_pct << 8)
    body: []const u8 = "", // Fog::BitBuffer flag/stat stream from +0x0D (opaque)

    pub fn wireLen(self: AssignMonster) usize {
        return HEADER + self.body.len;
    }
    pub fn encode(self: AssignMonster, out: []u8) []u8 {
        const n = self.wireLen();
        std.debug.assert(out.len >= n and n <= 255);
        out[0] = OPCODE;
        std.mem.writeInt(u32, out[1..5], self.guid, .little);
        std.mem.writeInt(i16, out[5..7], self.monster_class, .little);
        std.mem.writeInt(u16, out[7..9], self.x, .little);
        std.mem.writeInt(u16, out[9..11], self.y, .little);
        out[0x0b] = self.hp_pct;
        out[0x0c] = @intCast(n); // pktLen = total wire size
        @memcpy(out[HEADER..n], self.body);
        return out[0..n];
    }
    pub fn decode(buf: []const u8) DecodeError!AssignMonster {
        if (buf.len < HEADER) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const n: usize = buf[0x0c];
        if (n < HEADER or buf.len < n) return error.ShortBuffer;
        return .{
            .guid = std.mem.readInt(u32, buf[1..5], .little),
            .monster_class = std.mem.readInt(i16, buf[5..7], .little),
            .x = std.mem.readInt(u16, buf[7..9], .little),
            .y = std.mem.readInt(u16, buf[9..11], .little),
            .hp_pct = buf[0x0b],
            .body = buf[HEADER..n],
        };
    }
};

/// 0x96 PlayerLeave @0x0045DC50 — NAME IS A MISNOMER (inherited from the handler table). Despite
/// "PlayerLeave"/cat=unit_remove, this handler carries NO guid and removes nobody: it is a
/// bit-packed (Fog::BitBuffer, LSB-first) MOVE + STAMINA update for the LOCAL player. It sets
/// UNITSTAT_stamina and PATH_MoveUnitToPoint(x, y, +signed dX/dY). Decoded by DecodeIncoming0x96
/// @0x0045DBE0: `[op 8b][stamina 15b][x 16b][y 16b][dX 8b][dY 8b]` = 9 bytes. `dX`/`dY` are signed
/// step deltas (the engine treats a raw value >0x80 as negative). `stamina` is stored `<<8`.
pub const PlayerLeave = struct {
    pub const OPCODE: u8 = 0x96;
    pub const SIZE: usize = 9;
    stamina: u16 = 0, // 15-bit on the wire (engine keeps it <<8, 1/256 fixed point)
    x: u16 = 0,
    y: u16 = 0,
    dx: i8 = 0,
    dy: i8 = 0,

    pub fn encode(self: PlayerLeave, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        @memset(out[0..SIZE], 0);
        var w = BitWriter.init(out[0..SIZE]);
        w.write(OPCODE, 8);
        w.write(self.stamina, 15);
        w.write(self.x, 16);
        w.write(self.y, 16);
        w.write(@as(u8, @bitCast(self.dx)), 8);
        w.write(@as(u8, @bitCast(self.dy)), 8);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!PlayerLeave {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        var r = BitReader.init(buf);
        _ = r.read(8);
        return .{
            .stamina = @intCast(r.read(15)),
            .x = @intCast(r.read(16)),
            .y = @intCast(r.read(16)),
            .dx = @bitCast(@as(u8, @intCast(r.read(8)))),
            .dy = @bitCast(@as(u8, @intCast(r.read(8)))),
        };
    }
};

/// 0x0E ObjectState — NET_D2GS_SERVER_Send_0x0E @0x53b470 (12 bytes): broadcasts an
/// object unit's animation-mode/state change (chest opened, door toggled, shrine used).
/// `[op u8][unitType u8 = 2 OBJECT][guid u32][0x03 u8 const][active u8][animMode u32]`.
/// `active` = (unitFlags>>1)&1; `anim_mode` = eD2ObjectAnimMode (0 Neutral, 1 Operating,
/// 2 Opened, 3-7 Special1-5). Sole engine caller chain: OBJECT_SendStateToClient
/// @0x581a20 <- PacketUpdateForClient @0x581ad0 on UNITFLAG_DOUPDATE.
pub const ObjectState = struct {
    pub const OPCODE: u8 = 0x0E;
    pub const SIZE: usize = 12;

    guid: u32 = 0,
    active: u8 = 0,
    anim_mode: u32 = 0,

    pub fn encode(self: ObjectState, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = 2; // eD2UnitType OBJECT
        std.mem.writeInt(u32, out[2..6], self.guid, .little);
        out[6] = 0x03; // engine constant
        out[7] = self.active;
        std.mem.writeInt(u32, out[8..12], self.anim_mode, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!ObjectState {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{
            .guid = std.mem.readInt(u32, buf[2..6], .little),
            .active = buf[7],
            .anim_mode = std.mem.readInt(u32, buf[8..12], .little),
        };
    }
};

/// 0x19 GoldPickup — NET_D2GS_SERVER_Send_0x19_GoldPickup @0x53e9b0: the small-delta gold
/// pickup notification, `[op u8][amount u8]` (2 bytes). The engine sends this when the
/// picked amount is < 255; larger amounts reuse the SetAttribute opcodes (0x1D/0x1E/0x1F)
/// carrying stat 0x0E (gold) with the NEW total — see SetDWordAttr.
pub const GoldPickup = struct {
    pub const OPCODE: u8 = 0x19;
    pub const SIZE: usize = 2;

    amount: u8 = 0,

    pub fn encode(self: GoldPickup, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.amount;
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!GoldPickup {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{ .amount = buf[1] };
    }
};

/// 0x1F SetDWordAttr — the 32-bit SetAttribute: `[op u8][attr u8][value u32]` (6 bytes).
/// Sets a player stat to an absolute NEW value (attr = the Stat id; 0x0E = gold). Siblings
/// 0x1D/0x1E are the u8/u16 variants; the engine picks by value width (GoldPickup comment).
pub const SetDWordAttr = struct {
    pub const OPCODE: u8 = 0x1F;
    pub const SIZE: usize = 6;

    attr: u8 = 0,
    value: u32 = 0,

    pub fn encode(self: SetDWordAttr, out: []u8) []u8 {
        std.debug.assert(out.len >= SIZE);
        out[0] = OPCODE;
        out[1] = self.attr;
        std.mem.writeInt(u32, out[2..6], self.value, .little);
        return out[0..SIZE];
    }
    pub fn decode(buf: []const u8) DecodeError!SetDWordAttr {
        if (buf.len < SIZE) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        return .{ .attr = buf[1], .value = std.mem.readInt(u32, buf[2..6], .little) };
    }
};

/// 0x18 Life @0x0045D900 / 0x95 PlayerJoin @0x0045DB20 — bit-packed (Fog::BitBuffer, LSB-first).
/// Local player only (no GUID on the wire). Field order/widths: hp/mp/stamina are u15 each (the
/// engine keeps them <<8 as 1/256 fixed-point); 0x18 then carries two u7 regen fields; both then
/// carry absolute tile x/y as u16. 0x18 wire size 15, 0x95 wire size 13.
pub const Life = struct {
    pub const OP_LIFE: u8 = 0x18; // has the two regen fields
    pub const OP_JOIN: u8 = 0x95; // no regen fields
    opcode: u8 = OP_JOIN,
    hp: u16 = 0,
    mp: u16 = 0,
    stamina: u16 = 0,
    hp_regen: u8 = 0,
    mp_regen: u8 = 0,
    x: u16 = 0,
    y: u16 = 0,

    fn hasRegen(op: u8) bool {
        return op == OP_LIFE;
    }
    pub fn wireLen(self: Life) usize {
        return if (hasRegen(self.opcode)) 15 else 13;
    }
    pub fn encode(self: Life, out: []u8) []u8 {
        const n = self.wireLen();
        std.debug.assert(out.len >= n);
        @memset(out[0..n], 0);
        var w = BitWriter.init(out[0..n]);
        w.write(self.opcode, 8);
        w.write(self.hp, 15);
        w.write(self.mp, 15);
        w.write(self.stamina, 15);
        if (hasRegen(self.opcode)) {
            w.write(self.hp_regen, 7);
            w.write(self.mp_regen, 7);
        }
        w.write(self.x, 16);
        w.write(self.y, 16);
        return out[0..n];
    }
    pub fn decode(buf: []const u8) DecodeError!Life {
        if (buf.len == 0) return error.ShortBuffer;
        const op = buf[0];
        const need: usize = if (hasRegen(op)) 15 else 13;
        if (buf.len < need) return error.ShortBuffer;
        if (op != OP_LIFE and op != OP_JOIN) return error.WrongOpcode;
        var r = BitReader.init(buf);
        _ = r.read(8);
        var p = Life{ .opcode = op };
        p.hp = @intCast(r.read(15));
        p.mp = @intCast(r.read(15));
        p.stamina = @intCast(r.read(15));
        if (hasRegen(op)) {
            p.hp_regen = @intCast(r.read(7));
            p.mp_regen = @intCast(r.read(7));
        }
        p.x = @intCast(r.read(16));
        p.y = @intCast(r.read(16));
        return p;
    }
};

/// 0x9C item-on-ground / item action — Incoming0x9C @0x0045EB10. Variable length; the header is
/// `[id][action u8][pktLen u8][reserved u8][itemGUID u32]` (8 bytes) followed by the item's
/// Fog::BitBuffer bitstream (len = pktLen-8) which fully describes the item. This module models
/// the header + carries the item bitstream as opaque bytes; decoding the item body itself belongs
/// to the item library (d2-items / clientless item.zig), out of scope here.
pub const ItemAction = struct {
    pub const OPCODE: u8 = 0x9c;
    pub const HEADER: usize = 8;
    action: u8 = 0, // 0=add,1=picked,2=dropped,3=on-ground,…
    guid: u32 = 0,
    body: []const u8 = "", // item bitstream (opaque)

    pub fn wireLen(self: ItemAction) usize {
        return HEADER + self.body.len;
    }
    pub fn encode(self: ItemAction, out: []u8) []u8 {
        const n = self.wireLen();
        std.debug.assert(out.len >= n and n <= 255);
        out[0] = OPCODE;
        out[1] = self.action;
        out[2] = @intCast(n); // pktLen = total wire size (drives variable-size framing)
        out[3] = 0; // reserved
        std.mem.writeInt(u32, out[4..8], self.guid, .little);
        @memcpy(out[HEADER..n], self.body);
        return out[0..n];
    }
    pub fn decode(buf: []const u8) DecodeError!ItemAction {
        if (buf.len < HEADER) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const n: usize = buf[2];
        if (n < HEADER or buf.len < n) return error.ShortBuffer;
        return .{
            .action = buf[1],
            .guid = std.mem.readInt(u32, buf[4..8], .little),
            .body = buf[HEADER..n],
        };
    }
};

/// 0x26 ChatMessage (event/chat) — cross-checked against D2GSPacketSrv0x26. Fixed 10-byte header
/// `[id][msgType u8][unk2 u8][subType u8][unitGUID u32][unk8 u8][color u8]` then the sender name
/// (NUL-terminated, max 16) then the message text (NUL-terminated, max 256). Wire size is variable.
pub const Chat = struct {
    pub const OPCODE: u8 = 0x26;
    pub const HEADER: usize = 10;
    msg_type: u8 = 0,
    sub_type: u8 = 0,
    unit_guid: u32 = 0,
    color: u8 = 0,
    name: []const u8 = "",
    msg: []const u8 = "",

    pub fn wireLen(self: Chat) usize {
        return HEADER + self.name.len + 1 + self.msg.len + 1;
    }
    pub fn encode(self: Chat, out: []u8) []u8 {
        const n = self.wireLen();
        std.debug.assert(out.len >= n);
        out[0] = OPCODE;
        out[1] = self.msg_type;
        out[2] = 0; // unk2
        out[3] = self.sub_type;
        std.mem.writeInt(u32, out[4..8], self.unit_guid, .little);
        out[8] = 0; // unk8
        out[9] = self.color;
        var i: usize = HEADER;
        @memcpy(out[i..][0..self.name.len], self.name);
        i += self.name.len;
        out[i] = 0;
        i += 1;
        @memcpy(out[i..][0..self.msg.len], self.msg);
        i += self.msg.len;
        out[i] = 0;
        return out[0..n];
    }
    pub fn decode(buf: []const u8) DecodeError!Chat {
        if (buf.len < HEADER + 2) return error.ShortBuffer;
        if (buf[0] != OPCODE) return error.WrongOpcode;
        const name_end = std.mem.indexOfScalarPos(u8, buf, HEADER, 0) orelse return error.ShortBuffer;
        const msg_start = name_end + 1;
        const msg_end = std.mem.indexOfScalarPos(u8, buf, msg_start, 0) orelse return error.ShortBuffer;
        return .{
            .msg_type = buf[1],
            .sub_type = buf[3],
            .unit_guid = std.mem.readInt(u32, buf[4..8], .little),
            .color = buf[9],
            .name = buf[HEADER..name_end],
            .msg = buf[msg_start..msg_end],
        };
    }
};

// --- tests ---------------------------------------------------------------------------------

test "size table covers 0x00..0xB4" {
    try std.testing.expectEqual(@as(usize, MAX_OPCODE + 1), SC_SIZE.len);
}

test "packetSize: fixed framing needs the full packet; invalid opcode = desync" {
    try std.testing.expectEqual(@as(?usize, null), packetSize(&[_]u8{ 0x03, 0, 0 }));
    var full = [_]u8{0} ** 12;
    full[0] = 0x03;
    try std.testing.expectEqual(@as(?usize, 12), packetSize(&full));
    try std.testing.expectEqual(@as(?usize, 0), packetSize(&[_]u8{0xff}));
}

test "LoadAct round-trips + carries the map seed (matches world.zig fixture)" {
    // The exact bytes the sibling clientless world decoder asserts on.
    const fixture = [_]u8{ 0x03, 0x01, 0xEF, 0xBE, 0xAD, 0xDE, 0x28, 0x00, 0x44, 0x33, 0x22, 0x11 };
    const d = try LoadAct.decode(&fixture);
    try std.testing.expectEqual(@as(u8, 1), d.act);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), d.map_seed);
    try std.testing.expectEqual(@as(u16, 0x0028), d.area);
    try std.testing.expectEqual(@as(u32, 0x11223344), d.automap);
    var out: [12]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &fixture, d.encode(&out));
}

test "GameFlags decodes difficulty/expansion/ladder" {
    const d = try GameFlags.decode(&[_]u8{ 0x01, 0x02, 0, 0, 0, 0, 0x01, 0x01 });
    try std.testing.expectEqual(@as(u8, 2), d.difficulty);
    try std.testing.expect(d.expansion and d.ladder);
    var out: [8]u8 = undefined;
    const d2 = try GameFlags.decode(d.encode(&out));
    try std.testing.expectEqual(d, d2);
}

test "AssignLevelWarp / ReassignPlayer / CreateObject round-trip" {
    var out: [16]u8 = undefined;
    const w = AssignLevelWarp{ .unit_type = 5, .guid = 0x1234, .class_id = 7, .x = 100, .y = 200 };
    try std.testing.expectEqual(w, try AssignLevelWarp.decode(w.encode(&out)));
    const r = ReassignPlayer{ .unit_type = 0, .guid = 0x1000, .x = 150, .y = 250, .move_flag = 1 };
    try std.testing.expectEqual(r, try ReassignPlayer.decode(r.encode(&out)));
    const c = CreateObject{ .unit_type = 2, .guid = 0xABCD, .class_id = 30, .x = 5, .y = 6, .state = 1, .interaction = 2 };
    try std.testing.expectEqual(c, try CreateObject.decode(c.encode(&out)));
}

test "CreatePlayer round-trips name+pos (matches world.zig capture shape)" {
    var p = CreatePlayer{ .guid = 0x1000, .class_id = 1, .x = 100, .y = 200 };
    p.setName("Bob");
    var out: [26]u8 = undefined;
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(usize, 26), wire.len);
    const d = try CreatePlayer.decode(wire);
    try std.testing.expectEqualStrings("Bob", d.nameSlice());
    try std.testing.expectEqual(@as(u32, 0x1000), d.guid);
    try std.testing.expectEqual(@as(u16, 200), d.y);
}

test "Life 0x95 (no regen) bit-packed round-trip" {
    const p = Life{ .opcode = Life.OP_JOIN, .hp = 100, .mp = 50, .stamina = 80, .x = 5000, .y = 6000 };
    var out: [15]u8 = undefined;
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(usize, 13), wire.len);
    const d = try Life.decode(wire);
    try std.testing.expectEqual(@as(u16, 100), d.hp);
    try std.testing.expectEqual(@as(u16, 50), d.mp);
    try std.testing.expectEqual(@as(u16, 80), d.stamina);
    try std.testing.expectEqual(@as(u16, 5000), d.x);
    try std.testing.expectEqual(@as(u16, 6000), d.y);
}

test "Life 0x18 (with regen) bit-packed round-trip, 15 bytes" {
    const p = Life{ .opcode = Life.OP_LIFE, .hp = 1234, .mp = 567, .stamina = 890, .hp_regen = 12, .mp_regen = 7, .x = 100, .y = 4095 };
    var out: [15]u8 = undefined;
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(usize, 15), wire.len);
    try std.testing.expectEqual(p, try Life.decode(wire));
}

test "ItemAction header round-trips, body carried opaque, pktLen frames it" {
    const body = [_]u8{ 0xDE, 0xAD, 0xBE };
    const p = ItemAction{ .action = 3, .guid = 0xCAFE, .body = &body };
    var out: [32]u8 = undefined;
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(?usize, wire.len), packetSize(wire)); // variable-size framing agrees
    const d = try ItemAction.decode(wire);
    try std.testing.expectEqual(@as(u8, 3), d.action);
    try std.testing.expectEqual(@as(u32, 0xCAFE), d.guid);
    try std.testing.expectEqualSlices(u8, &body, d.body);
}

test "Chat 0x26 variable-length round-trip + self-consistent framing" {
    const p = Chat{ .msg_type = 1, .unit_guid = 0x2000, .color = 4, .name = "Bob", .msg = "hi there" };
    var out: [300]u8 = undefined;
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(?usize, wire.len), packetSize(wire));
    const d = try Chat.decode(wire);
    try std.testing.expectEqualStrings("Bob", d.name);
    try std.testing.expectEqualStrings("hi there", d.msg);
    try std.testing.expectEqual(@as(u32, 0x2000), d.unit_guid);
}

test "RemoveObject 0x0A round-trips (6 bytes)" {
    var out: [6]u8 = undefined;
    const p = RemoveObject{ .unit_type = 1, .guid = 0xDEADBEEF };
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(usize, 6), wire.len);
    try std.testing.expectEqual(@as(?usize, 6), packetSize(wire));
    try std.testing.expectEqual(p, try RemoveObject.decode(wire));
}

test "PlayerStop 0x0D round-trips + frames at SC_SIZE 13" {
    var out: [13]u8 = undefined;
    const p = PlayerStop{ .unit_type = 0, .guid = 0x1234, .mode = 6, .x = 100, .y = 200, .target_type = 3, .hp_pct = 88 };
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(usize, @intCast(SC_SIZE[0x0d])), wire.len);
    try std.testing.expectEqual(@as(?usize, 13), packetSize(wire));
    try std.testing.expectEqual(p, try PlayerStop.decode(wire));
}

test "PlayerMove 0x0F round-trips, dest x/y at 0x0C/0x0E (16 bytes)" {
    var out: [16]u8 = undefined;
    const p = PlayerMove{ .unit_type = 0, .guid = 0xABCD, .mode = 1, .skill_id = 42, .item_id = 7, .target_type = 2, .x = 5000, .y = 6000 };
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(usize, @intCast(SC_SIZE[0x0f])), wire.len);
    // destination lands at byte 0x0C/0x0E (matches world.zig applyPlayerMove)
    try std.testing.expectEqual(@as(u16, 5000), std.mem.readInt(u16, wire[0x0c..0x0e], .little));
    try std.testing.expectEqual(@as(u16, 6000), std.mem.readInt(u16, wire[0x0e..0x10], .little));
    try std.testing.expectEqual(p, try PlayerMove.decode(wire));
}

test "AssignMonster 0xAC header round-trips, body opaque, pktLen frames it" {
    const body = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const p = AssignMonster{ .guid = 0xCAFEBABE, .monster_class = -1, .x = 1234, .y = 4321, .hp_pct = 128, .body = &body };
    var out: [64]u8 = undefined;
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(usize, 17), wire.len); // 13 header + 4 body
    try std.testing.expectEqual(@as(u8, 17), wire[0x0c]); // pktLen = total size
    try std.testing.expectEqual(@as(?usize, wire.len), packetSize(wire)); // variable framing agrees
    const d = try AssignMonster.decode(wire);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), d.guid);
    try std.testing.expectEqual(@as(i16, -1), d.monster_class);
    try std.testing.expectEqual(@as(u16, 1234), d.x);
    try std.testing.expectEqual(@as(u16, 4321), d.y);
    try std.testing.expectEqual(@as(u8, 128), d.hp_pct);
    try std.testing.expectEqualSlices(u8, &body, d.body);
}

test "PlayerLeave 0x96 bit-packed move+stamina round-trip, signed deltas (9 bytes)" {
    const p = PlayerLeave{ .stamina = 20000, .x = 5000, .y = 6000, .dx = -3, .dy = 4 };
    var out: [9]u8 = undefined;
    const wire = p.encode(&out);
    try std.testing.expectEqual(@as(usize, @intCast(SC_SIZE[0x96])), wire.len);
    try std.testing.expectEqual(@as(?usize, 9), packetSize(wire));
    const d = try PlayerLeave.decode(wire);
    try std.testing.expectEqual(@as(u16, 20000), d.stamina);
    try std.testing.expectEqual(@as(u16, 5000), d.x);
    try std.testing.expectEqual(@as(u16, 6000), d.y);
    try std.testing.expectEqual(@as(i8, -3), d.dx);
    try std.testing.expectEqual(@as(i8, 4), d.dy);
}

test "ObjectState 0x0E round-trips byte-exact (12 bytes, table-sized)" {
    var buf: [16]u8 = undefined;
    const p = ObjectState{ .guid = 0x11223344, .active = 1, .anim_mode = 2 };
    const wire = p.encode(&buf);
    try std.testing.expectEqual(@as(i16, @intCast(wire.len)), SC_SIZE[0x0E]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0E, 2, 0x44, 0x33, 0x22, 0x11, 0x03, 1, 2, 0, 0, 0 }, wire);
    try std.testing.expectEqual(p, try ObjectState.decode(wire));
}

test "GoldPickup 0x19 + SetDWordAttr 0x1F round-trip, sizes match the SC table" {
    var buf: [8]u8 = undefined;
    const g = GoldPickup{ .amount = 200 };
    const gw = g.encode(&buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x19, 200 }, gw);
    try std.testing.expectEqual(@as(i16, @intCast(gw.len)), SC_SIZE[0x19]);
    try std.testing.expectEqual(g, try GoldPickup.decode(gw));

    const s = SetDWordAttr{ .attr = 0x0E, .value = 123456 };
    const sw = s.encode(&buf);
    try std.testing.expectEqual(@as(usize, 6), sw.len);
    try std.testing.expectEqual(@as(i16, @intCast(sw.len)), SC_SIZE[0x1F]);
    try std.testing.expectEqual(s, try SetDWordAttr.decode(sw));
}

test "PacketWriter concatenates several packets for one flush" {
    var buf: [64]u8 = undefined;
    var pw = PacketWriter.init(&buf);
    pw.add(RemoveObject{ .unit_type = 1, .guid = 0x10 });
    pw.add(PlayerMove{ .unit_type = 0, .guid = 0x20, .x = 1, .y = 2 });
    pw.add(AssignMonster{ .guid = 0x30, .monster_class = 5, .x = 3, .y = 4 });
    const out = pw.bytes();
    try std.testing.expectEqual(@as(usize, 6 + 16 + 13), out.len);
    // stream reframes back into the same three packets, in order
    var off: usize = 0;
    try std.testing.expectEqual(@as(?usize, 6), packetSize(out[off..]));
    try std.testing.expectEqual(@as(u32, 0x10), (try RemoveObject.decode(out[off..])).guid);
    off += 6;
    try std.testing.expectEqual(@as(?usize, 16), packetSize(out[off..]));
    try std.testing.expectEqual(@as(u32, 0x20), (try PlayerMove.decode(out[off..])).guid);
    off += 16;
    try std.testing.expectEqual(@as(?usize, 13), packetSize(out[off..]));
    try std.testing.expectEqual(@as(u32, 0x30), (try AssignMonster.decode(out[off..])).guid);
}

test "dispatch mirror: opcode -> name/cat matches 0x7114D0 handlers" {
    try std.testing.expectEqualStrings("LoadAct", info(0x03).name);
    try std.testing.expectEqual(Cat.level, info(0x03).cat);
    try std.testing.expectEqual(Cat.unit_add, info(0x59).cat);
    try std.testing.expectEqual(Cat.chat, info(0x26).cat);
    try std.testing.expectEqual(Cat.unknown, info(0xEE).cat);
}
