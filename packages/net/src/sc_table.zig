//! Server -> client opcode table, 1.14d — the whole 175-entry dispatch space.
//!
//! Generated from `NET_D2GS_CLIENT_INCOMING` @0x007114D0 (Ghidra session 62fbfe69) via
//! scripts/gen_sc_table.py. `handler` is the client function the engine actually runs for
//! the opcode, which is the honest name for it — several of the symbols in the binary are
//! misnomers, and this table records what the code does, not what the label claims.

const std = @import("std");

pub const Entry = struct {
    /// The client handler the engine dispatches to.
    handler: []const u8,
    /// The size THIS TABLE's entry declares. Note it is not the framing size: the engine
    /// frames with `NET_D2GS_CLIENT_INCOMING_SIZE` @0x730AE8 (`sc.SC_SIZE`, and
    /// `sc.packetSize` for the variable ones), and the two disagree on 0x17 and 0x80 —
    /// both dead opcodes the framing table marks invalid. Frame with `sc.packetSize`;
    /// this field is only what the handler entry claims to expect.
    expected_size: i32,
};

pub const COUNT = 175;

/// Every S->C opcode the 1.14d client dispatches, indexed by opcode.
pub const TABLE = [COUNT]Entry{
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 1 }, // 0x00 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "GameFlags", .expected_size = 8 }, // 0x01 NET_D2GS_CLIENT_Incoming0x01_GameFlags
    .{ .handler = "LoadSuccess", .expected_size = 1 }, // 0x02 NET_D2GS_CLIENT_Incoming0x02_LoadSuccess
    .{ .handler = "LoadAct", .expected_size = 12 }, // 0x03 NET_D2GS_CLIENT_Incoming0x03_LoadAct
    .{ .handler = "LoadComplete", .expected_size = 1 }, // 0x04 NET_D2GS_CLIENT_Incoming0x04_LoadComplete
    .{ .handler = "UnloadComplete", .expected_size = 1 }, // 0x05 NET_D2GS_CLIENT_Incoming0x05_UnloadComplete
    .{ .handler = "GameExit", .expected_size = 1 }, // 0x06 NET_D2GS_CLIENT_Incoming0x06_GameExit
    .{ .handler = "MapReveal", .expected_size = 6 }, // 0x07 NET_D2GS_CLIENT_Incoming0x07_MapReveal
    .{ .handler = "MapHide", .expected_size = 6 }, // 0x08 NET_D2GS_CLIENT_Incoming0x08_MapHide
    .{ .handler = "AssignLevelWarp", .expected_size = 11 }, // 0x09 NET_D2GS_CLIENT_Incoming0x09_AssignLevelWarp
    .{ .handler = "RemoveObject", .expected_size = 6 }, // 0x0a NET_D2GS_CLIENT_Incoming0x0A_RemoveObject
    .{ .handler = "HandShake", .expected_size = 6 }, // 0x0b NET_D2GS_CLIENT_Incoming0x0B_HandShake
    .{ .handler = "NpcHit", .expected_size = 9 }, // 0x0c NET_D2GS_CLIENT_Incoming0x0C_NpcHit
    .{ .handler = "PlayerStop", .expected_size = 13 }, // 0x0d NET_D2GS_CLIENT_Incoming0x0D_PlayerStop
    .{ .handler = "ObjectState", .expected_size = 12 }, // 0x0e NET_D2GS_CLIENT_Incoming0x0E_ObjectState
    .{ .handler = "PlayerMove", .expected_size = 16 }, // 0x0f NET_D2GS_CLIENT_Incoming0x0F_PlayerMove
    .{ .handler = "CharacterToObject", .expected_size = 16 }, // 0x10 NET_D2GS_CLIENT_Incoming0x10_CharacterToObject
    .{ .handler = "ReportKill", .expected_size = 8 }, // 0x11 NET_D2GS_CLIENT_Incoming0x11_ReportKill
    .{ .handler = "IncomingReturn_0045d130", .expected_size = 26 }, // 0x12 NET_D2GS_CLIENT_IncomingReturn_0045d130
    .{ .handler = "IncomingReturn_0045d140", .expected_size = 14 }, // 0x13 NET_D2GS_CLIENT_IncomingReturn_0045d140
    .{ .handler = "IncomingReturn_0045d150", .expected_size = 18 }, // 0x14 NET_D2GS_CLIENT_IncomingReturn_0045d150
    .{ .handler = "ReassignPlayer", .expected_size = 11 }, // 0x15 NET_D2GS_CLIENT_Incoming0x15_ReassignPlayer
    .{ .handler = "Incoming0x16", .expected_size = -1 }, // 0x16 NET_D2GS_CLIENT_Incoming0x16
    .{ .handler = "PlayerBeginCast", .expected_size = -1 }, // 0x17 NET_D2GS_CLIENT_Incoming0x17_PlayerBeginCast
    .{ .handler = "Incoming0x18", .expected_size = 15 }, // 0x18 NET_D2GS_CLIENT_Incoming0x18
    .{ .handler = "ItemPageUpdate", .expected_size = 2 }, // 0x19 NET_D2GS_CLIENT_Incoming0x19_ItemPageUpdate
    .{ .handler = "ItemPageUpdate", .expected_size = 2 }, // 0x1a NET_D2GS_CLIENT_Incoming0x19_ItemPageUpdate
    .{ .handler = "ItemPageUpdate", .expected_size = 3 }, // 0x1b NET_D2GS_CLIENT_Incoming0x19_ItemPageUpdate
    .{ .handler = "ItemPageUpdate", .expected_size = 5 }, // 0x1c NET_D2GS_CLIENT_Incoming0x19_ItemPageUpdate
    .{ .handler = "ItemPageUpdate", .expected_size = 3 }, // 0x1d NET_D2GS_CLIENT_Incoming0x19_ItemPageUpdate
    .{ .handler = "ItemPageUpdate", .expected_size = 4 }, // 0x1e NET_D2GS_CLIENT_Incoming0x19_ItemPageUpdate
    .{ .handler = "ItemPageUpdate", .expected_size = 6 }, // 0x1f NET_D2GS_CLIENT_Incoming0x19_ItemPageUpdate
    .{ .handler = "Incoming0x20", .expected_size = 10 }, // 0x20 NET_D2GS_CLIENT_Incoming0x20
    .{ .handler = "Incoming0x21", .expected_size = 12 }, // 0x21 NET_D2GS_CLIENT_Incoming0x21
    .{ .handler = "SkillQuantity", .expected_size = 12 }, // 0x22 NET_D2GS_CLIENT_Incoming0x22_SkillQuantity
    .{ .handler = "SelectSkill", .expected_size = 13 }, // 0x23 NET_D2GS_CLIENT_Incoming0x23_SelectSkill
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 90 }, // 0x24 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 90 }, // 0x25 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "Incoming0x26", .expected_size = -1 }, // 0x26 NET_D2GS_CLIENT_Incoming0x26
    .{ .handler = "OverheadText", .expected_size = 40 }, // 0x27 NET_D2GS_CLIENT_Incoming0x27_OverheadText
    .{ .handler = "NpcInteract", .expected_size = 103 }, // 0x28 NET_D2GS_CLIENT_Incoming0x28_NpcInteract
    .{ .handler = "Incoming0x29", .expected_size = 97 }, // 0x29 NET_D2GS_CLIENT_Incoming0x29
    .{ .handler = "Incoming0x2A", .expected_size = 15 }, // 0x2a NET_D2GS_CLIENT_Incoming0x2A
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x2b NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "Incoming0x2C", .expected_size = 8 }, // 0x2c NET_D2GS_CLIENT_Incoming0x2C
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x2d NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x2e NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x2f NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x30 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x31 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x32 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x33 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x34 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x35 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x36 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x37 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x38 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x39 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x3a NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x3b NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x3c NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x3d NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "Incoming0x3E", .expected_size = -1 }, // 0x3e NET_D2GS_CLIENT_Incoming0x3E
    .{ .handler = "Incoming0x3F", .expected_size = 8 }, // 0x3f NET_D2GS_CLIENT_Incoming0x3F
    .{ .handler = "Incoming0x40", .expected_size = 13 }, // 0x40 NET_D2GS_CLIENT_Incoming0x40
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x41 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "Incoming0x42", .expected_size = 6 }, // 0x42 NET_D2GS_CLIENT_Incoming0x42
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x43 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x44 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045e290", .expected_size = 13 }, // 0x45 NET_D2GS_CLIENT_IncomingReturn_0045e290
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x46 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "RecvRecalcEquippedItems", .expected_size = 11 }, // 0x47 NET_D2GS_CLIENT_RecvRecalcEquippedItems
    .{ .handler = "RecvRecalcEquippedItems2", .expected_size = 11 }, // 0x48 NET_D2GS_CLIENT_RecvRecalcEquippedItems2
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x49 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x4a NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x4b NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "PlayerCast", .expected_size = 16 }, // 0x4c NET_D2GS_CLIENT_Incoming0x4C_PlayerCast
    .{ .handler = "PlayerCastTarget", .expected_size = 17 }, // 0x4d NET_D2GS_CLIENT_Incoming0x4D_PlayerCastTarget
    .{ .handler = "Incoming0x4E", .expected_size = 7 }, // 0x4e NET_D2GS_CLIENT_Incoming0x4E
    .{ .handler = "Incoming0x4F", .expected_size = 1 }, // 0x4f NET_D2GS_CLIENT_Incoming0x4F
    .{ .handler = "Incoming0x50", .expected_size = 15 }, // 0x50 NET_D2GS_CLIENT_Incoming0x50
    .{ .handler = "CreateObject", .expected_size = 14 }, // 0x51 NET_D2GS_CLIENT_Incoming0x51_CreateObject
    .{ .handler = "Incoming0x52", .expected_size = 42 }, // 0x52 NET_D2GS_CLIENT_Incoming0x52
    .{ .handler = "Incoming0x53", .expected_size = 10 }, // 0x53 NET_D2GS_CLIENT_Incoming0x53
    .{ .handler = "IncomingReturn_0045e3b0", .expected_size = 3 }, // 0x54 NET_D2GS_CLIENT_IncomingReturn_0045e3b0
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x55 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x56 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "Incoming0x57", .expected_size = 14 }, // 0x57 NET_D2GS_CLIENT_Incoming0x57
    .{ .handler = "Incoming0x58", .expected_size = 7 }, // 0x58 NET_D2GS_CLIENT_Incoming0x58
    .{ .handler = "Incoming0x59", .expected_size = 26 }, // 0x59 NET_D2GS_CLIENT_Incoming0x59
    .{ .handler = "Incoming0x5A", .expected_size = 40 }, // 0x5a NET_D2GS_CLIENT_Incoming0x5A
    .{ .handler = "Incoming0x5B", .expected_size = -1 }, // 0x5b NET_D2GS_CLIENT_Incoming0x5B
    .{ .handler = "Incoming0x5C", .expected_size = 5 }, // 0x5c NET_D2GS_CLIENT_Incoming0x5C
    .{ .handler = "Incoming0x5D", .expected_size = 6 }, // 0x5d NET_D2GS_CLIENT_Incoming0x5D
    .{ .handler = "Incoming0x5E", .expected_size = 38 }, // 0x5e NET_D2GS_CLIENT_Incoming0x5E
    .{ .handler = "Incoming0x5F", .expected_size = 5 }, // 0x5f NET_D2GS_CLIENT_Incoming0x5F
    .{ .handler = "Incoming0x60", .expected_size = 7 }, // 0x60 NET_D2GS_CLIENT_Incoming0x60
    .{ .handler = "Incoming0x61", .expected_size = 2 }, // 0x61 NET_D2GS_CLIENT_Incoming0x61
    .{ .handler = "Incoming0x62", .expected_size = 7 }, // 0x62 NET_D2GS_CLIENT_Incoming0x62
    .{ .handler = "Incoming0x63", .expected_size = 21 }, // 0x63 NET_D2GS_CLIENT_Incoming0x63
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x64 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "Incoming0x65", .expected_size = 7 }, // 0x65 NET_D2GS_CLIENT_Incoming0x65
    .{ .handler = "IncomingReturn_0045e6c0", .expected_size = 7 }, // 0x66 NET_D2GS_CLIENT_IncomingReturn_0045e6c0
    .{ .handler = "MonsterStop", .expected_size = 16 }, // 0x67 NET_D2GS_CLIENT_Incoming0x67_MonsterStop
    .{ .handler = "MonsterBeginCast", .expected_size = 21 }, // 0x68 NET_D2GS_CLIENT_Incoming0x68_MonsterBeginCast
    .{ .handler = "MonsterSpell", .expected_size = 12 }, // 0x69 NET_D2GS_CLIENT_Incoming0x69_MonsterSpell
    .{ .handler = "RecvNpcStateToEntity", .expected_size = 12 }, // 0x6a NET_D2GS_CLIENT_RecvNpcStateToEntity
    .{ .handler = "MonsterBeginCastWalk", .expected_size = 16 }, // 0x6b NET_D2GS_CLIENT_Incoming0x6B_MonsterBeginCastWalk
    .{ .handler = "MonsterCastStationary", .expected_size = 16 }, // 0x6c NET_D2GS_CLIENT_Incoming0x6C_MonsterCastStationary
    .{ .handler = "Incoming0x6D", .expected_size = 10 }, // 0x6d NET_D2GS_CLIENT_Incoming0x6D
    .{ .handler = "IncomingReturn_0045d0a0", .expected_size = 1 }, // 0x6e NET_D2GS_CLIENT_IncomingReturn_0045d0a0
    .{ .handler = "IncomingReturn_0045d0b0", .expected_size = 1 }, // 0x6f NET_D2GS_CLIENT_IncomingReturn_0045d0b0
    .{ .handler = "IncomingReturn_0045d0c0", .expected_size = 1 }, // 0x70 NET_D2GS_CLIENT_IncomingReturn_0045d0c0
    .{ .handler = "IncomingReturn_0045d0d0", .expected_size = 1 }, // 0x71 NET_D2GS_CLIENT_IncomingReturn_0045d0d0
    .{ .handler = "IncomingReturn_0045d0e0", .expected_size = 1 }, // 0x72 NET_D2GS_CLIENT_IncomingReturn_0045d0e0
    .{ .handler = "WaypointInit", .expected_size = 32 }, // 0x73 NET_D2GS_CLIENT_Incoming0x73_WaypointInit
    .{ .handler = "Incoming0x74", .expected_size = 10 }, // 0x74 NET_D2GS_CLIENT_Incoming0x74
    .{ .handler = "Incoming0x75", .expected_size = 13 }, // 0x75 NET_D2GS_CLIENT_Incoming0x75
    .{ .handler = "Incoming0x76", .expected_size = 6 }, // 0x76 NET_D2GS_CLIENT_Incoming0x76
    .{ .handler = "Incoming0x77", .expected_size = 2 }, // 0x77 NET_D2GS_CLIENT_Incoming0x77
    .{ .handler = "Incoming0x78", .expected_size = 21 }, // 0x78 NET_D2GS_CLIENT_Incoming0x78
    .{ .handler = "Incoming0x79", .expected_size = 6 }, // 0x79 NET_D2GS_CLIENT_Incoming0x79
    .{ .handler = "Incoming0x7A", .expected_size = 13 }, // 0x7a NET_D2GS_CLIENT_Incoming0x7A
    .{ .handler = "SetSkillSlot", .expected_size = 8 }, // 0x7b NET_D2GS_CLIENT_Incoming0x7B_SetSkillSlot
    .{ .handler = "ItemAction", .expected_size = 6 }, // 0x7c NET_D2GS_CLIENT_Incoming0x7C_ItemAction
    .{ .handler = "Incoming0x7D", .expected_size = 18 }, // 0x7d NET_D2GS_CLIENT_Incoming0x7D
    .{ .handler = "Incoming0x7E", .expected_size = 5 }, // 0x7e NET_D2GS_CLIENT_Incoming0x7E
    .{ .handler = "Incoming0x7F", .expected_size = 10 }, // 0x7f NET_D2GS_CLIENT_Incoming0x7F
    .{ .handler = "nullptr", .expected_size = 4 }, // 0x80 nullptr
    .{ .handler = "Incoming0x81", .expected_size = 20 }, // 0x81 NET_D2GS_CLIENT_Incoming0x81
    .{ .handler = "Incoming0x82", .expected_size = 29 }, // 0x82 NET_D2GS_CLIENT_Incoming0x82
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x83 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x84 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x85 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x86 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x87 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0x88 NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "Incoming0x89", .expected_size = 2 }, // 0x89 NET_D2GS_CLIENT_Incoming0x89
    .{ .handler = "Incoming0x8A", .expected_size = 6 }, // 0x8a NET_D2GS_CLIENT_Incoming0x8A
    .{ .handler = "Incoming0x8B", .expected_size = 6 }, // 0x8b NET_D2GS_CLIENT_Incoming0x8B
    .{ .handler = "Incoming0x8C", .expected_size = 11 }, // 0x8c NET_D2GS_CLIENT_Incoming0x8C
    .{ .handler = "Incoming0x8D", .expected_size = 7 }, // 0x8d NET_D2GS_CLIENT_Incoming0x8D
    .{ .handler = "RosterOtherAllocFree", .expected_size = 10 }, // 0x8e NET_D2GS_CLIENT_Incoming0x8E_RosterOtherAllocFree
    .{ .handler = "Incoming0x8F", .expected_size = 33 }, // 0x8f NET_D2GS_CLIENT_Incoming0x8F
    .{ .handler = "Incoming0x90", .expected_size = 13 }, // 0x90 NET_D2GS_CLIENT_Incoming0x90
    .{ .handler = "Incoming0x91", .expected_size = 26 }, // 0x91 NET_D2GS_CLIENT_Incoming0x91
    .{ .handler = "Incoming0x92", .expected_size = 6 }, // 0x92 NET_D2GS_CLIENT_Incoming0x92
    .{ .handler = "RecvSkillTabBonusDelta", .expected_size = 8 }, // 0x93 NET_D2GS_CLIENT_RecvSkillTabBonusDelta
    .{ .handler = "Incoming0x94", .expected_size = -1 }, // 0x94 NET_D2GS_CLIENT_Incoming0x94
    .{ .handler = "PlayerJoin", .expected_size = 13 }, // 0x95 NET_D2GS_CLIENT_Incoming0x95_PlayerJoin
    .{ .handler = "PlayerLeave", .expected_size = 9 }, // 0x96 NET_D2GS_CLIENT_Incoming0x96_PlayerLeave
    .{ .handler = "Incoming0x9", .expected_size = 1 }, // 0x97 NET_D2GS_CLIENT_Incoming0x9
    .{ .handler = "Incoming0x98", .expected_size = 7 }, // 0x98 NET_D2GS_CLIENT_Incoming0x98
    .{ .handler = "Incoming0x99", .expected_size = 16 }, // 0x99 NET_D2GS_CLIENT_Incoming0x99
    .{ .handler = "Incoming0x9A", .expected_size = 17 }, // 0x9a NET_D2GS_CLIENT_Incoming0x9A
    .{ .handler = "Incoming0x9B", .expected_size = 7 }, // 0x9b NET_D2GS_CLIENT_Incoming0x9B
    .{ .handler = "Incoming0x9C", .expected_size = -1 }, // 0x9c NET_D2GS_CLIENT_Incoming0x9C
    .{ .handler = "Incoming0x9D", .expected_size = -1 }, // 0x9d NET_D2GS_CLIENT_Incoming0x9D
    .{ .handler = "Incoming0x9Eto0xA2", .expected_size = 7 }, // 0x9e NET_D2GS_CLIENT_Incoming0x9Eto0xA2
    .{ .handler = "Incoming0x9Eto0xA2", .expected_size = 8 }, // 0x9f NET_D2GS_CLIENT_Incoming0x9Eto0xA2
    .{ .handler = "Incoming0x9Eto0xA2", .expected_size = 10 }, // 0xa0 NET_D2GS_CLIENT_Incoming0x9Eto0xA2
    .{ .handler = "Incoming0x9Eto0xA2", .expected_size = 7 }, // 0xa1 NET_D2GS_CLIENT_Incoming0x9Eto0xA2
    .{ .handler = "Incoming0x9Eto0xA2", .expected_size = 8 }, // 0xa2 NET_D2GS_CLIENT_Incoming0x9Eto0xA2
    .{ .handler = "Incoming0xA3", .expected_size = 24 }, // 0xa3 NET_D2GS_CLIENT_Incoming0xA3
    .{ .handler = "Incoming0xA4", .expected_size = 3 }, // 0xa4 NET_D2GS_CLIENT_Incoming0xA4
    .{ .handler = "Incoming0xA5", .expected_size = 8 }, // 0xa5 NET_D2GS_CLIENT_Incoming0xA5
    .{ .handler = "Incoming0xA6", .expected_size = -1 }, // 0xa6 NET_D2GS_CLIENT_Incoming0xA6
    .{ .handler = "Incoming0xA7", .expected_size = 7 }, // 0xa7 NET_D2GS_CLIENT_Incoming0xA7
    .{ .handler = "Incoming0xA8", .expected_size = -1 }, // 0xa8 NET_D2GS_CLIENT_Incoming0xA8
    .{ .handler = "Incoming0xA9", .expected_size = 7 }, // 0xa9 NET_D2GS_CLIENT_Incoming0xA9
    .{ .handler = "Incoming0xAA", .expected_size = -1 }, // 0xaa NET_D2GS_CLIENT_Incoming0xAA
    .{ .handler = "Incoming0xAB", .expected_size = 7 }, // 0xab NET_D2GS_CLIENT_Incoming0xAB
    .{ .handler = "Incoming0xAC", .expected_size = -1 }, // 0xac NET_D2GS_CLIENT_Incoming0xAC
    .{ .handler = "IncomingReturn_0045c900", .expected_size = 0 }, // 0xad NET_D2GS_CLIENT_IncomingReturn_0045c900
    .{ .handler = "Incoming0xAE", .expected_size = -1 }, // 0xae NET_D2GS_CLIENT_Incoming0xAE
};

/// The handler name for an opcode, or null when the opcode is outside the table.
pub fn handler(op: u8) ?[]const u8 {
    if (op >= COUNT) return null;
    return TABLE[op].handler;
}

test "the table covers the engine's whole dispatch space" {
    try std.testing.expectEqual(@as(usize, 175), TABLE.len);
    try std.testing.expectEqualStrings("LoadAct", TABLE[0x03].handler);
    try std.testing.expectEqual(@as(i32, 12), TABLE[0x03].expected_size);
    try std.testing.expect(handler(0xff) == null);
}
