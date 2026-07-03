#pragma once
/*
 * d2drlg — C ABI for the faithful D2 1.14d map-generation (DRLG) engine.
 * ABI version 3. See d2drlg_abi_version().
 *
 * Generates an entire act's room layout (byte-exact seeds/placement where ported)
 * and, optionally, a composited subtile-collision grid per level.
 */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque context: the loaded game tables, built once. */
typedef struct D2DrlgCtx D2DrlgCtx;

/* Opaque generated-act handle (rooms of every level in the act). */
typedef struct D2DrlgAct D2DrlgAct;

/* One generated room's world rectangle + type. Mirrors the Zig lib.RoomRect. */
typedef struct D2DrlgRoom {
    int32_t x;
    int32_t y;
    int32_t w;
    int32_t h;
    int32_t n_type;         /* RoomEx.nType */
    int32_t n_preset_type;  /* RoomEx.nPresetType */
    int32_t picked_file;    /* preset nPickedFile / outdoor nSubThemePicked; -1 if neither */
} D2DrlgRoom;

/* Loads the game tables. Returns NULL on failure. */
D2DrlgCtx *d2drlg_ctx_create(void);

/* Frees a context (NULL-safe). */
void d2drlg_ctx_destroy(D2DrlgCtx *ctx);

/*
 * Generate an entire act. difficulty: 0=normal 1=nightmare 2=hell. act_no is
 * 0-based (Act I = 0 … Act V = 4). Returns an opaque act handle (free with
 * d2drlg_act_free) or NULL on error.
 */
D2DrlgAct *d2drlg_gen_act(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty, int32_t act_no);

/* Frees a generated-act handle (NULL-safe). */
void d2drlg_act_free(D2DrlgAct *act);

/* Number of levels in the act, or -1 on error. */
int32_t d2drlg_act_level_count(D2DrlgAct *act);

/* Levels.txt id of the level at level_index, or -1 if out of range. */
int32_t d2drlg_act_level_id(D2DrlgAct *act, int32_t level_index);

/* DrlgType of the level (1 maze, 2 preset, 3 wilderness), or -1 if out of range. */
int32_t d2drlg_act_level_drlg_type(D2DrlgAct *act, int32_t level_index);

/* 1 if placed by the act placement graph (surface), 0 if interior, -1 out of range. */
int32_t d2drlg_act_level_placed(D2DrlgAct *act, int32_t level_index);

/* Room count of the level at level_index, or -1 if out of range. */
int32_t d2drlg_act_level_room_count(D2DrlgAct *act, int32_t level_index);

/*
 * Writes up to `cap` rooms of the level at level_index into `out`; returns the
 * FULL room count (>=0, may exceed `cap` => truncated) or a negative error code.
 */
int32_t d2drlg_act_rooms(D2DrlgAct *act, int32_t level_index, D2DrlgRoom *out, int32_t cap);

/*
 * The level's generated world ORIGIN / SIZE in TILES (multiply by 5 for the subtile
 * frame DBM reports). Write the pair and return 0, or a negative error (outputs 0).
 */
int32_t d2drlg_act_level_origin(D2DrlgAct *act, int32_t level_index, int32_t *ox, int32_t *oy);
int32_t d2drlg_act_level_size(D2DrlgAct *act, int32_t level_index, int32_t *w, int32_t *h);

/*
 * Write a level's Levels.txt LevelName (in-game display name) into `buf`, NUL-terminated
 * if it fits. Returns the byte length (>=0; may exceed `cap` => truncated), or negative on
 * error. Length 0 for an unknown id.
 */
int32_t d2drlg_level_name(D2DrlgCtx *ctx, int32_t level_id, char *buf, int32_t cap);

/*
 * Generate a level's composited subtile-collision grid (one byte per subtile:
 * 0x00 open, 0x02 los-block, 0x01 blocked-terrain, 0x80 void). Writes up to `cap`
 * bytes into `out` and always sets *out_w / *out_h to the FULL grid dims. Returns
 * the FULL cell count (w*h, may exceed `cap` => truncated), 0 if the level has no
 * collision grid, or a negative error code. NOTE: regenerates the whole act
 * internally, so it is not cheap.
 */
int32_t d2drlg_level_collision(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty,
                               int32_t level_id, uint8_t *out, int32_t cap,
                               int32_t *out_w, int32_t *out_h);

/*
 * Generate a level's RAW subtile CollMap grid: one LITTLE-ENDIAN uint16 per subtile,
 * row-major from the level-local top-left (the DeadlyBossMods frame). Each cell is the
 * exact engine Colbit flag set (0x01 wall, 0x02 visible, 0x04 missile_barrier, 0x08
 * noplayer, 0x10 preset, 0x20 no_floor, ...); uncovered/OOB cells are 0xFFFF. Grid dims
 * equal the level WorldSize*5 (Cold Plains 400x400). Writes up to `cap` uint16 cells into
 * `out` and always sets *out_w / *out_h to the FULL grid dims. Returns the FULL cell count
 * (w*h, may exceed `cap` => truncated), 0 if the level has no collision grid, or a negative
 * error code. NOTE: regenerates the whole act internally, so it is not cheap.
 */
int32_t d2drlg_level_collision_raw(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty,
                                   int32_t level_id, uint16_t *out, int32_t cap,
                                   int32_t *out_w, int32_t *out_h);

/*
 * One outdoor shrine/well: resolved objects.txt class id + world SUBTILE position.
 * x/y are subtile coords (divide by 5 for tile coords).
 */
typedef struct D2DrlgShrine {
    int32_t class_id;  /* 130=Well, 84/2/81/83=Shrine variants */
    int32_t x;         /* world subtile X (/5 for tile) */
    int32_t y;         /* world subtile Y (/5 for tile) */
} D2DrlgShrine;

/*
 * Generate an act and write up to `cap` of a level's seeded OUTDOOR SHRINES/WELLS
 * into `out`. difficulty: 0=normal 1=nightmare 2=hell. Returns the FULL shrine count
 * (>=0, may exceed `cap` => truncated), 0 if the level has none, or a negative error
 * code. x/y are world subtile coords (divide by 5 for tiles). NOTE: regenerates the
 * whole act internally, so it is not cheap.
 */
int32_t d2drlg_level_shrines(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty,
                             int32_t level_id, D2DrlgShrine *out, int32_t cap);

/*
 * One preset unit (DBM shape). etype: 1 npc (MonStats id), 2 obj (Objects.txt row),
 * 5 exit (warp id). x/y are level-LOCAL subtile coords (subtract nothing — already the
 * DBM frame). Mirrors the Zig lib.PresetUnit.
 */
typedef struct D2DrlgPreset {
    int32_t etype;        /* 1 npc, 2 obj, 5 exit */
    int32_t txt_file_no;  /* MonStats id / Objects.txt row / warp id */
    int32_t x;            /* level-local subtile X */
    int32_t y;            /* level-local subtile Y */
} D2DrlgPreset;

/*
 * Generate an act and write up to `cap` of a level's PRESET UNITS (npc/obj/exit,
 * deduped, level-local subtile coords) into `out`. Returns the FULL count (>=0, may
 * exceed `cap` => truncated), or a negative error code. NOTE: regenerates the whole
 * act internally, so it is not cheap.
 */
int32_t d2drlg_level_presets(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty,
                             int32_t level_id, D2DrlgPreset *out, int32_t cap);

/*
 * One adjacency bridge tile (DBM shape). `dest_level_id` is the Levels.txt id the warp
 * leads to; `bridge_x`/`bridge_y` are level-LOCAL subtile coords (the DBM frame — the
 * room-centre of the warp-flagged room). Mirrors the Zig lib.LevelAdjacent.
 */
typedef struct D2DrlgAdjacent {
    int32_t dest_level_id;
    int32_t bridge_x;
    int32_t bridge_y;
} D2DrlgAdjacent;

/*
 * Generate an act and write up to `cap` of a level's WARP/ADJACENCY BRIDGE TILES (one
 * per set warp slot of every warp-flagged room whose destination resolves) into `out`.
 * Bridge coords are level-LOCAL subtiles (the DBM frame). Returns the FULL count (>=0,
 * may exceed `cap` => truncated), or a negative error code. NOTE: regenerates the whole
 * act internally, so it is not cheap.
 */
int32_t d2drlg_level_adjacents(D2DrlgCtx *ctx, uint32_t seed, int32_t difficulty,
                               int32_t level_id, D2DrlgAdjacent *out, int32_t cap);

/*
 * GENERATE-ONCE act-handle accessors. These read a level's presets / adjacents / raw
 * CollMap straight from an already-generated D2DrlgAct handle (from d2drlg_gen_act) —
 * NO regeneration — so assembling a whole DBM map costs ONE act generation instead of
 * re-generating the act for each level. Semantics/shape match the seed-based
 * d2drlg_level_presets / d2drlg_level_adjacents / d2drlg_level_collision_raw, but keyed
 * by 0-based act `level_index` (as d2drlg_act_rooms) rather than a Levels.txt id.
 */
int32_t d2drlg_act_level_presets(D2DrlgAct *act, int32_t level_index, D2DrlgPreset *out, int32_t cap);
int32_t d2drlg_act_level_adjacents(D2DrlgAct *act, int32_t level_index, D2DrlgAdjacent *out, int32_t cap);
int32_t d2drlg_act_level_collision(D2DrlgAct *act, int32_t level_index, uint16_t *out, int32_t cap,
                                   int32_t *out_w, int32_t *out_h);

/*
 * Like d2drlg_act_level_collision, but ZLIB-DEFLATES (rfc1950) the little-endian u16 RAW
 * CollMap and writes the compressed bytes to `out`. Always sets *out_w/*out_h to the full
 * grid dims. Returns the FULL deflated byte length (>=0, may exceed `cap` => grow+retry),
 * 0 if the level has no collision grid, or a negative error code. The INFLATED grid is
 * byte-for-byte identical to d2drlg_act_level_collision, letting hosts deflate map collision
 * entirely in-wasm (no host zlib) and inflate with any standard zlib.
 */
int32_t d2drlg_act_level_collision_zlib(D2DrlgAct *act, int32_t level_index, uint8_t *out, int32_t cap,
                                        int32_t *out_w, int32_t *out_h);

/*
 * Writes up to `cap` bytes of the level-at-`level_index` WALK grid into `out`: one byte per
 * subtile (0 = blocked, 1 = walkable), row-major, SAME dims/origin as the RAW CollMap. Derived
 * during generation from the raw CollMap via the d2bs LevelMap mask (walkable = not
 * BlockWalk(0x01)|BlockPlayer(0x08)|Object(0x400) and not OOB 0xFFFF). Always sets *w/*h to the
 * full grid dims. Returns the FULL cell count (w*h, >=0, may exceed `cap`), 0 if the level has
 * no collision grid, or a negative error code. Path-ready: A* on these bytes directly.
 */
int32_t d2drlg_act_level_walk(D2DrlgAct *act, int32_t level_index, uint8_t *out, int32_t cap,
                              int32_t *w, int32_t *h);

/*
 * zlib-DEFLATE (rfc1950) an arbitrary caller byte buffer. Reads `in_len` bytes from `in`,
 * writes up to `cap` compressed bytes to `out`, returns the FULL deflated byte length
 * (>=0, may exceed `cap` => grow+retry) or a negative error code. Lets a host deflate any
 * buffer entirely in-wasm (no host zlib).
 */
int32_t d2drlg_deflate_zlib(const uint8_t *in, int32_t in_len, uint8_t *out, int32_t cap);

/*
 * Write an object row's Objects.txt "Name" (d2drlg_object_name) or description
 * (d2drlg_object_desc, column "description - not loaded") into `buf`, NUL-terminated if
 * it fits. Returns the string's byte length (>=0; may exceed `cap` => truncated), or a
 * negative error. `txt_file_no` is a preset obj's txtFileNo (0-based Objects.txt row);
 * length 0 if out of range.
 */
int32_t d2drlg_object_name(int32_t txt_file_no, char *buf, int32_t cap);
int32_t d2drlg_object_desc(int32_t txt_file_no, char *buf, int32_t cap);

/* Returns the ABI version (currently 3). */
uint32_t d2drlg_abi_version(void);

#ifdef __cplusplus
}
#endif
