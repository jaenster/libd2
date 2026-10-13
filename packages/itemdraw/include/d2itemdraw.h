/* d2itemdraw: a Diablo II 1.14d item drawn as the game draws it (libd2).
 *
 * The art is the caller's: add the game's MPQs (Patch_D2.mpq, d2exp.mpq, d2data.mpq, in that order)
 * or loose files. libd2 ships none of it. The text needs no art at all.
 *
 * Item input is the item's serialized records: the 1.14d save-form bitstream ("JM" record) of the
 * item, followed by the records of whatever is socketed into it, as in a .d2s item list.
 */
#ifndef D2ITEMDRAW_H
#define D2ITEMDRAW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define D2ITEMDRAW_ABI_VERSION 1

typedef struct D2ItemDrawCtx D2ItemDrawCtx;
typedef struct D2ItemDrawImage D2ItemDrawImage;

/* Who looks at the item. has_viewer == 0: the neutral character (every requirement met, no class,
 * per-level stats at `level`). 24 bytes. */
typedef struct D2ItemDrawOptions {
    int32_t has_viewer;
    int32_t class_id;   /* 0 Amazon, 1 Sorceress, 2 Necromancer, 3 Paladin, 4 Barbarian, 5 Druid, 6 Assassin */
    int32_t level;
    int32_t strength;
    int32_t dexterity;
    int32_t act;        /* palette act for pictures, 1..5 */
} D2ItemDrawOptions;

uint32_t d2itemdraw_abi_version(void);

/* Memory a host fills with archive or record bytes (needed by wasm hosts). */
uint8_t *d2itemdraw_alloc(size_t len);
void d2itemdraw_free(uint8_t *ptr, size_t len);

D2ItemDrawCtx *d2itemdraw_create(void);
void d2itemdraw_destroy(D2ItemDrawCtx *ctx);

/* An MPQ, searched after the ones added before it. Borrowed: keep it alive until destroy. 0 = ok. */
int32_t d2itemdraw_add_archive(D2ItemDrawCtx *ctx, const uint8_t *bytes, size_t len);
/* One file under its game path ("data/global/items/invamu1.dc6"), copied; wins over archives. */
int32_t d2itemdraw_add_file(D2ItemDrawCtx *ctx, const char *name, const uint8_t *bytes, size_t len);

/* The item's description. mode 0: the engine's string (UTF-8, first line at the BOTTOM, colour codes
 * "\xC3\xBF" "c" digit); 1: plain text top to bottom; 2: top to bottom, colour runs as "{N}text".
 * Writes at most cap bytes, returns the full length or a negative error. */
int32_t d2itemdraw_text(D2ItemDrawCtx *ctx, const uint8_t *records, size_t len,
                        const D2ItemDrawOptions *opts, int32_t mode, uint8_t *out, size_t cap);

/* Pictures; NULL when the records do not parse or the art is missing.
 * background: 0 none, 1 normal (blue), 2 hovered (green), 3 unusable (red), 4 unidentified.
 * sockets: non-zero draws the sockets and their fillers, as the game does for the hovered item. */
D2ItemDrawImage *d2itemdraw_icon(D2ItemDrawCtx *ctx, const uint8_t *records, size_t len,
                                 const D2ItemDrawOptions *opts, int32_t background, int32_t sockets);
D2ItemDrawImage *d2itemdraw_tooltip(D2ItemDrawCtx *ctx, const uint8_t *records, size_t len,
                                    const D2ItemDrawOptions *opts);
/* The item as on hover: cells tinted, icon and sockets, the tooltip centred above it. */
D2ItemDrawImage *d2itemdraw_card(D2ItemDrawCtx *ctx, const uint8_t *records, size_t len,
                                 const D2ItemDrawOptions *opts);

uint32_t d2itemdraw_image_width(const D2ItemDrawImage *img);
uint32_t d2itemdraw_image_height(const D2ItemDrawImage *img);
/* width*height*4 bytes, straight-alpha RGBA, rows top-down; valid until the image is freed. */
const uint8_t *d2itemdraw_image_rgba(const D2ItemDrawImage *img);
/* PNG bytes, encoded on first call; valid until the image is freed. */
const uint8_t *d2itemdraw_image_png(D2ItemDrawImage *img, size_t *out_len);
void d2itemdraw_image_free(D2ItemDrawImage *img);

#ifdef __cplusplus
}
#endif

#endif
