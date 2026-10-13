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

`d2-item`'s existing `itemtext` (the save inspector's approximate formatter, also used by d2up-server's
`d2render`) is left as it is. The new text builder is the faithful one; moving `itemtext` users onto it
is a separate change for the owner to call.

## API

Zig (`@import("libd2").itemdraw`, module `d2-itemdraw`):

```zig
var assets = itemdraw.Assets.init(gpa);       // where art comes from
try assets.addArchive(mpq_bytes);              // MPQs, searched in the order added (Patch_D2, d2exp, d2data)
try assets.addFile("data/global/items/invamu1.dc6", bytes); // or loose files, which win over archives
var d = try itemdraw.Drawer.init(gpa, &assets, .{ .act = 1 });
const records = try item.itemdesc.parseRecords(arena, bytes, 7); // host + socketed children
const desc = try item.itemdesc.build(arena, &tables, records, viewer); // lines, top to bottom, with colours
var icon = try d.icon(records, .{ .background = .none, .sockets = false });
var tip  = try d.tooltip(desc);
var card = try d.card(records, viewer);         // background + icon + sockets + the box, placed as on hover
const png = try icon.png(gpa);
```

`viewer` is optional. Without one the text uses the neutral case below; with one (class, level, strength,
dexterity, the set items worn) the requirement colours, class line, per-level stats, the attack-speed
line and set member colours follow the engine's rules for that character.

C ABI (`d2itemdraw.h`, in the combined wasm as subsystem `itemdraw`, Go package `itemdraw`, .NET
`LibD2.ItemDraw`): create/destroy a context, add an archive or a file, then `text`, `icon`, `tooltip`,
`card` from record bytes, each returning an image handle with width, height, RGBA and PNG accessors.

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

Shop cost lines, the trade-page short form, by-time stats evaluated against a live act (shown as with
no act, the engine's own branch), the full-set bonus block (needs the owner's set state list), elixirs.
