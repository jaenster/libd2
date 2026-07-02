# libd2 from Zig

Native Zig consumers use the packages as source modules — no C ABI needed. Depend
on the one you want by path and import its module.

```zig
// build.zig.zon
.dependencies = .{
    .d2_items = .{ .path = "path/to/libd2/packages/items" },
},
```

```zig
// build.zig
const items = b.dependency("d2_items", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("d2-items", items.module("d2-items"));
```

```zig
// somewhere.zig — the real Zig API (richer than the C ABI)
const d2items = @import("d2-items");

var tables = try d2items.Tables.load(alloc);
var set = try d2items.treasure.build(alloc, &tables);
var seed = d2items.Seed.init(12345, 0x29a);
const drops = try d2items.rollDrop(alloc, &seed, &tables, &set, "Act 1 Equip A", 5, .{});
defer alloc.free(drops);
```

Each package's module surface is documented in its own `packages/<pkg>/README.md`.
The C ABI (see the other language guides) is a thin wrapper over these same APIs.
