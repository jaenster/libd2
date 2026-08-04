# libd2 from C#

```sh
dotnet add package LibD2
```

That is the whole setup. The package carries a native build for every platform .NET runs on
under `runtimes/{rid}/native/`, so the host loads the right one: nothing to copy next to your
executable, nothing to put on the loader path, and no game installation.

## Generate a world from a seed

```csharp
using LibD2.Drlg;

// One generator, reused. Loading the game tables is the expensive part.
using var drlg = new MapGenerator();

// act is 0-based: 0 is Act I, 4 is Act V. It defaults to 0.
var act = drlg.GenerateAct(seed: 1337, act: 0);
Console.WriteLine(act);

foreach (var level in act.Levels.Take(3))
    Console.WriteLine($"  {level}  type={level.Type} size={level.Width}x{level.Height}");
```

```
Act 1 of seed 1337 (39 levels)
  Rogue Encampment (level 1, 35 rooms)  type=Preset size=56x40
  Blood Moor (level 2, 83 rooms)  type=Wilderness size=96x56
  Cold Plains (level 3, 97 rooms)  type=Wilderness size=80x80
```

The same seed always gives the same world, matching the retail engine cell for cell.

`act` counts from zero the way the engine does, so Act I is `0` and Act V is `4`. Worth passing
explicitly, and worth knowing that `Act.Number` is that same 0-based value while `ToString()`
renders it the way people say it — so `act.Number` is `0` where the line above prints "Act 1".

## Rooms, objects and monsters

Levels are addressed by their Levels.txt id, which is stable across seeds. Rooms and preset
units are `readonly record struct`, so they print, deconstruct and compare like any .NET value:

```csharp
var coldPlains = act.GetLevel(3)!;
Console.WriteLine(coldPlains.Rooms[0]);
// Room { X = 1056, Y = 1152, Width = 8, Height = 8, Type = 0, PresetType = 2, PickedFile = 0 }

foreach (var group in coldPlains.Presets
             .Where(u => u.Kind == PresetKind.Object)
             .GroupBy(u => MapGenerator.ObjectName(u.TxtFileNo))
             .OrderByDescending(g => g.Count())
             .Take(4))
    Console.WriteLine($"{group.Count()} x {group.Key}");
```

```
15 x fire
9 x Dummy
4 x Shrine
1 x bed
```

`Presets` is what the level's own map data places. Note that some things you might expect are
not in there: a wilderness waypoint is positioned by the generator rather than by preset data,
so it will not appear among a wilderness level's `Presets`.

## Where a level leads

```csharp
var reachable = coldPlains.Adjacents.Select(a => a.DestinationLevelId).Distinct().OrderBy(x => x);
Console.WriteLine(string.Join(", ", reachable));   // 2, 4, 9, 17
```

Each `Adjacent` also carries the level-local subtile position of the crossing, so it doubles as
"walk here to leave".

## Shrines

```csharp
foreach (var s in drlg.GetShrines(1337, levelId: 3))
    Console.WriteLine($"{(s.IsWell ? "well" : "shrine")} at ({s.X}, {s.Y})");
```

```
shrine at (4977, 5622)
shrine at (4972, 5572)
shrine at (5252, 5492)
well at (5052, 5457)
shrine at (5012, 5452)
```

Those are world subtile coordinates; divide by 5 for tiles.

## Collision

A whole act of collision grids is tens of megabytes, so it is only copied out when you ask.
Until then `Level.Collision` is null:

```csharp
var act = drlg.GenerateAct(1337, act: 0, includeCollision: true);
var grid = act.GetLevel(3)!.Collision!;

Console.WriteLine($"{grid.Width}x{grid.Height}");              // 400x400
Console.WriteLine(grid.IsWalkable(200, 200));                  // True
Console.WriteLine((grid[200, 200] & Collision.Wall) != 0);     // raw engine flags
```

`IsWalkable` applies the mask the engine uses for a walking player. The indexer gives you the
raw flags if you want to reason about missiles, line of sight or anything else yourself.

## Lifetime and threading

`MapGenerator` holds the loaded game tables and is the only thing owning anything native, so
dispose it when you are done. Everything it returns is plain managed data — the native handle is
released before `GenerateAct` returns — so an `Act` needs no disposing and is collected like any
other object.

`MapGenerator` is not thread-safe. Give each thread its own.

## Which .NET

The package targets `netstandard2.0`, so it loads on .NET Framework 4.6.1+, .NET Core 2.0+,
.NET 5 through 10, Mono and Unity from the same build.

Platforms covered: Windows x86/x64/arm64, Linux x64/arm64/arm (glibc and musl, so Alpine works),
macOS x64/arm64, FreeBSD x64/arm64, and linux-riscv64.

A RID-specific publish carries only the one binary it needs:

```sh
dotnet publish -r linux-musl-x64   # output contains one native library, ~2.5 MB
```

## Without NuGet

If you cannot take the package, the shared library and header are attached to each GitHub
Release and the C ABI is documented — see the [API reference](c.md#reference-the-drlg-c-api).
Declare the entry points with `DllImport` and mirror the structs with
`[StructLayout(LayoutKind.Sequential)]`. Every list-returning function reports the full count
when called with zero capacity, so ask for the size first, then allocate:

```csharp
[DllImport("d2drlg", CallingConvention = CallingConvention.Cdecl)]
static extern int d2drlg_level_shrines(IntPtr ctx, uint seed, int difficulty,
                                       int levelId, [Out] Shrine[] outShrines, int cap);
```
