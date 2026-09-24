# tools

Command-line programs that run on a developer's machine, over the packages.

Three tiers live in this repo and the distinction is what each one is *for*:

| tier | what it is | example |
|-|-|-|
| `packages/` | a library module, consumable on its own | `d2-bnet`, `d2-formats` |
| `apps/` | something deployed — a service, a container | `drlg-server` |
| `tools/` | something you run yourself, against real files | `keys`, `sprite` |

A tool is not deployed and is not depended on. It exists so a package can be pointed at a real
Diablo II installation and made to prove itself, which a unit test over a fixture cannot do.

Each tool is its own `build.zig` + `build.zig.zon`, exactly like an app, and depends on the
packages by path.

## What is here

### `keys` — the CD key material in an installation

Diablo II does not keep the CD key in the registry. It keeps it encrypted inside one of the game's
own archives, under the name of an ordinary asset: a cursor sound for the classic key, an Amazon
animation for the expansion one. `d2-bnet`'s `keystore` holds the cipher and the search order, and
this points them at a real installation.

```sh
keys show <game-dir>     the keys and owner it is carrying
keys find <game-dir>     which archive holds them, without decrypting
keys decode <key>        what a 16- or 26-character key decodes to
```

`show` and `find` read only; neither writes to the installation, and no key is written anywhere by
this program. Verified against the game itself — blobs from the same `keystore` are accepted by the
real `Bnclient.dll`, so what `show` prints is what the game would read.

### `sprite` — DC6, DCC and COF art, out of the archives and back in

A headless CLI for pipelines: list and extract sprites from the MPQs, render a frame or a composed
unit (COF layers in draw order) to PNG, unpack frames to indexed PNGs with a JSON description keyed
by the SHA-256 of each frame's indices, upscale in palette-index space with MMPX, and pack the
result back into DC6, DCC or COF. `verify` round-trips every file in the archives.

```sh
sprite list --match 'data/global/items/*.dc6'
sprite compose --token am --mode tn --wclass hth --scale 2 --out amazon.png
sprite batch --match 'data/global/items/*.dc6' --scale 2 --by-hash --out pack/
sprite verify
```

Deterministic output and exit codes (0 ok, 1 failed, 2 usage). See [`sprite/README.md`](sprite/README.md).
