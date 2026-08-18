//! C-ABI shim for the d2-net package: exposes the D2GS server->client wire protocol (1.14d) —
//! frame demux, per-opcode wire sizing and the decoders a bot consumes — to C/C++/C#/Go/Node and
//! to the combined wasm reactor module. NO Zig types cross the boundary: only C primitives, fixed
//! ints, pointers and `extern struct`s the caller owns. Nothing is allocated, so nothing has to be
//! freed and there is no context handle: every export is a pure function over caller memory.
//!
//! Every decoder takes the raw packet bytes and returns the WIRE SIZE it consumed (>0) on success,
//! so a caller can advance a cursor with the same call that decodes. 0 means "not this / none" and
//! a negative value is an error (D2NET_ERR_*). Variable-length bodies (item bitstreams, the 0xAC
//! stat stream, chat strings) are reported as an offset+length INTO THE CALLER'S OWN BUFFER — the
//! shim never copies them and never hands back a pointer it owns.
//!
//! Sizing and per-opcode layout come from `lib.sc`, which mirrors
//! `NET_D2GS_CLIENT_INCOMING_SIZE @0x730AE8` and
//! `GetIncomingPacketSizeFromTableAndVariableSize @0x52B920` (Ghidra session 62fbfe69). This file
//! adds no protocol knowledge of its own — it only reshapes `lib.sc` into C.

const std = @import("std");
// Imported as a MODULE, not as a relative file: this shim is also linked into the combined wasm
// alongside the other subsystems' shims, and a file may belong to only one module.
const lib = @import("d2-net");
const sc = lib.sc;

/// Error codes. Also mirrored in d2net.h as D2NET_ERR_*.
const ERR_ARGS: i32 = -1; // null pointer, or a negative length/capacity
const ERR_SHORT: i32 = -2; // the buffer does not hold the whole packet yet
const ERR_OPCODE: i32 = -3; // the packet at buf[0] is not the one this decoder reads

fn view(buf: ?[*]const u8, len: i32) ?[]const u8 {
    const p = buf orelse return null;
    if (len < 0) return null;
    return p[0..@intCast(len)];
}

fn errCode(e: anyerror) i32 {
    return switch (e) {
        error.WrongOpcode => ERR_OPCODE,
        else => ERR_SHORT,
    };
}

/// The wire size of the first S->C packet in `buf`, INCLUDING the opcode byte and covering the
/// variable-length opcodes (0x16 0x26 0x3E 0x5B 0x94 0x9C 0x9D 0xA6 0xA8 0xAA 0xAC 0xAE 0xAF 0xB3),
/// whose size is derived from header fields exactly as the engine derives it.
/// Returns: >0 the size; 0 the whole packet is not present yet (feed more bytes); ERR_ARGS on bad
/// arguments; ERR_OPCODE when the opcode is unknown or table-invalid, which on a real stream means
/// the reader has desynced.
export fn d2net_sc_packet_size(buf: ?[*]const u8, len: i32) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const n = sc.packetSize(b) orelse return 0;
    if (n == 0) return ERR_OPCODE;
    return @intCast(n);
}

/// The raw `NET_D2GS_CLIENT_INCOMING_SIZE` entry for `opcode`: >0 a fixed wire size, 0 an
/// invalid/stub opcode, -1 variable (use d2net_sc_packet_size on the bytes). ERR_ARGS if the
/// opcode is outside 0x00..0xB4.
export fn d2net_sc_table_size(opcode: i32) i32 {
    if (opcode < 0 or opcode > sc.MAX_OPCODE) return ERR_ARGS;
    return sc.SC_SIZE[@intCast(opcode)];
}

/// The opcode's handler category (D2NET_CAT_*, the `sc.Cat` ordinal), or ERR_ARGS if the opcode is
/// outside 0x00..0xFF. Unhandled opcodes report D2NET_CAT_UNKNOWN.
export fn d2net_sc_opcode_category(opcode: i32) i32 {
    if (opcode < 0 or opcode > 0xFF) return ERR_ARGS;
    return @intFromEnum(sc.info(@intCast(opcode)).cat);
}

/// Write the opcode's short handler name (the 1.14d Ghidra symbol; "?" when unhandled) into `buf`,
/// NUL-terminating if it fits, and return its FULL byte length (which may exceed `cap`, meaning it
/// was truncated). ERR_ARGS on bad arguments.
export fn d2net_sc_opcode_name(opcode: i32, buf: ?[*]u8, cap: i32) i32 {
    if (opcode < 0 or opcode > 0xFF or cap < 0) return ERR_ARGS;
    const out = buf orelse return ERR_ARGS;
    const s = sc.info(@intCast(opcode)).name;
    const cap_us: usize = @intCast(cap);
    const n = @min(s.len, cap_us);
    @memcpy(out[0..n], s[0..n]);
    if (n < cap_us) out[n] = 0;
    return @intCast(s.len);
}

// --- length-prefix framing -------------------------------------------------------------------

/// Bytes the length header of a `packet_len`-byte packet occupies (1 or 2). The header's value is
/// the packet's own length and does NOT count the header, so one byte covers up to 0xEF.
export fn d2net_frame_header_len(packet_len: i32) i32 {
    if (packet_len < 0) return ERR_ARGS;
    return @intCast(sc.frameHeaderLen(@intCast(packet_len)));
}

/// Demux ONE length-prefixed frame off the front of `buf` (the inverse of d2net_frame_write).
/// Writes the packet's offset within `buf` to `out_offset` and its length to `out_packet_len`, and
/// returns the TOTAL bytes the frame consumed (header included) so the caller can advance.
/// Returns 0 when the frame is not fully present yet or the header is degenerate — in both cases
/// the caller should read more bytes and retry; ERR_ARGS on bad arguments.
export fn d2net_frame_next(buf: ?[*]const u8, len: i32, out_offset: ?*i32, out_packet_len: ?*i32) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const fr = sc.nextFrame(b) orelse return 0;
    if (out_offset) |o| o.* = @intCast(fr.total - fr.packet.len);
    if (out_packet_len) |o| o.* = @intCast(fr.packet.len);
    return @intCast(fr.total);
}

/// Frame one packet: write its length header followed by the packet bytes into `out`, returning the
/// total bytes written (header + packet). ERR_ARGS on bad arguments, ERR_SHORT when `out_cap` is
/// too small for the frame.
export fn d2net_frame_write(out: ?[*]u8, out_cap: i32, packet: ?[*]const u8, packet_len: i32) i32 {
    const o = out orelse return ERR_ARGS;
    const p = view(packet, packet_len) orelse return ERR_ARGS;
    if (out_cap < 0 or p.len + sc.frameHeaderLen(p.len) > @as(usize, @intCast(out_cap))) return ERR_SHORT;
    const framed = sc.frameInto(o[0..@intCast(out_cap)], p);
    return @intCast(framed.len);
}

// --- decoders -------------------------------------------------------------------------------

/// 0x03 LoadAct. `map_seed` is the DRLG seed the act was generated from — the value d2drlg needs
/// to reproduce this game's maps. `area` is the Levels.txt id the player lands in.
pub const D2NetLoadAct = extern struct {
    act: i32,
    map_seed: u32,
    area: i32,
    automap: u32,
};

/// Decode 0x03 LoadAct into `out`. Returns the wire size (12) or a negative error.
export fn d2net_sc_load_act(buf: ?[*]const u8, len: i32, out: ?*D2NetLoadAct) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.LoadAct.decode(b) catch |e| return errCode(e);
    o.* = .{ .act = p.act, .map_seed = p.map_seed, .area = p.area, .automap = p.automap };
    return @intCast(sc.LoadAct.SIZE);
}

/// 0x01 GameFlags: the game's difficulty and expansion/ladder flags.
pub const D2NetGameFlags = extern struct {
    difficulty: i32,
    arena: u32,
    expansion: i32,
    ladder: i32,
};

/// Decode 0x01 GameFlags into `out`. Returns the wire size (8) or a negative error.
export fn d2net_sc_game_flags(buf: ?[*]const u8, len: i32, out: ?*D2NetGameFlags) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.GameFlags.decode(b) catch |e| return errCode(e);
    o.* = .{
        .difficulty = p.difficulty,
        .arena = p.arena,
        .expansion = @intFromBool(p.expansion),
        .ladder = @intFromBool(p.ladder),
    };
    return @intCast(sc.GameFlags.SIZE);
}

/// 0x59 CreatePlayer. `name` is the 16-byte NUL-padded wire field, kept verbatim so the caller
/// decides how to make a string of it; `class_id` is the eD2PlayerClass.
pub const D2NetCreatePlayer = extern struct {
    guid: u32,
    class_id: i32,
    x: i32,
    y: i32,
    name: [16]u8,
};

/// Decode 0x59 CreatePlayer into `out`. Returns the wire size (26) or a negative error.
export fn d2net_sc_create_player(buf: ?[*]const u8, len: i32, out: ?*D2NetCreatePlayer) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.CreatePlayer.decode(b) catch |e| return errCode(e);
    o.* = .{ .guid = p.guid, .class_id = p.class_id, .x = p.x, .y = p.y, .name = p.name };
    return @intCast(sc.CreatePlayer.SIZE);
}

/// 0xAC AssignMonster. `monster_class` is a signed eD2MonStatsId (-1 = none) and `hp_pct` the
/// 128-scale health fraction. The trailing Fog::BitBuffer flag/stat stream is reported as
/// `body_offset`/`body_len` into the caller's buffer — decoding it needs the game tables and
/// belongs above this wire layer.
pub const D2NetAssignMonster = extern struct {
    guid: u32,
    monster_class: i32,
    x: i32,
    y: i32,
    hp_pct: i32,
    body_offset: i32,
    body_len: i32,
};

/// Decode 0xAC AssignMonster into `out`. Returns the packet's TOTAL wire size (13 + body) or a
/// negative error.
export fn d2net_sc_assign_monster(buf: ?[*]const u8, len: i32, out: ?*D2NetAssignMonster) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.AssignMonster.decode(b) catch |e| return errCode(e);
    o.* = .{
        .guid = p.guid,
        .monster_class = p.monster_class,
        .x = p.x,
        .y = p.y,
        .hp_pct = p.hp_pct,
        .body_offset = @intCast(sc.AssignMonster.HEADER),
        .body_len = @intCast(p.body.len),
    };
    return @intCast(p.wireLen());
}

/// 0x09 AssignLevelWarp: a clickable inter-level warp appearing in view.
pub const D2NetAssignLevelWarp = extern struct {
    unit_type: i32,
    guid: u32,
    class_id: i32,
    x: i32,
    y: i32,
};

/// Decode 0x09 AssignLevelWarp into `out`. Returns the wire size (11) or a negative error.
export fn d2net_sc_assign_level_warp(buf: ?[*]const u8, len: i32, out: ?*D2NetAssignLevelWarp) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.AssignLevelWarp.decode(b) catch |e| return errCode(e);
    o.* = .{ .unit_type = p.unit_type, .guid = p.guid, .class_id = p.class_id, .x = p.x, .y = p.y };
    return @intCast(sc.AssignLevelWarp.SIZE);
}

/// 0x18 Life / 0x95 PlayerJoin: the LOCAL player's hp/mana/stamina and position. Bit-packed and
/// carrying no GUID — it is always the receiving player. `hp_regen`/`mp_regen` exist on 0x18 only
/// and read 0 for 0x95. hp/mp/stamina are whole points (the engine keeps them <<8 internally).
pub const D2NetLife = extern struct {
    opcode: i32,
    hp: i32,
    mp: i32,
    stamina: i32,
    hp_regen: i32,
    mp_regen: i32,
    x: i32,
    y: i32,
};

/// Decode 0x18 Life or 0x95 PlayerJoin into `out`. Returns the wire size (15 for 0x18, 13 for
/// 0x95) or a negative error.
export fn d2net_sc_life(buf: ?[*]const u8, len: i32, out: ?*D2NetLife) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.Life.decode(b) catch |e| return errCode(e);
    o.* = .{
        .opcode = p.opcode,
        .hp = p.hp,
        .mp = p.mp,
        .stamina = p.stamina,
        .hp_regen = p.hp_regen,
        .mp_regen = p.mp_regen,
        .x = p.x,
        .y = p.y,
    };
    return @intCast(p.wireLen());
}

/// 0x9C Item. `action` is the item action (0 add, 1 picked, 2 dropped, 3 on-ground, …). The item
/// itself is a bitstream reported as `body_offset`/`body_len` into the caller's buffer — feed it to
/// the item layer (d2-item), which is where item semantics live.
pub const D2NetItem = extern struct {
    action: i32,
    guid: u32,
    body_offset: i32,
    body_len: i32,
};

/// Decode 0x9C Item into `out`. Returns the packet's TOTAL wire size (8 + body) or a negative
/// error.
export fn d2net_sc_item(buf: ?[*]const u8, len: i32, out: ?*D2NetItem) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.ItemAction.decode(b) catch |e| return errCode(e);
    o.* = .{
        .action = p.action,
        .guid = p.guid,
        .body_offset = @intCast(sc.ItemAction.HEADER),
        .body_len = @intCast(p.body.len),
    };
    return @intCast(p.wireLen());
}

/// 0x0F PlayerMove / 0x10 CharacterToObject: a unit walking or running. `x`/`y` are the move
/// DESTINATION; `skill_id`/`item_id` are the generic message params the engine passes through.
pub const D2NetPlayerMove = extern struct {
    unit_type: i32,
    guid: u32,
    mode: i32,
    skill_id: i32,
    item_id: i32,
    target_type: i32,
    x: i32,
    y: i32,
};

/// Decode 0x0F PlayerMove into `out`. Returns the wire size (16) or a negative error. 0x10
/// CharacterToObject has the same layout and the same size; pass it with its own opcode byte
/// rewritten to 0x0F, or use d2net_sc_unit_pos, which accepts both.
export fn d2net_sc_player_move(buf: ?[*]const u8, len: i32, out: ?*D2NetPlayerMove) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.PlayerMove.decode(b) catch |e| return errCode(e);
    o.* = .{
        .unit_type = p.unit_type,
        .guid = p.guid,
        .mode = p.mode,
        .skill_id = p.skill_id,
        .item_id = p.item_id,
        .target_type = p.target_type,
        .x = p.x,
        .y = p.y,
    };
    return @intCast(sc.PlayerMove.SIZE);
}

/// 0x0D PlayerStop: a unit came to rest at `x`/`y`. `hp_pct` is a party-roster health update and
/// is only meaningful for players (`unit_type` 0).
pub const D2NetPlayerStop = extern struct {
    unit_type: i32,
    guid: u32,
    mode: i32,
    x: i32,
    y: i32,
    target_type: i32,
    hp_pct: i32,
};

/// Decode 0x0D PlayerStop into `out`. Returns the wire size (13) or a negative error.
export fn d2net_sc_player_stop(buf: ?[*]const u8, len: i32, out: ?*D2NetPlayerStop) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.PlayerStop.decode(b) catch |e| return errCode(e);
    o.* = .{
        .unit_type = p.unit_type,
        .guid = p.guid,
        .mode = p.mode,
        .x = p.x,
        .y = p.y,
        .target_type = p.target_type,
        .hp_pct = p.hp_pct,
    };
    return @intCast(sc.PlayerStop.SIZE);
}

/// 0x15 ReassignPlayer: a unit is teleported/snapped to `x`/`y` rather than pathed there.
pub const D2NetReassignPlayer = extern struct {
    unit_type: i32,
    guid: u32,
    x: i32,
    y: i32,
    move_flag: i32,
};

/// Decode 0x15 ReassignPlayer into `out`. Returns the wire size (11) or a negative error.
export fn d2net_sc_reassign_player(buf: ?[*]const u8, len: i32, out: ?*D2NetReassignPlayer) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.ReassignPlayer.decode(b) catch |e| return errCode(e);
    o.* = .{ .unit_type = p.unit_type, .guid = p.guid, .x = p.x, .y = p.y, .move_flag = p.move_flag };
    return @intCast(sc.ReassignPlayer.SIZE);
}

/// 0x96: despite the handler-table name "PlayerLeave" this removes nobody — it is the LOCAL
/// player's bit-packed stamina + position update, with `dx`/`dy` as SIGNED step deltas.
pub const D2NetLocalMove = extern struct {
    stamina: i32,
    x: i32,
    y: i32,
    dx: i32,
    dy: i32,
};

/// Decode 0x96 into `out`. Returns the wire size (9) or a negative error.
export fn d2net_sc_local_move(buf: ?[*]const u8, len: i32, out: ?*D2NetLocalMove) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.PlayerLeave.decode(b) catch |e| return errCode(e);
    o.* = .{ .stamina = p.stamina, .x = p.x, .y = p.y, .dx = p.dx, .dy = p.dy };
    return @intCast(sc.PlayerLeave.SIZE);
}

/// 0x0A RemoveObject: a unit left view or died.
pub const D2NetRemoveObject = extern struct {
    unit_type: i32,
    guid: u32,
};

/// Decode 0x0A RemoveObject into `out`. Returns the wire size (6) or a negative error.
export fn d2net_sc_remove_object(buf: ?[*]const u8, len: i32, out: ?*D2NetRemoveObject) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.RemoveObject.decode(b) catch |e| return errCode(e);
    o.* = .{ .unit_type = p.unit_type, .guid = p.guid };
    return @intCast(sc.RemoveObject.SIZE);
}

/// 0xAB UnitHpPercent: a unit's health-bar update, `hp_pct` on the 128 scale (0x80 = full).
pub const D2NetUnitHpPercent = extern struct {
    unit_type: i32,
    guid: u32,
    hp_pct: i32,
};

/// Decode 0xAB UnitHpPercent into `out`. Returns the wire size (7) or a negative error.
export fn d2net_sc_unit_hp_percent(buf: ?[*]const u8, len: i32, out: ?*D2NetUnitHpPercent) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.UnitHpPercent.decode(b) catch |e| return errCode(e);
    o.* = .{ .unit_type = p.unit_type, .guid = p.guid, .hp_pct = p.hp_pct };
    return @intCast(sc.UnitHpPercent.SIZE);
}

/// 0x26 ChatMessage. The two NUL-terminated strings are reported as offsets/lengths into the
/// caller's buffer (lengths exclude the terminator), so nothing is copied.
pub const D2NetChat = extern struct {
    msg_type: i32,
    sub_type: i32,
    unit_guid: u32,
    color: i32,
    name_offset: i32,
    name_len: i32,
    msg_offset: i32,
    msg_len: i32,
};

/// Decode 0x26 ChatMessage into `out`. Returns the packet's TOTAL wire size or a negative error.
export fn d2net_sc_chat(buf: ?[*]const u8, len: i32, out: ?*D2NetChat) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    const p = sc.Chat.decode(b) catch |e| return errCode(e);
    o.* = .{
        .msg_type = p.msg_type,
        .sub_type = p.sub_type,
        .unit_guid = p.unit_guid,
        .color = p.color,
        .name_offset = @intCast(sc.Chat.HEADER),
        .name_len = @intCast(p.name.len),
        .msg_offset = @intCast(sc.Chat.HEADER + p.name.len + 1),
        .msg_len = @intCast(p.msg.len),
    };
    return @intCast(p.wireLen());
}

/// "Which unit is now where" — the one thing a world model needs from every position-bearing
/// packet, so a consumer does not have to know each opcode's byte layout.
pub const D2NetUnitPos = extern struct {
    unit_type: i32,
    guid: u32,
    x: i32,
    y: i32,
};

/// Decode the unit type/GUID/position out of ANY position-bearing S->C packet: 0x09
/// AssignLevelWarp, 0x0D PlayerStop, 0x0F PlayerMove, 0x10 CharacterToObject, 0x15
/// ReassignPlayer, 0x51 CreateObject, 0x59 CreatePlayer and 0xAC AssignMonster. For 0x59 and
/// 0xAC — which carry no unit-type byte — `unit_type` is filled in as 0 (player) and 1 (monster)
/// respectively. Returns the packet's wire size (>0), 0 when the opcode carries no unit position
/// (nothing written to `out`), or a negative error.
export fn d2net_sc_unit_pos(buf: ?[*]const u8, len: i32, out: ?*D2NetUnitPos) i32 {
    const b = view(buf, len) orelse return ERR_ARGS;
    const o = out orelse return ERR_ARGS;
    if (b.len == 0) return ERR_SHORT;
    switch (b[0]) {
        sc.AssignLevelWarp.OPCODE => {
            const p = sc.AssignLevelWarp.decode(b) catch |e| return errCode(e);
            o.* = .{ .unit_type = p.unit_type, .guid = p.guid, .x = p.x, .y = p.y };
            return @intCast(sc.AssignLevelWarp.SIZE);
        },
        sc.PlayerStop.OPCODE => {
            const p = sc.PlayerStop.decode(b) catch |e| return errCode(e);
            o.* = .{ .unit_type = p.unit_type, .guid = p.guid, .x = p.x, .y = p.y };
            return @intCast(sc.PlayerStop.SIZE);
        },
        // 0x10 CharacterToObject shares 0x0F's layout and its 16-byte table size.
        sc.PlayerMove.OPCODE, 0x10 => {
            if (b.len < sc.PlayerMove.SIZE) return ERR_SHORT;
            o.* = .{
                .unit_type = b[1],
                .guid = std.mem.readInt(u32, b[2..6], .little),
                .x = std.mem.readInt(u16, b[0x0c..0x0e], .little),
                .y = std.mem.readInt(u16, b[0x0e..0x10], .little),
            };
            return @intCast(sc.PlayerMove.SIZE);
        },
        sc.ReassignPlayer.OPCODE => {
            const p = sc.ReassignPlayer.decode(b) catch |e| return errCode(e);
            o.* = .{ .unit_type = p.unit_type, .guid = p.guid, .x = p.x, .y = p.y };
            return @intCast(sc.ReassignPlayer.SIZE);
        },
        sc.CreateObject.OPCODE => {
            const p = sc.CreateObject.decode(b) catch |e| return errCode(e);
            o.* = .{ .unit_type = p.unit_type, .guid = p.guid, .x = p.x, .y = p.y };
            return @intCast(sc.CreateObject.SIZE);
        },
        sc.CreatePlayer.OPCODE => {
            const p = sc.CreatePlayer.decode(b) catch |e| return errCode(e);
            o.* = .{ .unit_type = 0, .guid = p.guid, .x = p.x, .y = p.y };
            return @intCast(sc.CreatePlayer.SIZE);
        },
        sc.AssignMonster.OPCODE => {
            const p = sc.AssignMonster.decode(b) catch |e| return errCode(e);
            o.* = .{ .unit_type = 1, .guid = p.guid, .x = p.x, .y = p.y };
            return @intCast(p.wireLen());
        },
        else => return 0,
    }
}

export fn d2net_abi_version() u32 {
    return 1;
}

// --- tests ---------------------------------------------------------------------------------
//
// The fixtures are the packets a live 1.14d capture produced when a sorceress joined the Rogue
// Encampment: LoadAct act=0 area=1 mapSeed=0x478248B7, CreatePlayer "EpicSorc" guid=0x14 at
// (260,180), AssignLevelWarp guid=0x13 at (284,180), Life hp=704 mp=243. Every assertion compares
// a COMPLETE struct or a COMPLETE byte slice.

const testing = std.testing;

test "d2net_sc_load_act decodes the capture's LoadAct whole" {
    const wire = [_]u8{ 0x03, 0x00, 0xB7, 0x48, 0x82, 0x47, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // The very bytes sc.LoadAct emits for those values — the fixture is not hand-waved.
    var enc: [12]u8 = undefined;
    try testing.expectEqualSlices(u8, &wire, (sc.LoadAct{
        .act = 0,
        .map_seed = 0x478248B7,
        .area = 1,
        .automap = 0,
    }).encode(&enc));

    var out: D2NetLoadAct = undefined;
    try testing.expectEqual(@as(i32, 12), d2net_sc_load_act(&wire, wire.len, &out));
    try testing.expectEqualDeep(D2NetLoadAct{ .act = 0, .map_seed = 0x478248B7, .area = 1, .automap = 0 }, out);
}

test "d2net_sc_create_player decodes name/class/pos whole" {
    const wire = [_]u8{
        0x59, 0x14, 0x00, 0x00, 0x00, 0x01,
        'E',  'p',  'i',  'c',  'S',  'o',
        'r',  'c',  0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x04, 0x01,
        0xB4, 0x00,
    };
    var p = sc.CreatePlayer{ .guid = 0x14, .class_id = 1, .x = 260, .y = 180 };
    p.setName("EpicSorc");
    var enc: [26]u8 = undefined;
    try testing.expectEqualSlices(u8, &wire, p.encode(&enc));

    var out: D2NetCreatePlayer = undefined;
    try testing.expectEqual(@as(i32, 26), d2net_sc_create_player(&wire, wire.len, &out));
    try testing.expectEqualDeep(D2NetCreatePlayer{
        .guid = 0x14,
        .class_id = 1,
        .x = 260,
        .y = 180,
        .name = [_]u8{ 'E', 'p', 'i', 'c', 'S', 'o', 'r', 'c', 0, 0, 0, 0, 0, 0, 0, 0 },
    }, out);
}

test "d2net_sc_assign_level_warp decodes the capture's warp whole" {
    const wire = [_]u8{ 0x09, 0x00, 0x13, 0x00, 0x00, 0x00, 0x00, 0x1C, 0x01, 0xB4, 0x00 };
    var enc: [11]u8 = undefined;
    try testing.expectEqualSlices(u8, &wire, (sc.AssignLevelWarp{
        .unit_type = 0,
        .guid = 0x13,
        .class_id = 0,
        .x = 284,
        .y = 180,
    }).encode(&enc));

    var out: D2NetAssignLevelWarp = undefined;
    try testing.expectEqual(@as(i32, 11), d2net_sc_assign_level_warp(&wire, wire.len, &out));
    try testing.expectEqualDeep(D2NetAssignLevelWarp{
        .unit_type = 0,
        .guid = 0x13,
        .class_id = 0,
        .x = 284,
        .y = 180,
    }, out);
}

test "d2net_sc_life decodes the capture's bit-packed 0x18 whole" {
    // hp=704 mp=243 at (260,180). 0x18 packs op8+hp15+mp15+stam15+hpRegen7+mpRegen7+x16+y16 = 99
    // bits into the table's 15-byte frame, so the last 21 bits are zero padding.
    const wire = [_]u8{
        0x18, 0xC0, 0x82, 0x79, 0x00, 0x00, 0x00, 0x00,
        0x20, 0x08, 0xA0, 0x05, 0x00, 0x00, 0x00,
    };
    var enc: [15]u8 = undefined;
    try testing.expectEqualSlices(u8, &wire, (sc.Life{
        .opcode = sc.Life.OP_LIFE,
        .hp = 704,
        .mp = 243,
        .stamina = 0,
        .x = 260,
        .y = 180,
    }).encode(&enc));

    var out: D2NetLife = undefined;
    try testing.expectEqual(@as(i32, 15), d2net_sc_life(&wire, wire.len, &out));
    try testing.expectEqualDeep(D2NetLife{
        .opcode = 0x18,
        .hp = 704,
        .mp = 243,
        .stamina = 0,
        .hp_regen = 0,
        .mp_regen = 0,
        .x = 260,
        .y = 180,
    }, out);
}

test "d2net_sc_life also reads the 13-byte 0x95 form, with no regen fields" {
    var enc: [15]u8 = undefined;
    const wire = (sc.Life{
        .opcode = sc.Life.OP_JOIN,
        .hp = 704,
        .mp = 243,
        .stamina = 512,
        .x = 260,
        .y = 180,
    }).encode(&enc);
    // 85 bits (no regen pair) inside the table's 13-byte frame; independently bit-packed by hand.
    try testing.expectEqualSlices(u8, &[_]u8{
        0x95, 0xC0, 0x82, 0x79, 0x00, 0x80, 0x80, 0x20, 0x80, 0x16, 0x00, 0x00, 0x00,
    }, wire);

    var out: D2NetLife = undefined;
    try testing.expectEqual(@as(i32, 13), d2net_sc_life(wire.ptr, @intCast(wire.len), &out));
    try testing.expectEqualDeep(D2NetLife{
        .opcode = 0x95,
        .hp = 704,
        .mp = 243,
        .stamina = 512,
        .hp_regen = 0,
        .mp_regen = 0,
        .x = 260,
        .y = 180,
    }, out);
}

test "d2net_sc_item reports the item bitstream as an offset into the caller's buffer" {
    const body = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var enc: [32]u8 = undefined;
    const wire = (sc.ItemAction{ .action = 3, .guid = 0x2A, .body = &body }).encode(&enc);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x9C, 0x03, 0x0C, 0x00, 0x2A, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF,
    }, wire);

    var out: D2NetItem = undefined;
    try testing.expectEqual(@as(i32, 12), d2net_sc_item(wire.ptr, @intCast(wire.len), &out));
    try testing.expectEqualDeep(D2NetItem{ .action = 3, .guid = 0x2A, .body_offset = 8, .body_len = 4 }, out);
    try testing.expectEqualSlices(u8, &body, wire[8..12]);
}

test "d2net_sc_assign_monster reports header + bitstream span, size from pktLen" {
    const body = [_]u8{ 0x11, 0x22, 0x33 };
    var enc: [32]u8 = undefined;
    const wire = (sc.AssignMonster{
        .guid = 0x1234,
        .monster_class = 58,
        .x = 5000,
        .y = 5100,
        .hp_pct = 0x80,
        .body = &body,
    }).encode(&enc);
    try testing.expectEqualSlices(u8, &[_]u8{
        0xAC, 0x34, 0x12, 0x00, 0x00, 0x3A, 0x00, 0x88,
        0x13, 0xEC, 0x13, 0x80, 0x10, 0x11, 0x22, 0x33,
    }, wire);

    var out: D2NetAssignMonster = undefined;
    try testing.expectEqual(@as(i32, 16), d2net_sc_assign_monster(wire.ptr, @intCast(wire.len), &out));
    try testing.expectEqualDeep(D2NetAssignMonster{
        .guid = 0x1234,
        .monster_class = 58,
        .x = 5000,
        .y = 5100,
        .hp_pct = 0x80,
        .body_offset = 13,
        .body_len = 3,
    }, out);
    // A negative monstatId stays negative across the boundary (-1 = none).
    const none = (sc.AssignMonster{ .guid = 1, .monster_class = -1 }).encode(&enc);
    try testing.expectEqual(@as(i32, 13), d2net_sc_assign_monster(none.ptr, @intCast(none.len), &out));
    try testing.expectEqualDeep(D2NetAssignMonster{
        .guid = 1,
        .monster_class = -1,
        .x = 0,
        .y = 0,
        .hp_pct = 0,
        .body_offset = 13,
        .body_len = 0,
    }, out);
}

test "d2net_sc_player_move / player_stop / reassign_player / local_move decode whole" {
    var enc: [16]u8 = undefined;

    const mv = (sc.PlayerMove{
        .unit_type = 0,
        .guid = 0x14,
        .mode = 1,
        .skill_id = 42,
        .item_id = 7,
        .target_type = 2,
        .x = 260,
        .y = 180,
    }).encode(&enc);
    var mv_out: D2NetPlayerMove = undefined;
    try testing.expectEqual(@as(i32, 16), d2net_sc_player_move(mv.ptr, @intCast(mv.len), &mv_out));
    try testing.expectEqualDeep(D2NetPlayerMove{
        .unit_type = 0,
        .guid = 0x14,
        .mode = 1,
        .skill_id = 42,
        .item_id = 7,
        .target_type = 2,
        .x = 260,
        .y = 180,
    }, mv_out);

    const st = (sc.PlayerStop{
        .unit_type = 0,
        .guid = 0x14,
        .mode = 6,
        .x = 260,
        .y = 180,
        .target_type = 3,
        .hp_pct = 88,
    }).encode(&enc);
    var st_out: D2NetPlayerStop = undefined;
    try testing.expectEqual(@as(i32, 13), d2net_sc_player_stop(st.ptr, @intCast(st.len), &st_out));
    try testing.expectEqualDeep(D2NetPlayerStop{
        .unit_type = 0,
        .guid = 0x14,
        .mode = 6,
        .x = 260,
        .y = 180,
        .target_type = 3,
        .hp_pct = 88,
    }, st_out);

    const rp = (sc.ReassignPlayer{ .unit_type = 0, .guid = 0x14, .x = 284, .y = 180, .move_flag = 1 }).encode(&enc);
    var rp_out: D2NetReassignPlayer = undefined;
    try testing.expectEqual(@as(i32, 11), d2net_sc_reassign_player(rp.ptr, @intCast(rp.len), &rp_out));
    try testing.expectEqualDeep(D2NetReassignPlayer{
        .unit_type = 0,
        .guid = 0x14,
        .x = 284,
        .y = 180,
        .move_flag = 1,
    }, rp_out);

    const lm = (sc.PlayerLeave{ .stamina = 20000, .x = 260, .y = 180, .dx = -3, .dy = 4 }).encode(&enc);
    var lm_out: D2NetLocalMove = undefined;
    try testing.expectEqual(@as(i32, 9), d2net_sc_local_move(lm.ptr, @intCast(lm.len), &lm_out));
    // dx/dy widen to signed i32 across the boundary, they do not come back as 0xFD.
    try testing.expectEqualDeep(D2NetLocalMove{ .stamina = 20000, .x = 260, .y = 180, .dx = -3, .dy = 4 }, lm_out);
}

test "d2net_sc_remove_object / unit_hp_percent decode whole" {
    var enc: [8]u8 = undefined;
    const rm = (sc.RemoveObject{ .unit_type = 1, .guid = 0x1234 }).encode(&enc);
    var rm_out: D2NetRemoveObject = undefined;
    try testing.expectEqual(@as(i32, 6), d2net_sc_remove_object(rm.ptr, @intCast(rm.len), &rm_out));
    try testing.expectEqualDeep(D2NetRemoveObject{ .unit_type = 1, .guid = 0x1234 }, rm_out);

    const hp = (sc.UnitHpPercent{ .unit_type = 1, .guid = 0x1234, .hp_pct = 96 }).encode(&enc);
    var hp_out: D2NetUnitHpPercent = undefined;
    try testing.expectEqual(@as(i32, 7), d2net_sc_unit_hp_percent(hp.ptr, @intCast(hp.len), &hp_out));
    try testing.expectEqualDeep(D2NetUnitHpPercent{ .unit_type = 1, .guid = 0x1234, .hp_pct = 96 }, hp_out);
}

test "d2net_sc_chat reports both strings as spans of the caller's buffer" {
    var enc: [64]u8 = undefined;
    const wire = (sc.Chat{
        .msg_type = 1,
        .sub_type = 0,
        .unit_guid = 0x14,
        .color = 4,
        .name = "EpicSorc",
        .msg = "hi",
    }).encode(&enc);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x26, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x04,
        'E',  'p',  'i',  'c',  'S',  'o',  'r',  'c',  0x00,
        'h',  'i',  0x00,
    }, wire);

    var out: D2NetChat = undefined;
    try testing.expectEqual(@as(i32, 22), d2net_sc_chat(wire.ptr, @intCast(wire.len), &out));
    try testing.expectEqualDeep(D2NetChat{
        .msg_type = 1,
        .sub_type = 0,
        .unit_guid = 0x14,
        .color = 4,
        .name_offset = 10,
        .name_len = 8,
        .msg_offset = 19,
        .msg_len = 2,
    }, out);
    try testing.expectEqualStrings("EpicSorc", wire[10..18]);
    try testing.expectEqualStrings("hi", wire[19..21]);
}

test "d2net_sc_unit_pos covers every position-bearing opcode and rejects the rest" {
    var enc: [32]u8 = undefined;
    var out: D2NetUnitPos = undefined;

    const warp = (sc.AssignLevelWarp{ .unit_type = 0, .guid = 0x13, .x = 284, .y = 180 }).encode(&enc);
    try testing.expectEqual(@as(i32, 11), d2net_sc_unit_pos(warp.ptr, @intCast(warp.len), &out));
    try testing.expectEqualDeep(D2NetUnitPos{ .unit_type = 0, .guid = 0x13, .x = 284, .y = 180 }, out);

    const stop = (sc.PlayerStop{ .unit_type = 0, .guid = 0x14, .x = 260, .y = 180 }).encode(&enc);
    try testing.expectEqual(@as(i32, 13), d2net_sc_unit_pos(stop.ptr, @intCast(stop.len), &out));
    try testing.expectEqualDeep(D2NetUnitPos{ .unit_type = 0, .guid = 0x14, .x = 260, .y = 180 }, out);

    const move = (sc.PlayerMove{ .unit_type = 0, .guid = 0x14, .x = 265, .y = 185 }).encode(&enc);
    try testing.expectEqual(@as(i32, 16), d2net_sc_unit_pos(move.ptr, @intCast(move.len), &out));
    try testing.expectEqualDeep(D2NetUnitPos{ .unit_type = 0, .guid = 0x14, .x = 265, .y = 185 }, out);

    // 0x10 CharacterToObject shares the layout, so the same call reads it.
    var to_obj: [16]u8 = undefined;
    @memcpy(&to_obj, move);
    to_obj[0] = 0x10;
    try testing.expectEqual(@as(i32, 16), d2net_sc_unit_pos(&to_obj, to_obj.len, &out));
    try testing.expectEqualDeep(D2NetUnitPos{ .unit_type = 0, .guid = 0x14, .x = 265, .y = 185 }, out);

    const reassign = (sc.ReassignPlayer{ .unit_type = 0, .guid = 0x14, .x = 300, .y = 200 }).encode(&enc);
    try testing.expectEqual(@as(i32, 11), d2net_sc_unit_pos(reassign.ptr, @intCast(reassign.len), &out));
    try testing.expectEqualDeep(D2NetUnitPos{ .unit_type = 0, .guid = 0x14, .x = 300, .y = 200 }, out);

    const obj = (sc.CreateObject{ .unit_type = 2, .guid = 0x30, .class_id = 30, .x = 270, .y = 190 }).encode(&enc);
    try testing.expectEqual(@as(i32, 14), d2net_sc_unit_pos(obj.ptr, @intCast(obj.len), &out));
    try testing.expectEqualDeep(D2NetUnitPos{ .unit_type = 2, .guid = 0x30, .x = 270, .y = 190 }, out);

    var player = sc.CreatePlayer{ .guid = 0x14, .class_id = 1, .x = 260, .y = 180 };
    player.setName("EpicSorc");
    const pl = player.encode(&enc);
    try testing.expectEqual(@as(i32, 26), d2net_sc_unit_pos(pl.ptr, @intCast(pl.len), &out));
    // 0x59 has no unit-type byte: it is always a player (0).
    try testing.expectEqualDeep(D2NetUnitPos{ .unit_type = 0, .guid = 0x14, .x = 260, .y = 180 }, out);

    const mon = (sc.AssignMonster{ .guid = 0x40, .monster_class = 58, .x = 5000, .y = 5100 }).encode(&enc);
    try testing.expectEqual(@as(i32, 13), d2net_sc_unit_pos(mon.ptr, @intCast(mon.len), &out));
    // 0xAC has no unit-type byte either: it is always a monster (1).
    try testing.expectEqualDeep(D2NetUnitPos{ .unit_type = 1, .guid = 0x40, .x = 5000, .y = 5100 }, out);

    // An opcode with no unit position reports 0 and leaves `out` untouched.
    const before = out;
    try testing.expectEqual(@as(i32, 0), d2net_sc_unit_pos(&[_]u8{ 0x18, 0, 0 }, 3, &out));
    try testing.expectEqualDeep(before, out);
}

test "d2net_sc_packet_size: fixed, variable, incomplete, desync" {
    // Fixed from the table.
    const load_act = [_]u8{ 0x03, 0x00, 0xB7, 0x48, 0x82, 0x47, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try testing.expectEqual(@as(i32, 12), d2net_sc_packet_size(&load_act, load_act.len));
    // Same packet, one byte short of complete: 0 = feed more.
    try testing.expectEqual(@as(i32, 0), d2net_sc_packet_size(&load_act, 11));
    // Variable: 0xAC takes its total from pktLen@0x0C, 0x9C from pktLen@0x02.
    var enc: [32]u8 = undefined;
    const mon = (sc.AssignMonster{ .guid = 1, .body = &[_]u8{ 1, 2, 3, 4 } }).encode(&enc);
    try testing.expectEqual(@as(i32, 17), d2net_sc_packet_size(mon.ptr, @intCast(mon.len)));
    const item = (sc.ItemAction{ .action = 3, .guid = 1, .body = &[_]u8{ 1, 2 } }).encode(&enc);
    try testing.expectEqual(@as(i32, 10), d2net_sc_packet_size(item.ptr, @intCast(item.len)));
    // Variable: 0x26 scans two NUL-terminated strings (the engine's SSTR length walk).
    const chat = (sc.Chat{ .name = "EpicSorc", .msg = "hi" }).encode(&enc);
    try testing.expectEqual(@as(i32, 22), d2net_sc_packet_size(chat.ptr, @intCast(chat.len)));
    // Unknown / table-invalid opcodes are a desync, not "need more bytes".
    try testing.expectEqual(ERR_OPCODE, d2net_sc_packet_size(&[_]u8{0xFF}, 1));
    try testing.expectEqual(ERR_OPCODE, d2net_sc_packet_size(&[_]u8{0x30}, 1));
    // Bad arguments.
    try testing.expectEqual(ERR_ARGS, d2net_sc_packet_size(null, 4));
    try testing.expectEqual(ERR_ARGS, d2net_sc_packet_size(&load_act, -1));
}

test "d2net_sc_table_size mirrors the engine table, variable marked -1" {
    try testing.expectEqual(@as(i32, 12), d2net_sc_table_size(0x03));
    try testing.expectEqual(@as(i32, 26), d2net_sc_table_size(0x59));
    try testing.expectEqual(@as(i32, 11), d2net_sc_table_size(0x09));
    try testing.expectEqual(@as(i32, 15), d2net_sc_table_size(0x18));
    try testing.expectEqual(@as(i32, -1), d2net_sc_table_size(0x9C));
    try testing.expectEqual(@as(i32, -1), d2net_sc_table_size(0xAC));
    try testing.expectEqual(@as(i32, -1), d2net_sc_table_size(0x26));
    try testing.expectEqual(@as(i32, 0), d2net_sc_table_size(0x30));
    try testing.expectEqual(ERR_ARGS, d2net_sc_table_size(0xB5));
    try testing.expectEqual(ERR_ARGS, d2net_sc_table_size(-1));
}

test "d2net_sc_opcode_name / category, including truncation reporting" {
    var buf: [32]u8 = undefined;
    try testing.expectEqual(@as(i32, 7), d2net_sc_opcode_name(0x03, &buf, buf.len));
    try testing.expectEqualStrings("LoadAct", buf[0..7]);
    try testing.expectEqual(@as(u8, 0), buf[7]); // NUL-terminated when it fits
    try testing.expectEqual(@as(i32, 13), d2net_sc_opcode_name(0xAC, &buf, buf.len));
    try testing.expectEqualStrings("AssignMonster", buf[0..13]);
    // Truncation: the FULL length comes back even though only `cap` bytes were written.
    try testing.expectEqual(@as(i32, 13), d2net_sc_opcode_name(0xAC, &buf, 4));
    try testing.expectEqualStrings("Assi", buf[0..4]);
    try testing.expectEqual(@as(i32, 1), d2net_sc_opcode_name(0xEE, &buf, buf.len));
    try testing.expectEqualStrings("?", buf[0..1]);

    // Categories: sc.Cat ordinals (see D2NET_CAT_* in d2net.h).
    try testing.expectEqual(@as(i32, @intFromEnum(sc.Cat.level)), d2net_sc_opcode_category(0x03));
    try testing.expectEqual(@as(i32, @intFromEnum(sc.Cat.unit_add)), d2net_sc_opcode_category(0x59));
    try testing.expectEqual(@as(i32, @intFromEnum(sc.Cat.life)), d2net_sc_opcode_category(0x18));
    try testing.expectEqual(@as(i32, @intFromEnum(sc.Cat.item)), d2net_sc_opcode_category(0x9C));
    try testing.expectEqual(@as(i32, @intFromEnum(sc.Cat.unknown)), d2net_sc_opcode_category(0xEE));
    try testing.expectEqual(ERR_ARGS, d2net_sc_opcode_category(0x100));
}

// The header's value is the PACKET's length and excludes itself — `sc.frameInto` is the one
// definition of that and this shim only reshapes it, so these expectations follow sc.zig rather
// than restating the wire format independently. (This test previously asserted an inclusive
// header, which no build ever compiled and which `sc.frameInto` contradicts.)
test "framing: write then demux, both header widths" {
    const packet = [_]u8{ 0x03, 0x00, 0xB7, 0x48, 0x82, 0x47, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var out: [4096]u8 = undefined;
    try testing.expectEqual(@as(i32, 1), d2net_frame_header_len(packet.len));
    try testing.expectEqual(@as(i32, 13), d2net_frame_write(&out, out.len, &packet, packet.len));
    try testing.expectEqualSlices(u8, &[_]u8{
        12, 0x03, 0x00, 0xB7, 0x48, 0x82, 0x47, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
    }, out[0..13]);

    var off: i32 = -1;
    var plen: i32 = -1;
    try testing.expectEqual(@as(i32, 13), d2net_frame_next(&out, 13, &off, &plen));
    try testing.expectEqual(@as(i32, 1), off);
    try testing.expectEqual(@as(i32, 12), plen);
    try testing.expectEqualSlices(u8, &packet, out[1..13]);

    // A packet big enough for the two-byte header: total = len + 2, hi nibble tagged 0xF0.
    var big: [0x123]u8 = undefined;
    @memset(&big, 0x5A);
    big[0] = 0xAC;
    try testing.expectEqual(@as(i32, 2), d2net_frame_header_len(big.len));
    try testing.expectEqual(@as(i32, 0x125), d2net_frame_write(&out, out.len, &big, big.len));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF1, 0x23 }, out[0..2]);
    try testing.expectEqual(@as(i32, 0x125), d2net_frame_next(&out, 0x125, &off, &plen));
    try testing.expectEqual(@as(i32, 2), off);
    try testing.expectEqual(@as(i32, 0x123), plen);

    // Partial frames report 0 (need more bytes), not an error.
    try testing.expectEqual(@as(i32, 0), d2net_frame_next(&out, 0x124, &off, &plen));
    try testing.expectEqual(@as(i32, 0), d2net_frame_next(&[_]u8{0xF1}, 1, &off, &plen));
    // A frame too big for the output buffer is refused rather than truncated.
    try testing.expectEqual(ERR_SHORT, d2net_frame_write(&out, 12, &packet, packet.len));
    try testing.expectEqual(ERR_ARGS, d2net_frame_write(null, 32, &packet, packet.len));
}

test "decoders reject a short buffer and a foreign opcode, and null arguments" {
    const load_act = [_]u8{ 0x03, 0x00, 0xB7, 0x48, 0x82, 0x47, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var out: D2NetLoadAct = undefined;
    try testing.expectEqual(ERR_SHORT, d2net_sc_load_act(&load_act, 11, &out));
    try testing.expectEqual(ERR_ARGS, d2net_sc_load_act(&load_act, -1, &out));
    try testing.expectEqual(ERR_ARGS, d2net_sc_load_act(null, 12, &out));
    try testing.expectEqual(ERR_ARGS, d2net_sc_load_act(&load_act, 12, null));

    var wrong = load_act;
    wrong[0] = 0x59;
    try testing.expectEqual(ERR_OPCODE, d2net_sc_load_act(&wrong, wrong.len, &out));

    var life_out: D2NetLife = undefined;
    try testing.expectEqual(ERR_OPCODE, d2net_sc_life(&[_]u8{0x03} ++ [_]u8{0} ** 14, 15, &life_out));

    // Length is checked before the opcode, so a foreign packet SHORTER than the header reports
    // ERR_SHORT; one long enough to hold the header reports ERR_OPCODE.
    var mon_out: D2NetAssignMonster = undefined;
    try testing.expectEqual(ERR_SHORT, d2net_sc_assign_monster(&load_act, load_act.len, &mon_out));
    const long_foreign = [_]u8{0x03} ++ [_]u8{0} ** 15;
    try testing.expectEqual(ERR_OPCODE, d2net_sc_assign_monster(&long_foreign, long_foreign.len, &mon_out));
    var pos_out: D2NetUnitPos = undefined;
    try testing.expectEqual(ERR_SHORT, d2net_sc_unit_pos(&load_act, 0, &pos_out));
}

test "d2net_abi_version" {
    try testing.expectEqual(@as(u32, 1), d2net_abi_version());
}

test "one flush walks end to end: frame demux, sizing, decode" {
    // The join burst as a client sees it: three packets, each in its own length-prefixed frame.
    var concat: [128]u8 = undefined;
    var pw = lib.sc.PacketWriter.init(&concat);
    pw.add(sc.LoadAct{ .act = 0, .map_seed = 0x478248B7, .area = 1 });
    var player = sc.CreatePlayer{ .guid = 0x14, .class_id = 1, .x = 260, .y = 180 };
    player.setName("EpicSorc");
    pw.add(player);
    pw.add(sc.AssignLevelWarp{ .unit_type = 0, .guid = 0x13, .x = 284, .y = 180 });

    var stream: [256]u8 = undefined;
    const framed = sc.frameFlush(&stream, pw.bytes());
    try testing.expectEqual(@as(usize, (1 + 12) + (1 + 26) + (1 + 11)), framed.len);

    var cursor: usize = 0;
    var seen: [3]i32 = undefined;
    var n: usize = 0;
    while (cursor < framed.len) {
        var off: i32 = 0;
        var plen: i32 = 0;
        const total = d2net_frame_next(framed.ptr + cursor, @intCast(framed.len - cursor), &off, &plen);
        try testing.expect(total > 0);
        const pkt = framed.ptr + cursor + @as(usize, @intCast(off));
        // The frame length and the opcode table agree on where the packet ends.
        try testing.expectEqual(plen, d2net_sc_packet_size(pkt, plen));
        seen[n] = pkt[0];
        n += 1;
        cursor += @intCast(total);
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(i32, &[_]i32{ 0x03, 0x59, 0x09 }, &seen);

    // And the three decode to the captured values.
    var act_out: D2NetLoadAct = undefined;
    try testing.expectEqual(@as(i32, 12), d2net_sc_load_act(framed.ptr + 1, 12, &act_out));
    try testing.expectEqualDeep(D2NetLoadAct{ .act = 0, .map_seed = 0x478248B7, .area = 1, .automap = 0 }, act_out);
    var player_out: D2NetCreatePlayer = undefined;
    try testing.expectEqual(@as(i32, 26), d2net_sc_create_player(framed.ptr + 14, 26, &player_out));
    try testing.expectEqualDeep(D2NetCreatePlayer{
        .guid = 0x14,
        .class_id = 1,
        .x = 260,
        .y = 180,
        .name = [_]u8{ 'E', 'p', 'i', 'c', 'S', 'o', 'r', 'c', 0, 0, 0, 0, 0, 0, 0, 0 },
    }, player_out);
    var warp_out: D2NetAssignLevelWarp = undefined;
    try testing.expectEqual(@as(i32, 11), d2net_sc_assign_level_warp(framed.ptr + 41, 11, &warp_out));
    try testing.expectEqualDeep(D2NetAssignLevelWarp{
        .unit_type = 0,
        .guid = 0x13,
        .class_id = 0,
        .x = 284,
        .y = 180,
    }, warp_out);
}
