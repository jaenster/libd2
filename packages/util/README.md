# d2-util

Cross-cutting primitives with no domain of their own. No dependencies, no libc; everything except
`png` is allocator-free, and the package builds for `wasm32-freestanding`.

| Module | What it is |
|-|-|
| `huffman` | The D2GS server->client packet codec of 1.14d `Game.exe`: compress, decompress, and the canonical table both sides build |
| `frame` | The length-prefix packet framing and the `AF` greeting around it |
| `png` | PNG out and back: RGBA8888 (stored or zlib-compressed), and 8-bit indexed with the palette in PLTE and index 0 transparent, which reads back to the exact indices. Takes an allocator |
| `mmpx` | MMPX pixel-art magnification of 8-bit palette indices, 2x/3x/4x. Has a C ABI |

```zig
const util = @import("d2-util");
try util.mmpx.scale(src, w, h, w, 2, .{ .palette = &pal, .edge = .zero }, dst, w * 2);
```

## MMPX on palette indices

MMPX is Morgan McGuire and Mara Gagiu, "MMPX Style-Preserving Pixel Art Magnification", JCGT
vol. 10 no. 2, 2021 (<https://jcgt.org/published/0010/02/04/>). `src/mmpx.zig` ports the rules of
the authors' MIT-licensed reference (the copyright notice is kept in that file): 1:1 slopes,
intersections, triangle tips and 2:1 slopes, reading up to three pixels out from the centre. MMPX
never blends, so **the output contains only indices that occur in the input**. With a palette whose
entry 0 is transparent black, the 2x output is identical to the reference run on the RGBA
expansion of the image.

- **Equality is index equality.** Two indices whose palette colours coincide are still different
  pixels.
- **Brightness.** The rules break some ties by brightness, the reference's
  `(r + g + b + 1) * (256 - alpha)`. With a palette (768 bytes, 256 colour triples) an opaque index
  ranks at `r + g + b + 1`. The sum does not depend on channel order, so D2's `pal.dat` (B,G,R) can
  be passed exactly as loaded; there is no RGB/BGR switch because none is needed. Without a
  palette, indices rank by value, so only index order drives those rules.
- **Index 0 is transparent**, as in D2, unless `index0_transparent = false`
  (`D2UTIL_INDEX0_OPAQUE`). For equality it is an ordinary index. For brightness, with a palette it
  gets the reference's alpha-0 luma `(r + g + b + 1) * 256` of entry 0; for D2's black entry 0 that
  is 256, which ranks above opaque colours with `r + g + b < 255` and below brighter ones - exactly
  where the reference puts a transparent black pixel. Without a palette it ranks above every other
  index.
- **Edges.** `.clamp` (default, the reference's behaviour) repeats the nearest edge pixel, right
  for tiled UI panels. `.zero` (`D2UTIL_EDGE_ZERO`) reads index 0 outside, the reference's mode for
  sprites and fonts; the rules may then copy index 0 in at the border.
- **Scales.** 1 copies. 2 is MMPX. 4 is MMPX applied to the 2x image. 3: MMPX defines only 2x, so
  3x is the 4x image sampled at the centres of the 3x pixels. Per source pixel, 3x columns 0 and 2
  take 4x columns 0 and 3; the centre of 3x column 1 falls exactly on the edge between 4x columns
  1 and 2, so it takes the more frequent of those two (the block's middle pixel chooses among the
  central 2x2 the same way), a tie going to the source pixel when it is among the tied, else to
  the lowest index. That makes 3x exactly mirror- and transpose-symmetric, which plain `floor((4x + 2) / 3)` point sampling is
  not (it takes 4x columns 0, 2, 3 - its mirror would take 0, 1, 3).
- **Deterministic and allocation-free.** 3x and 4x run the second pass over 40x40 tiles of the 2x
  image (plus a 3-pixel halo recomputed from the source) in a stack buffer, which reproduces a
  full-size 2x buffer exactly; the tests check 4x against two whole-image 2x passes. `src` and
  `dst` must not overlap.

Rough cost (Apple M-series, ReleaseFast, 800x600 busy image): 2x ~9 ms, 3x or 4x ~50 ms. Upscale
once and cache, not per frame.

## C ABI

`include/d2util.h`, implemented in `src/capi.zig`. Stateless, allocation-free, thread-safe, no libc.

```c
int32_t d2util_abi_version(void);   /* 1 */
int32_t d2_upscale_indices(const uint8_t *src, int32_t w, int32_t h, int32_t src_pitch,
                           int32_t scale, const uint8_t *palette_rgb /* 768 bytes or NULL */,
                           uint8_t *dst, int32_t dst_pitch);
int32_t d2_upscale_indices_ex(/* same */ ..., int32_t flags); /* D2UTIL_EDGE_ZERO | D2UTIL_INDEX0_OPAQUE */
```

Returns 0, `D2UTIL_ERR_ARGS` (-1: null pointer, negative dimension, pitch smaller than its row,
unknown flag) or `D2UTIL_ERR_SCALE` (-2: scale not 1-4). `dst` must hold
`(h*scale - 1)*dst_pitch + w*scale` bytes with `dst_pitch >= w*scale`; the library cannot check
that. `w == 0` or `h == 0` is a no-op.

## Building

```sh
zig build test                     # unit tests + C-ABI tests
zig build                          # native libd2util.a / .dylib|.so + include/d2util.h
zig build -Dcapi=false             # the Zig module only
zig build -Dtarget=wasm32-freestanding   # wasm: the module builds, the C libraries are skipped
```

### For D2OpenGL (mingw i686 DLL)

```sh
cd packages/util
zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast
```

produces

- `zig-out/lib/d2util.lib` - the static archive (COFF objects, `ar` format; Zig names it `.lib` on
  Windows even for the GNU ABI). mingw links it by path:
  `i686-w64-mingw32-gcc ... foo.o /path/to/d2util.lib -shared -static-libgcc`.
- `zig-out/include/d2util.h`
- `zig-out/bin/d2util.dll` - a standalone DLL, if a host prefers one. Its import library is not
  installed, because on Windows it is also named `d2util.lib` and would overwrite the archive;
  mingw links a `.dll` directly.

The archive exports `_d2_upscale_indices`, `_d2_upscale_indices_ex` and `_d2util_abi_version`
(i686 cdecl decoration) and needs only `_memcpy` and `_memset` from the host's C runtime - no
compiler-rt, no stack probes (`__alloca`/`___chkstk_ms`), no ntdll. That holds for every optimize
mode: on Windows the shim installs a trapping panic handler so Debug and ReleaseSafe do not pull in
std's stack-trace printer. compiler-rt is deliberately not bundled. Verified by linking a DLL and an
exe with `i686-w64-mingw32-gcc` (D2OpenGL's own flags: `-shared -static-libgcc
-Wl,--enable-stdcall-fixup -static-libstdc++`) and with `zig cc -target x86-windows-gnu`, and
running them under wine.
