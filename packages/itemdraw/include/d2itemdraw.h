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

#define D2ITEMDRAW_ABI_VERSION 2

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

/* ---- the display list and pluggable drawing ----
 *
 * A layout says where 1.14d puts everything (box, lines as glyph cells, the icon and socket frames), in
 * the game's pixels, measured with the Font16 table. A rasterizer draws it at any scale through two
 * providers; a provider paints one zeroed RGBA tile (the glyph cell or sprite rectangle times the
 * scale) and returns non-zero, or returns 0 to leave it to libd2's own 1.14d DC6 art. */

typedef struct D2ItemDrawLayout D2ItemDrawLayout;

#define D2ITEMDRAW_KIND_ICON 0
#define D2ITEMDRAW_KIND_TOOLTIP 1
#define D2ITEMDRAW_KIND_CARD 2

typedef struct D2ItemDrawRect {
    int32_t x, y, w, h;
} D2ItemDrawRect;

typedef struct D2ItemDrawGlyphRef {
    const char *font;    /* "font16" */
    uint32_t code;       /* code point */
    uint32_t frame;      /* Font16 DC6 frame */
    uint32_t color;      /* text colour id 0..12 */
    uint32_t rgb;        /* its nominal colour, 0x00RRGGBB */
    D2ItemDrawRect cell; /* in layout pixels */
} D2ItemDrawGlyphRef;

typedef struct D2ItemDrawSpriteRef {
    const char *path;     /* "data/global/items/invamu1.dc6" */
    uint32_t frame;
    int32_t colormap_set; /* -1: no colour map */
    int32_t colormap_row;
    int32_t role;         /* 0 item, 1 socket frame, 2 socketed filler */
    uint32_t ethereal;
    D2ItemDrawRect rect;  /* in layout pixels */
} D2ItemDrawSpriteRef;

typedef int32_t (*d2itemdraw_glyph_fn)(void *user, const D2ItemDrawGlyphRef *glyph, uint32_t scale,
                                       uint32_t w, uint32_t h, uint8_t *rgba);
typedef int32_t (*d2itemdraw_sprite_fn)(void *user, const D2ItemDrawSpriteRef *sprite, uint32_t scale,
                                        uint32_t w, uint32_t h, uint8_t *rgba);

typedef struct D2ItemDrawProviders {
    void *user;
    d2itemdraw_glyph_fn glyph;   /* NULL: libd2's DC6 font */
    d2itemdraw_sprite_fn sprite; /* NULL: libd2's DC6 inventory art */
    uint32_t glyph_pad;          /* pixels the glyph tile extends past the cell on each side */
} D2ItemDrawProviders;

/* kind: D2ITEMDRAW_KIND_*; background and sockets apply to the icon as in d2itemdraw_icon.
 * Needs the art (font metrics, palette); NULL without it. */
D2ItemDrawLayout *d2itemdraw_layout(D2ItemDrawCtx *ctx, const uint8_t *records, size_t len,
                                    const D2ItemDrawOptions *opts, int32_t kind, int32_t background,
                                    int32_t sockets);
/* The display list as JSON; valid until the layout is freed. */
const uint8_t *d2itemdraw_layout_json(D2ItemDrawLayout *layout, size_t *out_len);
int32_t d2itemdraw_layout_width(const D2ItemDrawLayout *layout);
int32_t d2itemdraw_layout_height(const D2ItemDrawLayout *layout);
/* The layout's text, top to bottom, whole lines up to limit bytes (<= 0: 1024). Returns the length. */
int32_t d2itemdraw_layout_text(const D2ItemDrawLayout *layout, int32_t limit, uint8_t *out, size_t cap);
void d2itemdraw_layout_free(D2ItemDrawLayout *layout);

/* The same text without a layout or any art (alt text): whole lines up to limit bytes (<= 0: 1024). */
int32_t d2itemdraw_alt_text(D2ItemDrawCtx *ctx, const uint8_t *records, size_t len,
                            const D2ItemDrawOptions *opts, int32_t limit, uint8_t *out, size_t cap);

/* Draw a layout at scale (1 = the game's size). providers may be NULL. */
D2ItemDrawImage *d2itemdraw_rasterize(D2ItemDrawCtx *ctx, const D2ItemDrawLayout *layout,
                                      const D2ItemDrawProviders *providers, uint32_t scale);

#ifdef __cplusplus
}
#endif

#endif
