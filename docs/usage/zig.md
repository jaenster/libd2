# libd2 from Zig

Native Zig consumers use the packages as source modules — no C ABI needed. Depend
on the one you want by path and import its module.

```zig
// build.zig.zon
.dependencies = .{
    .d2_item = .{ .path = "path/to/libd2/packages/item" },
},
```

```zig
// build.zig
const items = b.dependency("d2_item", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("d2-item", items.module("d2-item"));
```

```zig
// somewhere.zig — the real Zig API (richer than the C ABI)
const d2item = @import("d2-item");

var tables = try d2item.Tables.load(alloc);
var set = try d2item.treasure.build(alloc, &tables);
// Two streams: the dropping unit's seed drives the treasure-class walk and the
// drop-time quality; the game seed is stepped twice per created item to produce
// that item's own affix/property seed.
var drop_seed = d2item.Seed.init(12345, 0x29a);
var game_seed = d2item.Seed.init(0xC0FFEE, 0x29a);
const drops = try d2item.rollDrop(alloc, &drop_seed, &game_seed, &tables, &set, "Act 1 Equip A", 5, .{});
defer alloc.free(drops);
```

Each package's module surface is documented in its own `packages/<pkg>/README.md`.
The C ABI (see the other language guides) is a thin wrapper over these same APIs.
