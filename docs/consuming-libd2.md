# Consuming libd2 from an external Zig project

libd2 is a monorepo of independent packages under `packages/` (each with its own
`build.zig` + `build.zig.zon`). The **root** package re-exports every public
sub-package module, so an external Zig 0.16 project can add libd2 **once** and
`@import` any of them.

## Importable module names

| module | package | notes |
|-|-|-|
| `d2-core` | packages/core | Stat/Item model foundation (seed-RNG, Stat/StatList, ISC, wire decoder, Fog::Memory pool) |
| `d2-data` | packages/data | the authoritative 1.14d excel tables + TSV reader |
| `d2-sim` | packages/sim | faithful runtime game-simulation port (combat/skills/monsters) |
| `d2-item` | packages/item | faithful item-generation (drop) port |
| `d2-drlg` | packages/drlg | faithful DRLG map generator + collision |
| `d2-formats` | packages/formats | pure DS1/DT1 parsers + the fixed `.d2s` save header |
| `d2-save` | packages/save | the `.d2s` character save sections, read and write |
| `d2-util` | packages/util | D2GS Huffman packet codec + wire framing |

## build.zig.zon

Add libd2 as a path dependency. In Zig 0.16 the `.path` must be **relative to
your build root** (absolute paths are rejected):

```zig
.{
    .name = .my_project,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .fingerprint = 0x0, // zig prints the correct value on first build

    .dependencies = .{
        .libd2 = .{ .path = "../path/to/libd2" },
    },

    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

## build.zig

Take one dependency and pull the modules you want off it with `.module("<name>")`:

```zig
const libd2 = b.dependency("libd2", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("d2-sim", libd2.module("d2-sim"));
exe.root_module.addImport("d2-data", libd2.module("d2-data"));
exe.root_module.addImport("d2-core", libd2.module("d2-core"));
// ...and d2-item / d2-drlg / d2-formats as needed.
```

Inter-package imports (e.g. `d2-sim` depending on `d2-core` + `d2-data`) are
already wired inside libd2, so they resolve transitively — you only add the
top-level modules you actually `@import`.

## src/main.zig (worked example)

```zig
const std = @import("std");
const sim = @import("d2-sim");
const d2data = @import("d2-data");

pub fn main() !void {
    var dbg = std.heap.DebugAllocator(.{}).init;
    defer _ = dbg.deinit();
    const alloc = dbg.allocator();

    // d2-data: open a real 1.14d excel table from the embedded bytes.
    var skills_tbl = try d2data.open(alloc, "Skills");
    defer skills_tbl.deinit();

    // d2-sim: load the Skills model (built on d2-data) and read a real value.
    var skills = try sim.Skills.load(alloc);
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

## Zig 0.16 gotchas

- `std.heap.GeneralPurposeAllocator` is **gone** — use `std.heap.DebugAllocator(.{})`
  or `std.testing.allocator` in tests.
- `std.mem.trimRight` → `std.mem.trimEnd`.
- `.zon` path dependencies must be **relative** to the build root.
