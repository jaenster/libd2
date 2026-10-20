# Drawing a level as the game draws it

An area or unit preview that looks the way the game looks: the same tiles in the same order, under
the same light, through the same texture formats and blend maths as the D2OpenGL renderer. This note
says what of that lives in libd2, how it is drawn without the game, Windows or a GPU, where a mod
plugs in, how it is proven against the renderer, and what is in the first slice.

The route that came first runs the renderer itself: the mod writes a scene file, a small x86 Windows
program loads the debug D2OpenGL.dll under Wine and feeds it the scene through the renderer's slot
table. It is exact by construction but needs Wine, a Windows build of the renderer and a GL context,
so it cannot run in CI, on Linux, in a browser or in a server. libd2's route draws the same scene in
Zig and must match the Wine route's frames before the Wine route is retired.

## The packages

`d2-gfx` (new, `packages/gfx`, no dependencies, libc-free, builds for `wasm32-freestanding`):

|module|what it is|
|-|-|
|`scene`|The scene file: DT1s by game path, every tile placement in drawing order, the screen palette, the light map, units' layers, the world view. libd2 owns the format from here on; a host writes it|
|`tiles`|A DT1 as the renderer receives it (tile entries, blocks) and the two decodes textures are made from: a floor or roof tile into 256 x 128 indices, a wall or shadow block into 32 x 32|
|`tilepal`|Which palette a tile converts with: the screen's, with the act stretch (indices 225..254) of the DT1's own act when that is another act|
|`light`|Light values per draw (36 per ground tile, 6 per wall by direction), the modulate (intensity * channel / 255), and the smooth-light lattice: growth of the border rings, the clamped Catmull-Rom sample|
|`raster`|The CPU rasteriser: triangles with colour and texel coordinates, nearest and linear sampling, repeat or clamp, the texture unit's modulate and RGB scale, the alpha test, blend off, alpha and multiply|
|`view`|A frame: the renderer's tile draws at render scale 1 with the view flat, in the client's pass order|
|`compare`|The 64 x 64 block gate between two frames of one view|
|`gamma`|The Options' gamma and contrast table over the finished frame|

`tools/gfx` is the command line over it (`gfx view`, `gfx compare`, `gfx stats`, `gfx levels`).

### The pass order

ViewDraw2 (1.14d D2Client 0x476bc0) draws the world in this order, and `scene.Pass.rank` plus the
order of the draw list carry it:

1. the Arcane Sanctuary's stars (0x476290) when the player's level is the Sanctuary, the Arreat
   Summit's backdrop (0x476460) when it is the Summit;
2. the lower walls, DT1 orientations 16 to 19, under the floor (0x4df480), when the view's flag asks;
3. the floor (0x4ded10), then the rain on it;
4. the shadow tiles (0x4df510);
5. the walls (0x4df1c0), each unit after the walls of its cell and the cells before it, its shadow
   with the shadow tiles;
6. the roofs (0x4dea70), then the weather overlay and the scene transition.

Within a pass a tile goes by row (tx + ty), then column (tx - ty), then placement order. The stars
and the backdrop are not in the scene format yet (see below): they are DC6 cels drawn before
everything, so they arrive as a `background` section of version 3.

### What moves in, and from where

|piece|today|in libd2|
|-|-|-|
|DS1/DT1 to a draw list in pass order|d2up `preview_scene.zig`, `map_preview.drawBefore`|`d2-gfx.scene` (done); a `d2-render` adapter that writes a scene from libd2's own map generation|
|Per-tile and per-wall light values|d2up `preview.cpp` (the client's side)|`d2-gfx.light` (done)|
|The light map: ambient (ROOM_GetAmbientLightColor 0x474550), point lights (LIGHTMAP_ApplyPointLight 0x4748d0, LIGHTMAP_AddLightToCell 0x4747c0)|d2up `preview_scene.zig` `LightMap`|`d2-gfx.lightmap`: our code, moves as is|
|Wall occlusion of light (LIGHTMAP_ApplyStaticLightWithShadow 0x474d70: BLANK and BLOCK_MISSILE about the light, shade passed ring by ring)|d2up `preview_scene.zig`|`d2-gfx.lightmap`, reading the collision `d2-drlg` already computes byte-exact; the scene gains a collision section so a host without libd2's map generation can still pass one|
|Smooth light, coloured light, the light curve|D2OpenGL `lighting.cpp`, `light_grid.h`, `colour_light.h`|`d2-gfx.light` (lattice done; the curve is a host parameter)|
|Unit composition from COF/DCC|d2up `scene_units.zig` (picks the COF, mode, colour table); libd2 `tools/sprite` `compose.zig`|COF/DCC decode is in `d2-formats`; composition (layer order by direction row, colour tables) moves from `tools/sprite` into `d2-gfx.units`, which the sprite tool then calls. Choosing *which* monster and colour table stays with the host|
|HD pack reader|D2OpenGL `upscale/hdpack*.{h,cpp}`; libd2 `d2-util.hdpack` (the writer and format), `d2-util.framekey`|`d2-util.hdpack` gains the lookup the renderer does; D2OpenGL links it|
|Blend tables (the pl2 transforms and their exact equations), linear blend, Transparency=exact|D2OpenGL `renderer/blend*.h`, `present/filter_math.h`|`d2-gfx.blend`; the tables from `d2-formats.pl2`|
|Gamma and contrast|D2OpenGL `present/gamma_math.h`|`d2-gfx.gamma` (done)|
|Act palette stretches per DT1 folder|D2OpenGL `renderer/tile_palette.h`|`d2-gfx.tilepal` (done); the stretches themselves are palette data and come from the host|

## The drawing

**A CPU rasteriser is the backend**, not Metal or OpenGL. Reasons:

- libd2 is libc-free and must build for `wasm32-freestanding`. A GPU backend is a platform binding;
  the rasteriser is plain Zig and runs in CI on Linux, in a browser (the preview site could draw
  views client side) and in a server (a Discord preview, the stash renderer).
- A preview is a few frames, not 60 a second. One 800 x 600 view draws in about 80 ms single-threaded
  (ReleaseFast, Apple M3), the whole level's overview in seconds.
- It is deterministic: the same scene gives the same bytes on every machine, so a golden test is a
  byte compare, which a GPU driver never promises.

The rasteriser does what the GL implementation does with these draws (pixel centres at half
integers, top-left ties, screen-linear attributes, 8 bits of sub-texel weight, rounding to 8 bits),
closely enough for the block gate; it is not a GL emulator and only covers the state the world
passes use. If speed ever matters (an interactive viewer at 2x with HD packs), a GPU backend can draw
the same draw list; the CPU one stays the reference.

### One source with D2OpenGL

D2OpenGL is our C++ in d2up. **D2OpenGL consumes libd2's**, rather than both building from shared
files:

- **The maths that is code today:** D2OpenGL already keeps its maths in plain headers without GL or
  Windows (`colour_light.h`, `light_grid.h`, `gamma_math.h`, `tile_palette.h`, `blend_modes.h`,
  `filter_math.h`, `hdpack_format.h`) so its offline checks can run them. Each is replaced by a call
  into a `d2gfx.h` C ABI, built as an i686 mingw static library from `d2-gfx`, the way D2OpenGL
  already links `d2util.lib` for MMPX. The lattice, the modulate, the act palette choice, the gamma
  table, the blend tables and the HD pack lookup are then one Zig implementation. A header goes when
  D2OpenGL's own offline check (`test/lightcheck` and kin) passes against the library.
- **The shaders:** the GLSL (the light spline, linear blend, the grade, soft shadows) moves to
  `packages/gfx/shaders/*.glsl`, and D2OpenGL's build embeds them as strings (a build step writes the
  header) instead of holding them as raw literals. The CPU side implements the same functions in Zig
  next to them. GLSL cannot run in libd2's CI, so the two are kept together by the block gate below,
  not by sharing bytes; each shader file names the Zig function it must equal.
- **Fixed-function state** (the texture unit's modulate and RGB scale, the alpha test, filters,
  texture formats) is not code in D2OpenGL either: `view.zig` writes down what the renderer sets for
  each draw, and the gate checks it.

Why not the other way round (libd2 builds D2OpenGL's C++): libd2 is Zig only and libc-free, and a
C++ dependency would pull libc++ into every consumer and out of wasm.

What may not move as code: D2OpenGL's `renderer/` is in part recovered from the Mac OpenGL renderer
(the functions marked with Mac addresses: the ground mesh and its UV insets, the wall corner table,
the modulate table, the texture managers). libd2 does not transliterate those; it states their
behaviour (`view.zig`'s header) and implements it, the standard `d2-drlg` was written to. Our own
parts of D2OpenGL (smooth and coloured light, the act palettes, the light curve, HD packs, blend
linear, the quality pass, the Act VI layers) are ours and move as code.

## Where a mod plugs in

d2up's generator and Act VI moods are d2up's. libd2 holds none of d2up's game data; the interface:

|plug|type|d2up passes|
|-|-|-|
|the scene|the `D2PS` file or a `scene.Scene` in memory|its laid-out level (`area_scene.zig`: Anchorhold, hybrid levels, the Cathedral District, the maze kits) and its units|
|act palette stretches|`tilepal.Ramps`, six optional stretches|acts 1 to 5 from the game's pal.dat, act 6 from d2up's palette|
|tile folders|`[]tilepal.Folder`|`act6` drawn on act 3's palette|
|the screen's act|detected from the screen palette's stretch, as the renderer does|nothing|
|the light curve|a power on intensity (`OGL_SetLightCurve`)|the level's darkness from its mood table|
|world layers|two callbacks on `view.Renderer`: after the floor pass and after the roofs, each given the frame's target, the view and the world state (level, seed, day ticks), plus a final pass over the finished frame|the Act VI glass, fog, ambience, wind, sand and grade, written in Zig against `raster.Target`|

The world layers are the part that does not move: they are d2up's look, ported out of D2OpenGL's
C++ into d2up's own Zig and called through the callbacks. Until a layer is ported, the comparison
for that layer runs with `--no-world` on both sides.

## Verification

The gate before the Wine route is retired: the same views rendered by both routes, compared per 64 x
64 block (`gfx compare`, `d2-gfx.compare`):

- the mean absolute difference in linear light (sRGB decoded, 0..255) under 2, and SSIM on
  luminance (8 x 8 windows, stride 4) over 0.98, in every block with at least half its pixels
  unmasked;
- every view `area-scene` picks, for every level of the sixth act, at render scale 1 and 2, with and
  without HD packs, units on, world layers on once ported;
- a failing block is shown side by side with the difference times eight (`--out`): geometry errors
  show as edges, light errors as smooth gradients, palette errors as speckle.

The Wine route is retired only when every one of those passes, and libd2's frames become the
goldens.

### The first slice (Cathedral District, level 165)

`d2-gfx` draws floors, roofs, walls and shadow tiles with the smooth light. Scene: `zig build
area-scene -- --level 165 --units 0` on d2up `preview-render` (4979f59e): 6747 floor, 1140 roof,
1473 wall and 534 shadow draws from 32 DT1s (29 of act 2, 3 of d2up's act 6). Wine route:
`d2up-preview.exe --no-world`, render scale 1, the release `D2OpenGL.ini`, no HD pack. The four views
`area-scene` picked:

|view|gamma off, mean / worst block / worst SSIM|gamma 155,49|
|-|-|-|
|-1520,900|0.013 / 0.046 / 0.9986|0.035 / 0.117 / 0.9972|
|1280,4500|0.016 / 0.024 / 0.9989|0.044 / 0.064 / 0.9982|
|2880,2400|0.016 / 0.060 / 0.9988|0.043 / 0.143 / 0.9979|
|-4720,2700|0.016 / 0.030 / 0.9994|0.045 / 0.079 / 0.9991|

All 130 blocks of every view pass; no pixel differs by more than 8 in any channel, most by 0 or 1.
With a tinted ambient (`--ambient 140,255,200,150`, exercising the modulate and the lattice) two views
give mean 0.004, worst SSIM 0.9982.

What the slice found out about the renderer under Wine on macOS: textures are ARGB1555 (the Apple
packed-pixel path drops the low three bits of each channel; 8-bit texels fail SSIM on the walls at
0.975), and the floor is a 160 x 80 rectangle texture sampled linear. Both are `view.Options`
(`texels`, `rect_textures`), since a Windows driver takes the other branch. Without the act 2
stretch on the act 6 screen the floor speckles (mean 0.36, 23k pixels off by more than 8), which is
what the palette plug is for.

Not yet covered: the lower-wall pass (no level-165 draws), units and their shadows, point lights and
their occlusion (the scene's light map arrives built), the stars and the backdrop, render scale 2,
HD packs, colour detail, soft shadows, perspective, roofs lifting over the player, animated water and
the Act VI layers. Off-lattice ground tiles (the renderer then falls back to per-vertex light) are
implemented but only seen under uniform light here.

Reproduce:

    zig build area-scene -- --level 165 --units 0 --out 165.scene          # in d2up
    tools/preview-render.sh WORK 1 --scene 165.scene -- --views auto       # sets up WORK/run
    wine d2up-preview.exe level.scene nw -opengl --views X,Y --no-world --gamma off   # in WORK/run
    gfx view 165.scene --views "X,Y" --out cpu --gamma off --act-palettes PALS --folder act6=3
    gfx compare nw/view-X_Y.png cpu/view-X_Y.png --out side.png

`PALS` holds `pal1.dat` .. `pal6.dat` (`sprite extract data\global\palette\ACTn\pal.dat`; act 6 is
d2up's). Note `preview-render.sh` passes `--no-world` only to its overview run, not to the views; run
the views directly as above.

## Licensing

libd2 is clean-room. Nothing comes from `refs/` (D2MOO, PlugY and the rest) or from any leaked
source. Addresses cited are from our own Ghidra databases of the shipped 1.14d binaries, as elsewhere
in libd2. Palette data is never committed: the act stretches come from the host at run time. Our own
D2OpenGL code may move in; its recovered Mac renderer parts are described and reimplemented, not
copied.
