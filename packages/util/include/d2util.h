#pragma once
/*
 * d2util - C ABI for the d2-util package of libd2.
 * ABI version 1. See d2util_abi_version().
 *
 * MMPX pixel-art magnification (McGuire & Gagiu, JCGT 10(2), 2021) run on 8-bit PALETTE
 * INDICES rather than colours. MMPX never blends: every output pixel is a copy of an input pixel,
 * so the output holds only indices the input holds (with D2UTIL_EDGE_ZERO, index 0 may also be
 * copied in at the image border).
 *
 * STATELESS. Nothing is allocated and nothing needs freeing; there is no context and no libc
 * dependency. Every function is a pure, deterministic function over memory the caller owns, and
 * safe to call from any number of threads at once.
 *
 * SEMANTICS
 *   - Two pixels are equal when their indices are equal.
 *   - The brightness tie-breakers rank index i at r+g+b+1 of palette entry i. Channel order does
 *     not matter to that sum, so D2's pal.dat (B,G,R triples) can be passed as-is. With no
 *     palette, indices rank by value.
 *   - Index 0 is transparent unless D2UTIL_INDEX0_OPAQUE is set. With a palette it ranks as the
 *     reference ranks a transparent pixel, (r+g+b+1)*256 of entry 0 (256 for D2's black entry:
 *     above dark colours, below bright ones). With no palette it ranks above every other index.
 *   - Outside the image reads the nearest edge pixel (right for tiled UI panels), or index 0 with
 *     D2UTIL_EDGE_ZERO (right for sprites whose surroundings are transparent).
 *   - scale 1 copies, 2 is MMPX, 4 is MMPX applied twice, 3 is the 4x image sampled at 3x pixel
 *     centres; where a centre falls exactly between 4x pixels, the most frequent of them wins, a
 *     tie going to the source pixel if it is among the tied, else to the lowest index.
 */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Error codes. Functions return 0 on success or one of these. */
enum {
    /* A null pointer, a negative or oversized dimension, a pitch smaller than its row, or an
       unknown flag. */
    D2UTIL_ERR_ARGS  = -1,
    /* scale is not 1, 2, 3 or 4. */
    D2UTIL_ERR_SCALE = -2
};

/* Flags for d2_upscale_indices_ex. */
enum {
    /* Read index 0 outside the image instead of repeating the edge pixel. */
    D2UTIL_EDGE_ZERO     = 1 << 0,
    /* Rank index 0 as an ordinary opaque colour instead of as transparent. */
    D2UTIL_INDEX0_OPAQUE = 1 << 1
};

/* The ABI version this library implements (1). Compare it against the version above. */
int32_t d2util_abi_version(void);

/*
 * Magnify w x h palette indices by `scale` (1, 2, 3 or 4).
 *   src          h rows of src_pitch bytes (src_pitch >= w).
 *   palette_rgb  NULL, or 768 bytes: 256 colour triples, used only for brightness.
 *   dst          receives h*scale rows of w*scale indices at dst_pitch (dst_pitch >= w*scale).
 *                It must hold (h*scale - 1)*dst_pitch + w*scale bytes; that is the caller's
 *                contract, the library cannot check it. dst must not overlap src.
 * Edges clamp and index 0 is transparent. w == 0 or h == 0 is a no-op returning 0.
 * Returns 0, D2UTIL_ERR_ARGS or D2UTIL_ERR_SCALE.
 */
int32_t d2_upscale_indices(const uint8_t *src, int32_t w, int32_t h, int32_t src_pitch,
                           int32_t scale, const uint8_t *palette_rgb,
                           uint8_t *dst, int32_t dst_pitch);

/* As d2_upscale_indices, with `flags` a combination of D2UTIL_EDGE_ZERO and D2UTIL_INDEX0_OPAQUE. */
int32_t d2_upscale_indices_ex(const uint8_t *src, int32_t w, int32_t h, int32_t src_pitch,
                              int32_t scale, const uint8_t *palette_rgb,
                              uint8_t *dst, int32_t dst_pitch, int32_t flags);

#ifdef __cplusplus
}
#endif
