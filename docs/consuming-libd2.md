# Consuming libd2 from an external Zig project

libd2 is a monorepo of independent packages under `packages/` (each with its own
`build.zig` + `build.zig.zon`), but a consumer does not have to know that. The root
package exposes **one module, `libd2`**, with every layer reachable by name:

```zig
const libd2 = @import("libd2");

const map  = try libd2.drlg.generate(...);
const hash = libd2.bnet.xsha1.passwordHash("secret");
```

Naming a namespace costs nothing until you use it — Zig analyses a declaration only
when something references it, so a binary that touches `libd2.bnet` never compiles the
map generator and never embeds the excel tables. The per-package modules still resolve
too (see below); the umbrella is the surface, not the structure.

## What is in it

| namespace | module | what it is |
|-|-|-|
| `util` | `d2-util` | Domain-free mechanics: bit reader/writer, the D2GS Huffman codec and its framing. |
| `data` | `d2-data` | The real 1.14d excel tables, embedded, plus the TSV reader. |
| `formats` | `d2-formats` | On-disk parsers: `ds1`, `dt1`, `dc6`, `dcc`, `cof`, the `.d2s` header, and `mpq` archives. |
| `core` | `d2-core` | Domain primitives: the seed LCG, `Stat`, `Unit`, the Fog memory pool. |
| `item` | `d2-item` | Item generation: treasure classes, quality, affixes. |
| `save` | `d2-save` | The `.d2s` character save sections above the header, read and write. |
| `drlg` | `d2-drlg` | Map generation, byte-exact against the engine. |
| `world` | `d2-world` | The live map of a running game: levels, collision, who stands where. |
| `pathfinding` | `d2-pathfinding` | Routing over those maps, walking or teleporting, across levels. |
| `render` | `d2-render` | The automap and the DT1 tile-art layer. |
| `bnet` | `d2-bnet` | Battle.net, before a game exists: BNCS, MCP, BNFTP. |
| `net` | `d2-net` | The D2GS game protocol, once one does. |
| `game` | `d2-game` | The simulation: units, stats, combat, skills, monsters, objects. |
| `client` | `d2-client` | The world as a client knows it — what the server has told you so far. |

## build.zig.zon

Add libd2 as a path dependency. In Zig 0.17 the `.path` must be **relative to
your build root** (absolute paths are rejected):

```zig
.{
    .name = .my_project,
    .version = "0.0.0",
    .minimum_zig_version = "0.17.0",
    .fingerprint = 0x0, // zig prints the correct value on first build

    .dependencies = .{
        .libd2 = .{ .path = "../path/to/libd2" },
    },

    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

## build.zig

```zig
const libd2 = b.dependency("libd2", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("libd2", libd2.module("libd2"));
```

Or take individual packages instead, if you would rather name them explicitly. The
inter-package imports are already wired inside libd2, so they resolve transitively —
you only add the ones you `@import` yourself:

```zig
exe.root_module.addImport("d2-game", libd2.module("d2-game"));
exe.root_module.addImport("d2-data", libd2.module("d2-data"));
```

## src/main.zig (worked example)

```zig
const std = @import("std");
const libd2 = @import("libd2");

pub fn main() !void {
    var dbg: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = dbg.deinit();
    const alloc = dbg.allocator();

    // data: open a real 1.14d excel table from the embedded bytes.
    var skills_tbl = try libd2.data.open(alloc, "Skills");
    defer skills_tbl.deinit();

    // game: load the Skills model (built on data) and read a real value.
    var skills = try libd2.game.Skills.load(alloc);
    defer skills.deinit();
    const fire_bolt = skills.byId(36) orelse return error.SkillMissing; // 36 = FireBolt

    std.debug.print("Skills.txt rows={d}, FireBolt mana={d}\n", .{
        skills_tbl.rowCount(), fire_bolt.mana,
    });
}
```

`zig build run` prints:

```
Skills.txt rows=357, FireBolt mana=5
```

## Zig 0.17 gotchas

- `std.heap.DebugAllocator` is deprecated — use `std.heap.SafeAllocator`
  (`.init(backing, .{})`; `deinit()` returns the leak count) or `std.testing.allocator` in tests.
- `a ** n` is gone — an array of one repeated value is `@splat(value)` with the type on the
  left: `var buf: [64]u8 = @splat(0);`.
- `@intFromEnum`/`@enumFromInt` are deprecated for `@backingInt`/`@fromBackingInt`, and the
  latter takes exactly the backing integer type: widen or narrow it with `@intCast` first.
- `@typeInfo` containers are struct-of-arrays: `.field_names`/`.field_types`/`.field_values`,
  `.decl_names`. `@hasDecl` only sees `pub` declarations.
- `std.fmt.allocPrint(a, ...)` → `a.print(...)`; `std.fmt.bufPrint` → `std.mem.print`.
- In build.zig, `if (b.args) |args| run.addArgs(args);` → `run.addPassthruArgs();`.
- `.zon` path dependencies must be **relative** to the build root.
