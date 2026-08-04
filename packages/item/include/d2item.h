#pragma once
/*
 * d2item — C ABI for the faithful D2 1.14d seed-driven item-drop generator.
 * ABI version 2. See d2item_abi_version().
 */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque context: the loaded tables + treasure sets. */
typedef struct D2ItemCtx D2ItemCtx;

/* A single rolled drop. Mirrors the Zig model.Drop, flattened. */
typedef struct D2ItemDrop {
    uint8_t  kind;              /* DropKind: none=0 gold=1 item=2 quiver=3 bodypart=4 */
    uint8_t  item_code[4];      /* base item code (kind==item); NOT NUL-terminated if 4 chars */
    uint8_t  quality;           /* Quality: invalid=0 low=1 normal=2 superior=3 magic=4 set=5 rare=6 unique=7 crafted=8 tempered=9 */
    uint16_t prefix_id;
    uint16_t suffix_id;
    uint16_t rare_prefix_ids[3];
    uint16_t rare_suffix_ids[3];
    uint16_t rare_prefix_name;  /* RarePrefix.txt row (1-based) — the item's NAME, not a mod */
    uint16_t rare_suffix_name;  /* RareSuffix.txt row (1-based) */
    uint16_t unique_id;         /* UniqueItems.txt row (1-based) */
    uint16_t set_id;            /* SetItems.txt row (1-based) */
    uint16_t quality_id;        /* QualityItems.txt row (1-based), superior only */
    uint16_t low_quality_id;    /* LowQualityItems.txt row (1-based), low quality only */
    uint16_t auto_prefix_id;    /* MagicPrefix.txt row (1-based) of the base's automagic affix */
    uint8_t  sockets;
    uint8_t  ethereal;
    int32_t  quantity;          /* gold amount / stack size */
    int32_t  item_level;
    uint32_t item_seed;         /* low word of the item's mod seed — replays its property rolls */
} D2ItemDrop;

/* Loads tables + treasure sets. Returns NULL on failure. */
D2ItemCtx *d2item_create(void);

/* Frees a context (NULL-safe). */
void d2item_destroy(D2ItemCtx *ctx);

/*
 * Rolls a drop for (seed, tc_name, mlvl, mf). Writes up to `cap` drops into
 * `out`; returns the FULL number produced (>=0, may exceed `cap` => truncated)
 * or a negative error code. `tc_name` is a NUL-terminated C string.
 */
int32_t d2item_roll(D2ItemCtx *ctx, uint32_t seed, const char *tc_name,
                     int32_t mlvl, int32_t mf, D2ItemDrop *out, int32_t cap);

/* Returns the ABI version (currently 2). */
uint32_t d2item_abi_version(void);

#ifdef __cplusplus
}
#endif
