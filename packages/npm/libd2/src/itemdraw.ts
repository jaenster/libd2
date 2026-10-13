// Items drawn the way Diablo II 1.14d draws them: the grid icon, the hover tooltip and the two together,
// from an item's save-form records. A thin layer over the d2itemdraw C ABI in `items.wasm`, which is
// its own module so that a page that only wants maps never downloads the item tables.
//
// The art is the caller's: add the game's MPQs (Patch_D2, d2exp, d2data, in that order). Text needs
// none of it.

import {LAYOUT, D2ITEMDRAW_KIND_CARD, D2ITEMDRAW_KIND_ICON, D2ITEMDRAW_KIND_TOOLTIP} from './abi.ts';
import {loadItems, type Exports} from './wasm.ts';

/** Who looks at the item. Leaving it out is the neutral character: every requirement met, no class,
 *  per-level stats at level 99. Class: 0 Amazon .. 6 Assassin. */
export interface Viewer {
  classId: number;
  level: number;
  strength: number;
  dexterity: number;
}

/** engine: the game's own string (first line at the bottom, `ÿcN` colour codes); plain: top to
 *  bottom without colours; colored: top to bottom, each colour run as `{N}text`. */
export type TextMode = 'engine' | 'plain' | 'colored';
const TEXT_MODES: Record<TextMode, number> = {engine: 0, plain: 1, colored: 2};

/** The tint behind the item's cells: none, the normal blue, hovered green, unusable red, unidentified. */
export type Background = 'none' | 'normal' | 'hovered' | 'unusable' | 'unidentified';
const BACKGROUNDS: Record<Background, number> = {none: 0, normal: 1, hovered: 2, unusable: 3, unidentified: 4};

export type LayoutKind = 'icon' | 'tooltip' | 'card';
const KINDS: Record<LayoutKind, number> = {
  icon: D2ITEMDRAW_KIND_ICON,
  tooltip: D2ITEMDRAW_KIND_TOOLTIP,
  card: D2ITEMDRAW_KIND_CARD,
};

/** Straight-alpha RGBA, rows top-down, and the same as a PNG file. */
export interface ItemImage {
  width: number;
  height: number;
  rgba: Uint8Array;
  png: Uint8Array;
}

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** A rectangle of one colour at an alpha: a tinted cell or the tooltip box. */
export interface Fill extends Rect {
  rgb: [number, number, number];
  alpha: number;
}

/** One inventory frame: the item, a socket frame, or what fills a socket. */
export interface Sprite extends Rect {
  /** The draw mode's alpha (0x40, 0x80, 0xC0 or 0xFF); the rasterizer applies it. */
  alpha: number;
  ethereal: boolean;
  role: 'item' | 'socket' | 'filler';
  /** The DC6's game path. */
  path: string;
  frame: number;
  /** The item colour map: the `InvTrans` file and row. */
  colormap: {set: number; row: number} | null;
}

/** One glyph: the code point, the Font16 frame the game draws, its cell (x, y, w, h). */
export interface Glyph extends Rect {
  code: number;
  frame: number;
  advance: number;
}

/** A run of one colour inside a line. */
export interface Span {
  color: number;
  text: string;
  x: number;
  width: number;
  glyphs: Glyph[];
}

export interface Line {
  x: number;
  baseline: number;
  width: number;
  spans: Span[];
}

/** The display list, in the game's pixels: everything the rasterizer draws and where. */
export interface LayoutData {
  kind: LayoutKind;
  width: number;
  height: number;
  origin: [number, number];
  font: string;
  linePitch: number;
  centered: boolean;
  baseColor: number;
  /** The nominal RGB of each text colour id. */
  textColors: [number, number, number][];
  cells: Fill[];
  icon: Sprite | null;
  sockets: Sprite[];
  box: Fill | null;
  /** In the description's order: the first line is drawn at the bottom. */
  lines: Line[];
  /** The lines top to bottom as plain text, capped at 1024 bytes. */
  text: string;
}

/** A layout with its native handle, for `ItemDrawer.rasterize`. Call `free()` when done. */
export class Layout {
  readonly data: LayoutData;
  readonly json: string;
  #handle: number;
  #exports: Exports;

  constructor(exports: Exports, handle: number, json: string) {
    this.#exports = exports;
    this.#handle = handle;
    this.json = json;
    this.data = JSON.parse(json) as LayoutData;
  }

  get handle(): number {
    if (!this.#handle) throw new Error('libd2: the layout was freed');
    return this.#handle;
  }

  free(): void {
    if (this.#handle) this.#exports.d2itemdraw_layout_free(this.#handle);
    this.#handle = 0;
  }
}

/** The tables, the archives added and the art loaded from them. Call `destroy()` when done. */
export class ItemDrawer {
  #e: Exports;
  #ctx: number;
  #archives: [number, number][] = [];

  private constructor(e: Exports, ctx: number) {
    this.#e = e;
    this.#ctx = ctx;
  }

  /** Loads `items.wasm` (once per process) and the tables. */
  static async create(): Promise<ItemDrawer> {
    const e = await loadItems();
    const ctx = e.d2itemdraw_create();
    if (!ctx) throw new Error('libd2: could not load the item tables');
    return new ItemDrawer(e, ctx);
  }

  #ctxOrThrow(): number {
    if (!this.#ctx) throw new Error('libd2: the ItemDrawer was destroyed');
    return this.#ctx;
  }

  #bytes(): Uint8Array {
    return new Uint8Array(this.#e.memory.buffer);
  }

  #copyIn(data: Uint8Array): number {
    const p = this.#e.d2itemdraw_alloc(Math.max(data.length, 1));
    if (!p) throw new Error('libd2: out of wasm memory');
    this.#bytes().set(data, p);
    return p;
  }

  /** Runs `f` with `data` copied into wasm memory, freeing it afterwards. */
  #with<T>(data: Uint8Array, f: (ptr: number) => T): T {
    const p = this.#copyIn(data);
    try {
      return f(p);
    } finally {
      this.#e.d2itemdraw_free(p, Math.max(data.length, 1));
    }
  }

  #options(viewer: Viewer | undefined, act: number): Uint8Array {
    const L = LAYOUT.D2ItemDrawOptions;
    const b = new Uint8Array(L.size);
    const v = new DataView(b.buffer);
    v.setInt32(L.fields.has_viewer.offset, viewer ? 1 : 0, true);
    v.setInt32(L.fields.class_id.offset, viewer?.classId ?? 0, true);
    v.setInt32(L.fields.level.offset, viewer?.level ?? 99, true);
    v.setInt32(L.fields.strength.offset, viewer?.strength ?? 0, true);
    v.setInt32(L.fields.dexterity.offset, viewer?.dexterity ?? 0, true);
    v.setInt32(L.fields.act.offset, act, true);
    return b;
  }

  /** Adds an MPQ, searched after those added before it. Kept in wasm memory until `destroy()`. */
  addArchive(mpq: Uint8Array): void {
    const ctx = this.#ctxOrThrow();
    const p = this.#copyIn(mpq);
    this.#archives.push([p, mpq.length]);
    const rc = this.#e.d2itemdraw_add_archive(ctx, p, mpq.length);
    if (rc !== 0) throw new Error(`libd2: not an MPQ (${rc})`);
  }

  /** Adds one file under its game path (`data/global/items/invamu1.dc6`); it wins over archives. */
  addFile(name: string, data: Uint8Array): void {
    const ctx = this.#ctxOrThrow();
    const n = new TextEncoder().encode(name + '\0');
    const rc = this.#with(n, (np) => this.#with(data, (dp) => this.#e.d2itemdraw_add_file(ctx, np, dp, data.length)));
    if (rc !== 0) throw new Error(`libd2: adding ${name} failed (${rc})`);
  }

  /** Calls a `(..., out, cap) -> length` export twice: once to size, once to fill. */
  #string(call: (out: number, cap: number) => number, cap?: number): string {
    const n = cap ?? call(0, 0);
    if (n < 0) throw new Error(`libd2: the records do not describe an item (${n})`);
    const p = this.#e.d2itemdraw_alloc(Math.max(n, 1));
    try {
      const got = call(p, n);
      if (got < 0) throw new Error(`libd2: the records do not describe an item (${got})`);
      return new TextDecoder().decode(this.#bytes().slice(p, p + Math.min(got, n)));
    } finally {
      this.#e.d2itemdraw_free(p, Math.max(n, 1));
    }
  }

  /** The item's tooltip text. */
  text(records: Uint8Array, viewer?: Viewer, mode: TextMode = 'plain'): string {
    const ctx = this.#ctxOrThrow();
    return this.#with(records, (r) => this.#with(this.#options(viewer, 1), (o) =>
      this.#string((out, cap) => this.#e.d2itemdraw_text(ctx, r, records.length, o, TEXT_MODES[mode], out, cap))));
  }

  /** The description as alt text: top to bottom, no colours, whole lines up to `limit` bytes
   *  (0: 1024, Discord's cap). */
  altText(records: Uint8Array, viewer?: Viewer, limit = 0): string {
    const ctx = this.#ctxOrThrow();
    return this.#with(records, (r) => this.#with(this.#options(viewer, 1), (o) =>
      this.#string((out, cap) => this.#e.d2itemdraw_alt_text(ctx, r, records.length, o, limit, out, cap), 4096)));
  }

  #image(img: number, what: string): ItemImage {
    if (!img) throw new Error(`libd2: could not draw the ${what} (records or art missing)`);
    const e = this.#e;
    try {
      const width = e.d2itemdraw_image_width(img) >>> 0;
      const height = e.d2itemdraw_image_height(img) >>> 0;
      const px = e.d2itemdraw_image_rgba(img);
      const rgba = this.#bytes().slice(px, px + width * height * 4);
      const lenp = e.d2itemdraw_alloc(4);
      try {
        const p = e.d2itemdraw_image_png(img, lenp);
        if (!p) throw new Error('libd2: PNG encoding failed');
        const len = new DataView(e.memory.buffer).getUint32(lenp, true);
        return {width, height, rgba, png: this.#bytes().slice(p, p + len)};
      } finally {
        e.d2itemdraw_free(lenp, 4);
      }
    } finally {
      e.d2itemdraw_image_free(img);
    }
  }

  /** The grid icon; with sockets, the sockets and their fillers as for the hovered item. */
  icon(records: Uint8Array, background: Background = 'none', sockets = false, act = 1): ItemImage {
    const ctx = this.#ctxOrThrow();
    return this.#with(records, (r) => this.#with(this.#options(undefined, act), (o) =>
      this.#image(this.#e.d2itemdraw_icon(ctx, r, records.length, o, BACKGROUNDS[background], sockets ? 1 : 0), 'icon')));
  }

  /** The hover box alone. */
  tooltip(records: Uint8Array, viewer?: Viewer, act = 1): ItemImage {
    const ctx = this.#ctxOrThrow();
    return this.#with(records, (r) => this.#with(this.#options(viewer, act), (o) =>
      this.#image(this.#e.d2itemdraw_tooltip(ctx, r, records.length, o), 'tooltip')));
  }

  /** The item as on hover: cells tinted, icon with sockets, the tooltip above. */
  card(records: Uint8Array, viewer?: Viewer, act = 1): ItemImage {
    const ctx = this.#ctxOrThrow();
    return this.#with(records, (r) => this.#with(this.#options(viewer, act), (o) =>
      this.#image(this.#e.d2itemdraw_card(ctx, r, records.length, o), 'card')));
  }

  /** The display list of an item. */
  layout(records: Uint8Array, kind: LayoutKind, opts: {viewer?: Viewer; background?: Background; sockets?: boolean; act?: number} = {}): Layout {
    const ctx = this.#ctxOrThrow();
    const e = this.#e;
    const h = this.#with(records, (r) => this.#with(this.#options(opts.viewer, opts.act ?? 1), (o) =>
      e.d2itemdraw_layout(ctx, r, records.length, o, KINDS[kind], BACKGROUNDS[opts.background ?? 'none'], opts.sockets ? 1 : 0)));
    if (!h) throw new Error('libd2: could not lay out the item');
    const lenp = e.d2itemdraw_alloc(4);
    try {
      const p = e.d2itemdraw_layout_json(h, lenp);
      const len = new DataView(e.memory.buffer).getUint32(lenp, true);
      return new Layout(e, h, new TextDecoder().decode(this.#bytes().slice(p, p + len)));
    } finally {
      e.d2itemdraw_free(lenp, 4);
    }
  }

  /** Draws a layout at `scale` (1 is the game's size) with libd2's own 1.14d art from the archives.
   *  For other art, `rasterizeLayout` draws the same display list through JavaScript providers. */
  rasterize(layout: Layout, scale = 1): ItemImage {
    const ctx = this.#ctxOrThrow();
    return this.#image(this.#e.d2itemdraw_rasterize(ctx, layout.handle, 0, Math.max(scale, 1)), 'layout');
  }

  destroy(): void {
    if (this.#ctx) this.#e.d2itemdraw_destroy(this.#ctx);
    this.#ctx = 0;
    for (const [p, n] of this.#archives) this.#e.d2itemdraw_free(p, n);
    this.#archives = [];
  }
}

/** A zeroed RGBA buffer a provider paints: the glyph cell (plus `pad` on every side) or the sprite's
 *  rectangle, times the scale. */
export interface Tile {
  w: number;
  h: number;
  rgba: Uint8ClampedArray;
}

export interface GlyphProvider {
  /** Pixels the tile extends past the cell on each side, for an outline or anti-aliasing. */
  pad?: number;
  /** Paint `glyph` of `font`; `rgb` is the nominal colour of its colour id. False declines it. */
  drawGlyph(font: string, glyph: Glyph, color: number, rgb: [number, number, number], scale: number, tile: Tile): boolean;
}

export interface SpriteProvider {
  /** Paint the frame opaque: the draw mode's alpha is the rasterizer's. False declines it. */
  drawSprite(sprite: Sprite, scale: number, tile: Tile): boolean;
}

/**
 * Draws a display list through JavaScript providers, composing exactly as libd2's rasterizer does:
 * the cell tints, the icon, the sockets, the box, then the glyphs, each tile laid over the canvas
 * with straight-alpha "over" at the draw mode's alpha. What a provider declines (or a missing
 * provider) is left out, so pass `ItemDrawer.rasterize` output as a background for libd2's own art.
 *
 * The result is plain RGBA; `new ImageData(result.rgba, result.width)` puts it on a canvas.
 */
export function rasterizeLayout(
  layout: LayoutData,
  providers: {glyph?: GlyphProvider; sprite?: SpriteProvider},
  scale = 1,
): {width: number; height: number; rgba: Uint8ClampedArray} {
  const s = Math.max(1, Math.floor(scale));
  const width = Math.max(layout.width, 1) * s;
  const height = Math.max(layout.height, 1) * s;
  const px = new Uint8ClampedArray(width * height * 4);

  const put = (x: number, y: number, r: number, g: number, b: number, a: number) => {
    if (x < 0 || y < 0 || x >= width || y >= height || a === 0) return;
    const o = (y * width + x) * 4;
    const da = px[o + 3]!;
    if (a === 255 || da === 0) {
      px[o] = r;
      px[o + 1] = g;
      px[o + 2] = b;
      px[o + 3] = da === 0 ? a : a + Math.floor((da * (255 - a)) / 255);
      return;
    }
    const outA = a * 255 + da * (255 - a);
    const c = [r, g, b];
    for (let i = 0; i < 3; i++) {
      px[o + i] = Math.floor((c[i]! * a * 255 + px[o + i]! * da * (255 - a) + Math.floor(outA / 2)) / outA);
    }
    px[o + 3] = Math.floor((outA + 127) / 255);
  };
  const fill = (f: Fill) => {
    for (let y = f.y * s; y < (f.y + f.h) * s; y++) {
      for (let x = f.x * s; x < (f.x + f.w) * s; x++) put(x, y, f.rgb[0], f.rgb[1], f.rgb[2], f.alpha);
    }
  };
  const composite = (t: Tile, x0: number, y0: number, a: number) => {
    for (let row = 0; row < t.h; row++) {
      for (let col = 0; col < t.w; col++) {
        const o = (row * t.w + col) * 4;
        const ta = t.rgba[o + 3]!;
        if (ta === 0) continue;
        put(x0 + col, y0 + row, t.rgba[o]!, t.rgba[o + 1]!, t.rgba[o + 2]!, Math.floor((ta * a + 127) / 255));
      }
    }
  };
  const tile = (w: number, h: number): Tile => ({w, h, rgba: new Uint8ClampedArray(w * h * 4)});
  const sprite = (sp: Sprite) => {
    if (!providers.sprite) return;
    const t = tile(Math.max(sp.w, 0) * s, Math.max(sp.h, 0) * s);
    if (providers.sprite.drawSprite(sp, s, t)) composite(t, sp.x * s, sp.y * s, sp.alpha);
  };

  for (const f of layout.cells) fill(f);
  if (layout.icon) sprite(layout.icon);
  for (const sp of layout.sockets) sprite(sp);
  if (layout.box) fill(layout.box);
  const g = providers.glyph;
  if (g) {
    const pad = g.pad ?? 0;
    for (let li = layout.lines.length - 1; li >= 0; li--) {
      for (const span of layout.lines[li]!.spans) {
        for (const glyph of span.glyphs) {
          const color = Math.min(span.color, 12);
          const t = tile(Math.max(glyph.w, 0) * s + 2 * pad, Math.max(glyph.h, 0) * s + 2 * pad);
          if (g.drawGlyph(layout.font, glyph, color, layout.textColors[color]!, s, t)) {
            composite(t, glyph.x * s - pad, glyph.y * s - pad, 255);
          }
        }
      }
    }
  }
  return {width, height, rgba: px};
}
