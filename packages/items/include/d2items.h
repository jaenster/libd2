#pragma once
/*
 * d2items — C ABI for the faithful D2 1.14d seed-driven item-drop generator.
 * ABI version 1. See d2items_abi_version().
 */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque context: the loaded tables + treasure sets. */
typedef struct D2ItemsCtx D2ItemsCtx;

/* A single rolled drop. Mirrors the Zig model.Drop, flattened. */
typedef struct D2ItemsDrop {
    uint8_t  kind;              /* DropKind: none=0 gold=1 item=2 quiver=3 bodypart=4 */
    uint8_t  item_code[4];      /* base item code (kind==item); NOT NUL-terminated if 4 chars */
    uint8_t  quality;           /* Quality: invalid=0 low=1 normal=2 superior=3 magic=4 set=5 rare=6 unique=7 crafted=8 tempered=9 */
    uint16_t prefix_id;
    uint16_t suffix_id;
    uint16_t rare_prefix_ids[3];
    uint16_t rare_suffix_ids[3];
    uint8_t  sockets;
    int32_t  quantity;          /* gold amount / quiver count */
    int32_t  item_level;
} D2ItemsDrop;

/* Loads tables + treasure sets. Returns NULL on failure. */
D2ItemsCtx *d2items_create(void);

/* Frees a context (NULL-safe). */
void d2items_destroy(D2ItemsCtx *ctx);

/*
 * Rolls a drop for (seed, tc_name, mlvl, mf). Writes up to `cap` drops into
 * `out`; returns the FULL number produced (>=0, may exceed `cap` => truncated)
 * or a negative error code. `tc_name` is a NUL-terminated C string.
 */
int32_t d2items_roll(D2ItemsCtx *ctx, uint32_t seed, const char *tc_name,
                     int32_t mlvl, int32_t mf, D2ItemsDrop *out, int32_t cap);

/* Returns the ABI version (currently 1). */
uint32_t d2items_abi_version(void);

#ifdef __cplusplus
}
#endif
