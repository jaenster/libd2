# Item drawing

Draw an item the way Diablo II 1.14d draws it: the inventory icon, the hover tooltip, and the card the
game shows on hover (both together). Input is the item's serialized record (the 1.14d item bitstream of
a save or a stash entry, host record followed by its socketed records) plus the game data the caller
supplies. Output is an RGBA buffer, or a PNG through `d2-util`.

libd2 ships no Blizzard art. Every sprite, palette, colour map and font is read from archives or files
the caller hands in. The excel tables and string tables are the ones `d2-data` already embeds, and a
caller with a modified game overrides them with `data.setOverride` as everywhere else.

## Where it lives

|piece|package|why there|
|-|-|-|
|tooltip text (`itemdesc.zig`, `statdesc.zig`, `itemstats.zig`)|`d2-item`|item domain, needs only the tables and strings; usable with no art at all (a bot, a web stash list)|
|icon, frame, font draw, card, asset lookup, C ABI|new `d2-itemdraw` (`packages/itemdraw`)|needs `d2-formats` (dc6, font, palette, pl2, mpq, canvas); `d2-item` stays free of the art formats, `d2-render` drags in the whole DRLG|

Pixels go through `d2-formats`' `canvas` (RGBA canvas, palette blits with a colour map and alpha, fill,
straight-alpha composite, PNG), the one copy `d2-render`'s object sprites and `tools/sprite` use too.

`d2-item`'s existing `itemtext` (the save inspector's approximate formatter, also used by d2up-server's
`d2render`) is left as it is. The new text builder is the faithful one; moving `itemtext` users onto it
is a separate change for the owner to call.

## API

Drawing is two steps. **Layout** turns an item into a display list in 1.14d pixels: the box, every line
as colour runs with each glyph's Font16 frame and cell, the icon and socket frames with their DC6 path,
frame, colour map and draw-mode alpha, and the tinted cells. It needs only the Font16 widths.
**Raster** draws a display list at a scale through providers: a glyph provider paints one glyph into
its cell, a sprite provider one frame into its rectangle. libd2's own providers paint the 1.14d DC6 font
and inventory art from the caller's archives, so `rasterize(layout, defaults, 1)` is byte-identical to
the game. Other art (HD sprites, a vector face drawn into the glyph cell) plugs in as providers without
changing the layout; a tile a provider declines falls back to libd2's.

Zig (`@import("libd2").itemdraw`, module `d2-itemdraw`):

```zig
var assets = itemdraw.Assets.init(gpa);       // where art comes from
try assets.addArchive(mpq_bytes);              // MPQs, searched in the order added (Patch_D2, d2exp, d2data)
try assets.addFile("data/global/items/invamu1.dc6", bytes); // or loose files, which win over archives
const d = try itemdraw.Drawer.init(gpa, &assets, .{ .act = 1 });
defer d.deinit();
const records = try itemdraw.parseRecords(arena, bytes, 7); // host + socketed children
const opts = itemdraw.DescOptions{ .viewer = .{ .class = 1, .level = 80, .strength = 100, .dexterity = 50 } };

var l = try d.layoutCard(records, opts);       // or layoutIcon / layoutTooltip(desc)
defer l.deinit();
const json = try l.json(gpa);                  // the display list as JSON
const alt = try l.text(gpa, 1024);             // plain text, whole lines, capped (Discord alt text)
var img = try itemdraw.rasterize(gpa, &l, my_providers, d.defaults(), 4); // scale 4, own art first
const png = try itemdraw.png(gpa, &img);

var card = try d.card(records, opts);          // shorthand: layout + default providers at scale 1
```

A `GlyphProvider` gets the font name, the glyph (code point, Font16 frame, colour id, cell), the colour's
nominal RGB, the scale and a zeroed RGBA tile of cell x scale plus `pad` on every side. A `SpriteProvider`
gets the sprite (path, frame, colour map, role, ethereal, rect) and a tile of rect x scale, and paints it
opaque; the rasterizer applies the draw-mode alpha. Both return whether they drew.

Without art, `d2-item`'s `itemdesc.Describer` gives the same text from the tables alone.

`item-draw` (`zig build run -- --mpq ... --out DIR save.d2s`) draws every item of a save or record file:
icon, tooltip and card PNGs, the records of each item, and the text with the engine's own string.

Tests: `zig build test` in packages/itemdraw compares the text of every item of three characters
(EpicSorc, EpicAma, and a character composed at test time from `testdata/kits/golden.kit`) with and
without a viewer, the layout JSON of the binding fixtures, the box provider at scale 2 and 4 against the
same layout, a provider through the C callbacks, and a padded provider; with `-Dd2dir=<1.14d install>` it
also hashes every icon, tooltip and card, and `-Dout=DIR` writes them. `-Dupdate-golden=true` rewrites the
golden files, the diff being the review.

`viewer` is optional. Without one the text uses the neutral case below; with one (class, level, strength,
dexterity, the set items worn) the requirement colours, class line, per-level stats, the attack-speed
line and set member colours follow the engine's rules for that character.

C ABI (`d2itemdraw.h`, ABI 2): create/destroy a context, add an archive or a file; `text`, `alt_text`,
`icon`, `tooltip`, `card` from record bytes; `layout` (handle with `json`, `width`, `height`, `text`) and
`rasterize(ctx, layout, providers, scale)`, where `D2ItemDrawProviders` holds a user pointer, a glyph and
a sprite callback (either may be NULL) and the glyph pad.

|language|entry|layout + providers|
|-|-|-|
|Rust|`libd2::itemdraw::Context`|`layout`, `rasterize(&layout, Option<&mut dyn GlyphProvider>, Option<&mut dyn SpriteProvider>, scale)`|
|Go|`itemdraw.New()`|`Layout`, `Rasterize(l, GlyphProvider, pad, SpriteProvider, scale)` (purego callbacks)|
|.NET|`LibD2.ItemDraw.ItemDrawer`|`Layout`, `Rasterize(layout, GlyphProvider?, SpriteProvider?, scale)` (function pointers)|
|npm|`ItemDrawer.create()` (loads `items.wasm`)|`layout`, `rasterize` (libd2's art in wasm); `rasterizeLayout(layout.data, {glyph, sprite}, scale)` composes in JavaScript with the same blending, for providers in JS|

Every binding's tests read the same fixtures, `testdata/itemdraw/bindings` (records, colored text with
and without a viewer, the Griffon's Eye card layout JSON), written by the Zig tests through the C ABI.

## What follows which Ghidra function (1.14d Game.exe)

Text, built bottom-up into one string the way the engine does, then split top to bottom:

|part|function|
|-|-|
|block order, colours, numbers|`LoadItemDesc` 0x0048dd90|
|name lines per quality, personalised, runeword, ears|`GetItemName` 0x0048c060|
|set item card (own order, member list, partial/full bonuses)|`ITEM_BuildSetItemTooltip` 0x0048d1d0|
|Ethereal / Socketed line|`INV_FormatEtherealSocketedText` 0x00484b10|
|rune letters|`INV_FormatRunewordName` 0x00486670|
|gem/rune per-slot lines|`INV_FormatSocketFillerDesc` 0x004865d0, `SKILLDESC_BuildMagicAffixDesc` 0x004e6850|
|defense, damage, block, durability, attack speed, requirements|0x00485ee0, 0x00485410, 0x00485be0, 0x00484e90, 0x004861d0, 0x00484ff0/0x004850a0/0x00485170|
|current values (op 13 percent of base, per-level ops)|`STATSEX_GetCurrentStat` 0x00625480|
|attack speed|`ITEM_CalcWeaponAttackSpeed` 0x0062a710|
|required level|`ITEM_CalcRequiredLevel` 0x0062b5b0|
|stat list merge (own + runeword + socketed), walk|`SKILLDESC_BuildStatBuffDesc` 0x004e60a0, `SKILLDESC_BuildStatListDesc` 0x004e49c0|
|descfunc 1..28, dgrp groups, descstr2 suffix|`ItemStatCost_DescFunc_DGrpFunc` 0x004e4d80, `SKILLDESC_CalcStatGroupValue` 0x004e4c50, `SKILLDESC_CalcStatGroupMinMax` 0x004e4ce0|
|damage pairs, enhanced damage, poison seconds|`SKILLDESC_BuildStatDescription` 0x004e5a20|
|line order (unstable VS2005 qsort on descpriority)|`SORT_ItemDescPriority` 0x006379d0 with the CRT qsort 0x00685b50|

Frame (the box):

|part|function|
|-|-|
|store, measure|`TEXT_TooltipSetAttributes` 0x00502280, `TEXT_CalcTextDimensions` 0x00502520|
|draw: box W = widest line + 8, H = 16 per line (Font16, Latin), black rect at mode 2 (alpha 0xC0), lines centred one by one, first buffer line at the bottom|0x00503000, `D2GFX_DrawSolidRectEx` 0x004f6300, `D2WINFONT_DrawWideString` 0x00501a80|
|glyph advance, colour codes `ÿcN`|0x00501840, 0x00501650|
|placement above the item, centred, 2 px overlap|`LoadItemDesc` 0x0048ed34|

Icon:

|part|function|
|-|-|
|graphic: set/unique invfile, then VarInvGfx variant, then base invfile|`GFXUTIL_SetItemGfxFile` 0x004dabc0|
|top-left at the cell origin, 29 px cells, no centring; ethereal draws at mode 1 (50%)|`DrawItemGfx` 0x0046ee80|
|colour remap: InvTrans picks the palette file, the item's colour picks the row|`GetItemColor` 0x0062c100, `PALETTE_GetItemPalette` 0x00600c20|
|sockets (hovered and identified only): gemsocket at mode 0, filler drawn through its own icon path, 48-row position table|`INV_DrawSocketedItems` 0x00483e40|
|cell background tint (blue normal, green hovered, red unusable, dull red unidentified), mode 0|`DrawItemSolidBackground` 0x004839d0|

## The neutral case

With no character the engine's own null path is not usable (requirements red, Defense missing, damage
"1 to 2", the attack-speed calculation halts). Without a viewer we draw: requirements and class line in
white, numbers from the item's own stats, block without the class block factor, per-level stats at the
options' level (default 99), no attack-speed line, no kick/smite line, every set member red, no set
bonuses that need worn pieces. Everything else is the engine's rule.

## Not covered

- Shop cost lines and the trade-page short form (no shop here).
- By-time stats against a live act: shown as the engine does with no act loaded.
- Missile potions' throw damage (needs Missiles.txt and the character's skills).
- The quest-difficulty red name, monster body part names, elixirs.
- Potion points: the calc column as written, without the per-difficulty adjustment.
- Fractional scales: providers get an integer scale (D2OpenGL's HD text draws at fractional ones).
- Text wrapping: none, as in the engine.
- Unconfirmed, for the in-game screenshots: the vertical position of the glyphs in the box, the set
  member order, whether an unworn set piece shows the partial bonuses of the worn pieces, the tome
  line order, translucency taken as the Glide/Direct3D alpha constants (0x40/0x80/0xC0).
