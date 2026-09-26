#pragma once
/*
 * d2util - C ABI for the d2-util package of libd2.
 * ABI version 1. See d2util_abi_version().
 *
 * Three things: MMPX magnification of palette indices (d2_upscale_indices), the frame key that
 * recognises an index image whatever margin it sits in (d2_frame_key), and lookup in an HD pack of
 * replacement images filed under those keys (d2_hdpack_info2, d2_hdpack_find, d2_hdpack_inflate).
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
#include <stddef.h>
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
    D2UTIL_ERR_SCALE = -2,
    /* Not an HD pack, an unsupported version, or a damaged one. */
    D2UTIL_ERR_PACK  = -3,
    /* An HD pack entry's stored bytes are not a sound zlib stream: a bad header, damaged deflate
       data, a wrong Adler-32, or bytes after the end. */
    D2UTIL_ERR_DATA  = -4,
    /* An HD pack entry decodes to more or fewer bytes than the output buffer holds. */
    D2UTIL_ERR_SIZE  = -5
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

/*
 * FRAME KEY
 *
 * The key of a w x h index image, pitch bytes per row, TOP ROW FIRST: FNV-1a 64 over the bounding
 * box of its non-zero indices - the box width and height as u16 little-endian, then the box's
 * indices row by row from the top. The same art has the same key whatever transparent margin
 * surrounds it. Writes the key to *key_out (0 when every index is 0) and the box to box_out as
 * x0, y0, width, height (all 0 then). w == 0 or h == 0 gives key 0.
 * Returns 0 or D2UTIL_ERR_ARGS (null output, negative size, pitch < w, a box side above 65535).
 */
int32_t d2_frame_key(const uint8_t *src, int32_t w, int32_t h, int32_t pitch,
                     uint64_t *key_out, int32_t box_out[4]);

/*
 * HD PACK
 *
 * A file of replacement images for sprite frames. All integers little-endian. Version 2:
 *
 *   "D2HD", u32 version (2), u32 scale, u32 count                      16 bytes
 *   count x { u64 key, u16 bw, u16 bh, u32 offset, u32 length }       20 bytes each
 *   image data
 *
 * Version 1, the original raw form:
 *
 *   "D2HD", u32 version (1), u32 scale, u32 count                      16 bytes
 *   count x { u64 key, u16 bw, u16 bh, u32 offset }                   16 bytes each
 *   image data
 *
 * The table is sorted by (key, bw, bh), with no repeats. bw x bh is the frame's box at 1x (see
 * d2_frame_key); its image is bw*scale x bh*scale indices of the same palette, top row first.
 * offset counts from the start of the file.
 *
 * Version 1 stores every image raw: bw*scale * bh*scale bytes at offset.
 *
 * Version 2 stores `length` bytes at offset, in one of two forms, told apart by the length alone:
 *   length == bw*scale * bh*scale   the image itself, raw (written when zlib would not shrink it);
 *   any other length                a zlib stream (RFC 1950: 2-byte header, deflate, big-endian
 *                                   Adler-32) that inflates to exactly bw*scale * bh*scale bytes.
 * d2_hdpack_inflate applies that rule, so a reader may call it on every entry. Entries with
 * identical images may share one stored copy (the same offset and length). Offsets are 32-bit, so
 * a pack is at most 4 GiB - 1 bytes.
 *
 * A reader that keeps only the table in memory reads the 16-byte header and count x 20 bytes of
 * table itself, then for a hit reads `length` bytes at `offset` and passes them to
 * d2_hdpack_inflate. A reader holding the whole pack uses d2_hdpack_info2 once and d2_hdpack_find.
 */

/*
 * Checks a whole HD pack of either version (header, table order, every entry inside the file;
 * linear in its entries: call it once, when the pack is loaded) and reports its version (1 or 2),
 * scale and entry count. Any output may be NULL. It does not inflate the entries.
 * Returns 0, D2UTIL_ERR_ARGS or D2UTIL_ERR_PACK.
 */
int32_t d2_hdpack_info2(const uint8_t *pack, size_t len, uint32_t *version_out,
                        uint32_t *scale_out, uint32_t *count_out);

/* As d2_hdpack_info2 without the version. */
int32_t d2_hdpack_info(const uint8_t *pack, size_t len, uint32_t *scale_out, uint32_t *count_out);

/*
 * The entry filed under (key, bw, bh) in a pack of either version: a binary search. On a hit
 * stores a pointer into `pack` in *stored and the stored byte count in *stored_len and returns the
 * pack's scale; pass them to d2_hdpack_inflate with a bw*scale * bh*scale buffer. Otherwise
 * returns 0 and stores NULL and 0. bw and bh must match as well as the key, which guards against
 * two frames whose keys collide. Never reads outside the pack, even a damaged one. Either output
 * may be NULL.
 */
int32_t d2_hdpack_find(const uint8_t *pack, size_t len, uint64_t key, uint16_t bw, uint16_t bh,
                       const uint8_t **stored, size_t *stored_len);

/*
 * Decodes one entry's stored bytes into `out`, which must be exactly the image's size,
 * bw*scale * bh*scale bytes. When stored_len == out_len the entry is raw and is copied; otherwise
 * it is inflated, with the zlib header, the Adler-32, the size and the end of the stream all
 * checked. Needs only the entry's bytes, not the pack. Allocates nothing; uses a few KiB of stack.
 * `out` must not overlap `stored`.
 * Returns 0, D2UTIL_ERR_ARGS (a NULL pointer with a non-zero length), D2UTIL_ERR_DATA or
 * D2UTIL_ERR_SIZE. After an error the contents of `out` are unspecified.
 */
int32_t d2_hdpack_inflate(const uint8_t *stored, size_t stored_len, uint8_t *out, size_t out_len);

/*
 * The image filed under (key, bw, bh) as a pointer into `pack`: on a hit stores it in *pixels
 * (bw*scale x bh*scale indices, top row first) and returns the pack's scale; otherwise returns 0
 * and stores NULL. Every entry of a version 1 pack; in a version 2 pack only an entry stored raw,
 * since a compressed one has no image in the file to point at (use d2_hdpack_find). Never reads
 * outside the pack, even a damaged one. pixels may be NULL.
 */
int32_t d2_hdpack_lookup(const uint8_t *pack, size_t len, uint64_t key, uint16_t bw, uint16_t bh,
                         const uint8_t **pixels);

#ifdef __cplusplus
}
#endif
