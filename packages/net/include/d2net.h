#pragma once
/*
 * d2net — C ABI for the D2GS server->client wire protocol (Diablo II 1.14d).
 * ABI version 1. See d2net_abi_version().
 *
 * Turns the byte stream a 1.14d game server sends into structs: demux the length-prefixed frames,
 * ask how long the packet in front of you is, then decode the packets a bot actually consumes.
 *
 * STATELESS. There is no context to create and nothing to free: every function is a pure function
 * over memory the caller owns. Variable-length bodies (item bitstreams, the 0xAC stat stream, chat
 * strings) are reported as an OFFSET AND LENGTH into the buffer you passed in — this library never
 * copies them and never hands back a pointer it owns.
 *
 * RETURN CONVENTION. Every decoder returns the WIRE SIZE it consumed (> 0) on success, so one call
 * both decodes and tells you how far to advance. 0 means "none / not present yet / not this
 * opcode" — the exact meaning is documented per function. A negative value is a D2NET_ERR_*.
 *
 * ORDER OF OPERATIONS on a live socket:
 *   1. Strip the raw 0xAF greeting (it is NOT length-prefixed).
 *   2. d2net_frame_next  -> one packet per frame.
 *   3. d2net_sc_packet_size on the packet, if you want to split a 0xAE container yourself.
 *   4. d2net_sc_* decoders, or d2net_sc_unit_pos for anything that just moves a unit.
 * NOTE the engine COMPRESSES each packet before framing it. Decompression is a separate layer;
 * this library sees packets, not compressed frames.
 *
 * COORDINATES. Every x/y here is a subtile in the level's own frame, matching what d2drlg reports.
 */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Error codes. Every function returns one of these, or a non-negative result. */
enum {
    /* A null pointer, or a negative length/capacity. */
    D2NET_ERR_ARGS   = -1,
    /* The buffer does not hold the whole packet, or the output buffer is too small. */
    D2NET_ERR_SHORT  = -2,
    /* The opcode is not the one this decoder reads, or is unknown to the size table (= desync). */
    D2NET_ERR_OPCODE = -3
};

/* Handler categories, as reported by d2net_sc_opcode_category. */
enum {
    D2NET_CAT_CONTROL     = 0,  /* load/unload/handshake/game-flags: session lifecycle */
    D2NET_CAT_LEVEL       = 1,  /* act/seed/map reveal: world identity */
    D2NET_CAT_UNIT_ADD    = 2,  /* a unit appears */
    D2NET_CAT_UNIT_REMOVE = 3,  /* a unit is removed */
    D2NET_CAT_MOVE        = 4,  /* a unit changes position */
    D2NET_CAT_LIFE        = 5,  /* hp/mana/stamina */
    D2NET_CAT_STAT        = 6,  /* stat set/add */
    D2NET_CAT_STATE       = 7,  /* buff/debuff state */
    D2NET_CAT_SKILL       = 8,  /* skill assign/cast/select */
    D2NET_CAT_ITEM        = 9,  /* item ground/inventory actions */
    D2NET_CAT_CHAT        = 10, /* overhead text / messages */
    D2NET_CAT_ROSTER      = 11, /* party/quest/waypoint UI state */
    D2NET_CAT_MISC        = 12, /* named but not modelled */
    D2NET_CAT_UNKNOWN     = 13  /* no dedicated handler */
};

/*
 * The wire size of the first S->C packet in `buf`, including the opcode byte, covering the
 * variable-length opcodes (0x16 0x26 0x3E 0x5B 0x94 0x9C 0x9D 0xA6 0xA8 0xAA 0xAC 0xAE 0xAF 0xB3)
 * whose size comes out of their own header fields.
 * Returns: > 0 the size; 0 the packet is not fully present yet (read more and retry);
 * D2NET_ERR_OPCODE if the opcode is unknown or table-invalid, which on a live stream means the
 * reader has desynced; D2NET_ERR_ARGS on bad arguments.
 */
int32_t d2net_sc_packet_size(const uint8_t *buf, int32_t len);

/*
 * The raw per-opcode table entry: > 0 a fixed wire size, 0 an invalid/stub opcode, -1 variable
 * (call d2net_sc_packet_size on the bytes). D2NET_ERR_ARGS outside 0x00..0xB4.
 */
int32_t d2net_sc_table_size(int32_t opcode);

/* The opcode's D2NET_CAT_*, or D2NET_ERR_ARGS outside 0x00..0xFF. */
int32_t d2net_sc_opcode_category(int32_t opcode);

/*
 * Write the opcode's short handler name ("LoadAct", "AssignMonster", "?" when unhandled) into
 * `buf`, NUL-terminated if it fits, and return its FULL length — which may exceed `cap`, meaning
 * the name was truncated.
 */
int32_t d2net_sc_opcode_name(int32_t opcode, uint8_t *buf, int32_t cap);

/* ---- length-prefix framing ------------------------------------------------------------------ */

/*
 * Bytes the length header of a `packet_len`-byte packet occupies (1 or 2). The header's value
 * counts ITSELF, so the one-byte form lasts only while packet_len + 1 < 0xF0.
 */
int32_t d2net_frame_header_len(int32_t packet_len);

/*
 * Demux ONE frame off the front of `buf`. Writes the packet's offset within `buf` to `out_offset`
 * and its length to `out_packet_len` (either may be NULL), and returns the TOTAL bytes the frame
 * consumed — header included — so you can advance your cursor by it.
 * Returns 0 when the frame is not fully present yet or its header is degenerate: read more bytes
 * and retry. D2NET_ERR_ARGS on bad arguments.
 */
int32_t d2net_frame_next(const uint8_t *buf, int32_t len, int32_t *out_offset, int32_t *out_packet_len);

/*
 * Frame one packet into `out`: its length header followed by its bytes. Returns the total written
 * (header + packet), D2NET_ERR_SHORT if `out_cap` cannot hold the frame, D2NET_ERR_ARGS otherwise.
 */
int32_t d2net_frame_write(uint8_t *out, int32_t out_cap, const uint8_t *packet, int32_t packet_len);

/* ---- decoders ------------------------------------------------------------------------------- */

/*
 * 0x03 LoadAct. `map_seed` is the DRLG seed of this game — hand it to d2drlg to reproduce the very
 * maps the server is running. `area` is the Levels.txt id the player lands in.
 */
typedef struct D2NetLoadAct {
    int32_t  act;
    uint32_t map_seed;
    int32_t  area;
    uint32_t automap;
} D2NetLoadAct;

/* Decode 0x03. Returns 12, or a negative error. */
int32_t d2net_sc_load_act(const uint8_t *buf, int32_t len, D2NetLoadAct *out);

/* 0x01 GameFlags: difficulty (0 normal, 1 nightmare, 2 hell) plus the expansion/ladder flags. */
typedef struct D2NetGameFlags {
    int32_t  difficulty;
    uint32_t arena;
    int32_t  expansion;
    int32_t  ladder;
} D2NetGameFlags;

/* Decode 0x01. Returns 8, or a negative error. */
int32_t d2net_sc_game_flags(const uint8_t *buf, int32_t len, D2NetGameFlags *out);

/*
 * 0x59 CreatePlayer. `name` is the 16-byte NUL-padded wire field verbatim, so the caller decides
 * how to make a string of it. `class_id` is the character class.
 */
typedef struct D2NetCreatePlayer {
    uint32_t guid;
    int32_t  class_id;
    int32_t  x;
    int32_t  y;
    uint8_t  name[16];
} D2NetCreatePlayer;

/* Decode 0x59. Returns 26, or a negative error. */
int32_t d2net_sc_create_player(const uint8_t *buf, int32_t len, D2NetCreatePlayer *out);

/*
 * 0xAC AssignMonster. `monster_class` is a SIGNED MonStats id (-1 = none); `hp_pct` is on the 128
 * scale (0x80 = full). `body_offset`/`body_len` span the trailing bit-packed flag/stat stream
 * inside the buffer you passed in — decoding that needs the game tables and lives above this layer.
 */
typedef struct D2NetAssignMonster {
    uint32_t guid;
    int32_t  monster_class;
    int32_t  x;
    int32_t  y;
    int32_t  hp_pct;
    int32_t  body_offset;
    int32_t  body_len;
} D2NetAssignMonster;

/* Decode 0xAC. Returns the packet's TOTAL wire size (13 + body), or a negative error. */
int32_t d2net_sc_assign_monster(const uint8_t *buf, int32_t len, D2NetAssignMonster *out);

/* 0x09 AssignLevelWarp: a clickable inter-level warp coming into view. */
typedef struct D2NetAssignLevelWarp {
    int32_t  unit_type;
    uint32_t guid;
    int32_t  class_id;
    int32_t  x;
    int32_t  y;
} D2NetAssignLevelWarp;

/* Decode 0x09. Returns 11, or a negative error. */
int32_t d2net_sc_assign_level_warp(const uint8_t *buf, int32_t len, D2NetAssignLevelWarp *out);

/*
 * 0x18 Life / 0x95 PlayerJoin: the LOCAL player's vitals and position. Bit-packed, and carrying no
 * GUID — it is always the receiving player. hp/mp/stamina are whole points. `hp_regen`/`mp_regen`
 * exist on 0x18 only and read 0 for 0x95.
 */
typedef struct D2NetLife {
    int32_t opcode;
    int32_t hp;
    int32_t mp;
    int32_t stamina;
    int32_t hp_regen;
    int32_t mp_regen;
    int32_t x;
    int32_t y;
} D2NetLife;

/* Decode 0x18 or 0x95. Returns 15 (0x18) or 13 (0x95), or a negative error. */
int32_t d2net_sc_life(const uint8_t *buf, int32_t len, D2NetLife *out);

/*
 * 0x9C Item. `action` is 0 add, 1 picked, 2 dropped, 3 on-ground, … `body_offset`/`body_len` span
 * the item's own bitstream inside your buffer; feed that to the item layer (d2item).
 */
typedef struct D2NetItem {
    int32_t  action;
    uint32_t guid;
    int32_t  body_offset;
    int32_t  body_len;
} D2NetItem;

/* Decode 0x9C. Returns the packet's TOTAL wire size (8 + body), or a negative error. */
int32_t d2net_sc_item(const uint8_t *buf, int32_t len, D2NetItem *out);

/*
 * 0x0F PlayerMove: a unit walking or running. `x`/`y` are the move DESTINATION, not the current
 * position; `skill_id`/`item_id` are the generic message params the engine passes through.
 */
typedef struct D2NetPlayerMove {
    int32_t  unit_type;
    uint32_t guid;
    int32_t  mode;
    int32_t  skill_id;
    int32_t  item_id;
    int32_t  target_type;
    int32_t  x;
    int32_t  y;
} D2NetPlayerMove;

/*
 * Decode 0x0F. Returns 16, or a negative error. 0x10 CharacterToObject has the identical layout;
 * read it with d2net_sc_unit_pos, which accepts both.
 */
int32_t d2net_sc_player_move(const uint8_t *buf, int32_t len, D2NetPlayerMove *out);

/*
 * 0x0D PlayerStop: a unit came to rest at x/y. `hp_pct` is a party-roster health update and is
 * only meaningful for players (unit_type 0).
 */
typedef struct D2NetPlayerStop {
    int32_t  unit_type;
    uint32_t guid;
    int32_t  mode;
    int32_t  x;
    int32_t  y;
    int32_t  target_type;
    int32_t  hp_pct;
} D2NetPlayerStop;

/* Decode 0x0D. Returns 13, or a negative error. */
int32_t d2net_sc_player_stop(const uint8_t *buf, int32_t len, D2NetPlayerStop *out);

/* 0x15 ReassignPlayer: a unit is snapped/teleported to x/y rather than pathed there. */
typedef struct D2NetReassignPlayer {
    int32_t  unit_type;
    uint32_t guid;
    int32_t  x;
    int32_t  y;
    int32_t  move_flag;
} D2NetReassignPlayer;

/* Decode 0x15. Returns 11, or a negative error. */
int32_t d2net_sc_reassign_player(const uint8_t *buf, int32_t len, D2NetReassignPlayer *out);

/*
 * 0x96. Despite the engine handler being named "PlayerLeave", this removes nobody: it is the LOCAL
 * player's stamina + position update, with dx/dy as SIGNED step deltas.
 */
typedef struct D2NetLocalMove {
    int32_t stamina;
    int32_t x;
    int32_t y;
    int32_t dx;
    int32_t dy;
} D2NetLocalMove;

/* Decode 0x96. Returns 9, or a negative error. */
int32_t d2net_sc_local_move(const uint8_t *buf, int32_t len, D2NetLocalMove *out);

/* 0x0A RemoveObject: a unit left view or died. */
typedef struct D2NetRemoveObject {
    int32_t  unit_type;
    uint32_t guid;
} D2NetRemoveObject;

/* Decode 0x0A. Returns 6, or a negative error. */
int32_t d2net_sc_remove_object(const uint8_t *buf, int32_t len, D2NetRemoveObject *out);

/* 0xAB UnitHpPercent: a unit's health-bar update, `hp_pct` on the 128 scale (0x80 = full). */
typedef struct D2NetUnitHpPercent {
    int32_t  unit_type;
    uint32_t guid;
    int32_t  hp_pct;
} D2NetUnitHpPercent;

/* Decode 0xAB. Returns 7, or a negative error. */
int32_t d2net_sc_unit_hp_percent(const uint8_t *buf, int32_t len, D2NetUnitHpPercent *out);

/*
 * 0x26 ChatMessage. Both strings are spans of the buffer you passed in; the lengths exclude the
 * NUL terminators, and nothing is copied.
 */
typedef struct D2NetChat {
    int32_t  msg_type;
    int32_t  sub_type;
    uint32_t unit_guid;
    int32_t  color;
    int32_t  name_offset;
    int32_t  name_len;
    int32_t  msg_offset;
    int32_t  msg_len;
} D2NetChat;

/* Decode 0x26. Returns the packet's TOTAL wire size, or a negative error. */
int32_t d2net_sc_chat(const uint8_t *buf, int32_t len, D2NetChat *out);

/* "Which unit is now where" — all a world model needs from any position-bearing packet. */
typedef struct D2NetUnitPos {
    int32_t  unit_type;
    uint32_t guid;
    int32_t  x;
    int32_t  y;
} D2NetUnitPos;

/*
 * Decode the unit type/GUID/position out of ANY position-bearing packet: 0x09, 0x0D, 0x0F, 0x10,
 * 0x15, 0x51, 0x59 and 0xAC — so a consumer need not know each opcode's byte layout. 0x59 and 0xAC
 * carry no unit-type byte, so `unit_type` is filled in as 0 (player) and 1 (monster).
 * Returns the packet's wire size (> 0); 0 if the opcode carries no unit position, in which case
 * `out` is left untouched; or a negative error.
 */
int32_t d2net_sc_unit_pos(const uint8_t *buf, int32_t len, D2NetUnitPos *out);

/* This library's ABI version. Bumped whenever a signature or struct layout above changes. */
uint32_t d2net_abi_version(void);

#ifdef __cplusplus
}
#endif
