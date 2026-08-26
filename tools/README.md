# tools

Command-line programs that run on a developer's machine, over the packages.

Three tiers live in this repo and the distinction is what each one is *for*:

| tier | what it is | example |
|-|-|-|
| `packages/` | a library module, consumable on its own | `d2-bnet`, `d2-formats` |
| `apps/` | something deployed — a service, a container | `drlg-server` |
| `tools/` | something you run yourself, against real files | `keys` |

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
