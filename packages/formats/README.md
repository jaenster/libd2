# d2-formats

Diablo II 1.14d's on-disk formats, bytes in and records out — and, for the sprite formats, back
out again. No dependencies and no libc; every function takes the caller's allocator.

| Module | What it is |
|-|-|
| `mpq` | The archive everything ships in, protected archives included; `mpq.Set` searches several in install order |
| `pkware`, `huffman`, `adpcm` | The codecs an MPQ member is packed with |
| `ptc` | The PrePatch delta a patch installer carries |
| `ds1`, `dt1`, `dt1pix` | Level presets, tile libraries and their pixel art |
| `dc6` | Frame sheets. **Decode and encode**, byte-exact over every retail file |
| `dcc` | Compressed unit animations. **Decode and encode**; decode-exact on every retail file, byte-identical on 21668 of 21717 |
| `cof` | A unit mode's layer list and draw order. **Decode and encode**, byte-exact over every retail file |
| `palette`, `pl2` | `pal.dat`, and the light, blend, hue and text-colour transforms in `pal.pl2` |
| `canvas` | An RGBA surface and the index-0-is-a-hole compositing sprites need |
| `font`, `strtbl` | Font tables and string tables |
| `d2s`, `d2s_old` | The fixed `.d2s` header (the sections live in `d2-save`) |
| `installer` | The installer's own containers |

## Writing sprites

```zig
const f = @import("d2-formats");
const sheet = try f.dc6.parse(gpa, bytes);
const again = try f.dc6.encode(gpa, &sheet);   // == bytes
const anim = try f.dcc.parse(gpa, dcc_bytes);
const out = try f.dcc.encode(gpa, &anim);      // parse(out) == anim
const cof = try f.cof.parse(gpa, cof_bytes);
const cof_again = try f.cof.encode(gpa, &cof); // == cof_bytes
```

**DC6.** Runs of at most 127 opaque or transparent pixels, no transparent run before an end of
line, bottom-up rows unless the frame's `flip` is set — the game's own choices, so an unmodified
sheet encodes to the file it came from. The decoder also records what the format does not predict:
some retail files carry leftover buffer bytes in a frame's three trailing bytes or in its
`next_block` link, kept per frame (`tail`, `next_block`) and written back when present.

**COF.** Every byte the parser does not interpret (the header's reserved bytes, the per-frame
animation events, anything after the priority table) is kept and written back.

**DCC.** Encodes a `Dcc` as the decoder returns it, including each frame's own box
(`Direction.frame_boxes`), whose cell split the format depends on. Every cell is coded against an
exact model of the decoder, so what is written is what decodes. A cell holding more than four
distinct colours cannot be represented and is refused (`error.TooManyColoursInCell`) rather than
quantised — game art never has one, an upscaled frame usually does. See the top of
`src/dcc_encode.zig` for the stream choices.

The round trips over the real archives run in `tools/sprite` (`sprite verify`, and its
`zig build test`, which skips when no installation is present).

## Building

```sh
zig build test
```
