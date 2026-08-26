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
