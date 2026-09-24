# sprite

A headless, scriptable CLI for Diablo II's sprite formats — DC6, DCC and COF — over `d2-formats`
(decode and encode) and `d2-util` (index-space MMPX). No window, no prompts: data goes to stdout,
diagnostics to stderr, and the exit code says what happened.

```sh
zig build -Doptimize=ReleaseFast        # zig-out/bin/sprite
zig build test                          # unit tests + round trips over the real archives
```

| exit | meaning |
|-|-|
| 0 | done |
| 1 | the work failed: a file would not decode, a round trip differed, a write-back was refused |
| 2 | usage error |

Output is deterministic: names are sorted, PNGs use fixed filtering and zlib level, JSON keys come
out in a fixed order. Running a command twice produces identical files.

## Sources

Every command reads from a stack of MPQs searched in the order given (`--mpq PATH`, repeatable).
Without `--mpq` it opens `patch_d2`, `d2exp`, `d2data` and `d2char` from `$D2_DIR`, or else the
current folder. Names come from the archives' own `(listfile)`s plus any `--listfile`.
A `NAME` is either an archive member — case and `/` versus `\` do not matter, and names are printed
lowercased with `/` — or a path to a file on disk.

## Commands

```sh
sprite list    [--match GLOB] [--json]
sprite info    NAME [--json]
sprite extract NAME --out FILE
sprite render  NAME --out FILE.png [--dir N] [--frame N | --all] [--scale K] [--palette P]
               [--shift SPEC] [--indexed]
sprite compose --token TK --mode MD --wclass WC --out FILE.png [--class chars|monsters|objects]
               [--var COMP=VAR]... [--layer-shift COMP=SPEC]... [--dir N] [--frame N | --all]
               [--scale K] [--indexed] [--json]
sprite unpack  NAME --out DIR [--scale K] [--by-hash] [--rgba]
sprite pack    DIR --out FILE.dc6|.dcc|.cof
sprite upscale NAME --scale K --out FILE.dc6|.dcc|.png
sprite batch   --match GLOB --out DIR [--scale K] [--by-hash] [--rgba] [--manifest FILE]
sprite verify  [--match GLOB] [--json]
```

- **Globs**: `*` stays inside a directory, `**` crosses them, `?` is one character:
  `'data/global/items/*.dc6'`, `'data/global/monsters/**.dcc'`.
- **Palettes** (`--palette`, default `act1`): `act1`..`act5`, any `data/global/palette/<dir>` name
  (`units`, `fechar`, `sky`, ...), or a `pal.dat` on disk (its `pal.pl2` is picked up beside it).
- **Shifts** — 256-entry index maps applied after scaling, at draw time, exactly as the game applies
  them to a sprite draw: `pl2:TABLE:N` is transform N of a table in the palette's `pal.pl2`
  (`light`, `inv_colour`, `selected`, `hue`, `red`, `green`, `blue`, `darkened`, ...); `map:NAME:N` is
  the Nth 256-byte table of a colour-map file such as `data/global/items/palette/grey.dat` or a
  monster's `cof/palshift.dat`. A shift keeps the output indexed.
- **Scaling** (`--scale 1..4`): `--filter mmpx` (default) or `nearest`; `--edge zero` (default:
  outside a frame is a hole, right for sprites) or `clamp` (repeat the border, right for the blocks
  of a tiled UI panel). 3x is MMPX 4x point-sampled; see `packages/util/README.md`. Scaling happens in
  index space, so every output pixel is an index that was in the input.
- **Indexed PNG**: 8-bit colour type 3, the palette in `PLTE`, index 0 transparent via `tRNS`. The
  pixels are the palette indices; nothing is converted. `--indexed` asks for it where RGBA is the
  default (`render`, `compose`); `unpack` and `batch` write indexed unless `--rgba`.

### render and compose

`render` draws one frame (`--dir`, `--frame`) or, with `--all`, a sheet of every direction (rows)
and frame (columns), each cell the same pivot-aligned box so the animation stays registered.

`compose` builds a unit from its COF: `data/global/<class>/<tok>/cof/<tok><mode><wclass>.cof`, each
layer from `data/global/<class>/<tok>/<comp>/<tok><comp><var><mode><layer wclass>.dcc` (or `.dc6`),
drawn back to front in the COF's per-frame priority order. The variant is `--var COMP=VAR`, default
`lit`; if that file does not exist the first listed variant is used, except for the held-item layers
(`rh`, `lh`, `sh`), which are equipment and are left out unless a `--var` names them. `--class` is
guessed (`chars` for the seven class tokens, else `monsters`). Each layer is scaled on its own and
then composed, so a layer's edge is judged against its own holes. `--layer-shift COMP=SPEC` colours
one layer. `--json` reports the file each layer resolved to.

A layer the COF marks transparent is blended with `canvas`'s approximation of its draw mode in RGBA
output; indexed output draws it solid, since a blend has no single index without the pl2 blend
tables.

```sh
sprite render  data/global/monsters/zm/tr/zmtrlitwlhth.dcc --scale 2 --out zombie.png
sprite compose --token am --mode tn --wclass hth --scale 4 --out amazon.png
sprite compose --token am --mode wl --wclass 1hs --var rh=axe --var sh=bsh --all --out walk.png
```

### unpack, pack and upscale — the write-back path

`unpack` writes one indexed PNG per frame plus `sprite.json` (a COF becomes `cof.json`). `pack`
reads that directory back into the game's format. Between the two, any tool can replace the PNGs:
when a PNG is exactly k times its recorded size in both axes, `pack` scales the frame's placement by
k with it, so an upscaled sprite keeps its registration against the pivot. At 1x, `unpack` + `pack`
reproduces DC6 and COF files byte for byte.

`upscale` is `unpack --scale K` + `pack` in one step, or with a `.png` target an indexed sheet.

A DCC stores every 4x4 cell as at most four colours. Game art satisfies that by construction; an
MMPX-scaled frame usually does not, and the DCC encoder refuses it (`TooManyColoursInCell`) rather
than quantising. Write an upscaled DCC out as `.dc6` — the same frames, pivot-registered, with no
cell limit — or use `--filter nearest`, which keeps each cell within four colours. DCC write-back is
decode-exact on every retail file and byte-identical on 21668 of the 21717.

`sprite.json`:

```json
{ "name": "data/global/items/invcap.dc6", "kind": "dc6", "dirs": 1, "framesPerDir": 1, "scale": 2,
  "dc6": { "version": 6, "flags": 1, "encoding": 0, "termination": [238, 238, 238, 238] },
  "frames": [ { "dir": 0, "frame": 0, "w": 56, "h": 56, "x": 0, "y": -56,
                "hash": "61d84782...", "png": "d00f000.png" } ] }
```

`w`/`h`/`x`/`y` are the original frame at 1x; `x`/`y` are its top-left relative to the pivot.
`hash` is SHA-256 over `w`, `h` (little-endian u32) and the original indices — the key to file an
upscaled frame under, independent of which file it shipped in.

### batch

`batch --match GLOB --out DIR` unpacks every DC6, DCC and COF that matches into
`DIR/<member path>/`, and writes `DIR/manifest.json` (or `--manifest`): a JSON array of every
member's description with PNG paths relative to `DIR`. `--by-hash` writes each distinct frame once,
as `DIR/frames/<hash>.png`, so a pack of upscaled art is keyed by the original frame's hash. A member
that fails is reported on stderr, the rest continue, and the exit code is 1.

```sh
sprite batch --match 'data/global/items/*.dc6' --scale 2 --by-hash --out pack/
```

### verify

Decodes and re-encodes every match. DC6 and COF must come back byte for byte; a DCC must decode to
the same frames and boxes (its bytes may differ from Blizzard's; how many are identical is reported). A file the decoder refuses is counted as undecodable, not
failed: one retail `.cof` is the encrypted CD-key blob stored under an animation's name.

## Samples

`samples/` is gitignored: it holds Blizzard art rendered by the commands above and is never
committed.
