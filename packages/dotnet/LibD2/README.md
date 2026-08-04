# LibD2

Clean-room **Diablo II 1.14d** map generation for .NET. Give it a seed and it produces the
same world the game does: rooms, preset objects and monsters, level adjacency and subtile
collision, for every level of all five acts.

```csharp
using LibD2.Drlg;

using var drlg = new MapGenerator();
var act = drlg.GenerateAct(seed: 1337, act: 0);   // 0 is Act I, 4 is Act V

foreach (var level in act.Levels)
    Console.WriteLine($"{level.Name}: {level.Rooms.Count} rooms at ({level.OriginX}, {level.OriginY})");
```

```
Rogue Encampment: 35 rooms at (1104, 1080)
Blood Moor: 83 rooms at (1064, 1120)
Cold Plains: 97 rooms at (984, 1080)
...
```

Generation is deterministic: the same seed always gives the same world, matching the retail
engine cell for cell.

## Collision

Grids are large, so they are only copied out when asked for:

```csharp
var act = drlg.GenerateAct(1337, includeCollision: true);
var coldPlains = act.GetLevel(3)!;
var grid = coldPlains.Collision!;

if (grid.IsWalkable(x: 120, y: 200))
    Console.WriteLine("you can stand there");
```

## Lifetime

`MapGenerator` holds the game tables and is `IDisposable`. Everything it returns is plain
managed data with no native memory behind it, so an `Act` needs no disposing and is collected
like any other object.

Not thread-safe. Give each thread its own `MapGenerator`.

---

Runs on .NET Framework 4.6.1+, .NET Core 2.0+, .NET 5-10, Mono and Unity, on Windows,
Linux (glibc and musl), macOS and FreeBSD, across x86, x64, arm, arm64 and riscv64.

Part of [libd2](https://github.com/jaenster/libd2). MIT licensed. Not affiliated with or
endorsed by Blizzard Entertainment.
