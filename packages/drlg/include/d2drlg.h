#pragma once
/*
 * d2drlg — C ABI for the faithful D2 1.14d map-generation (DRLG) engine.
 * ABI version 1. See d2drlg_abi_version().
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

/* Returns the ABI version (currently 1). */
uint32_t d2drlg_abi_version(void);

#ifdef __cplusplus
}
#endif
