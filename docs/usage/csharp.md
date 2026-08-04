# libd2 from C#

```sh
dotnet add package LibD2.Drlg
```

That is the whole setup. The package carries the native library for every platform under
`runtimes/{rid}/native/`, so the .NET host loads the right one and there is nothing to copy
next to your executable and nothing to put on the loader path.

## Generate a map from a seed

```csharp
using LibD2.Drlg;

using var drlg = new MapGenerator();
var act = drlg.GenerateAct(seed: 1337);

Console.WriteLine(act);                       // Act 1 of seed 1337 (39 levels)
foreach (var level in act.Levels.Take(3))
    Console.WriteLine($"  {level}  type={level.Type} size={level.Width}x{level.Height}");
```

```
Act 1 of seed 1337 (39 levels)
  Rogue Encampment (level 1, 35 rooms)  type=Preset size=56x40
  Blood Moor (level 2, 83 rooms)  type=Wilderness size=96x56
  Cold Plains (level 3, 97 rooms)  type=Wilderness size=80x80
```

Rooms, preset units and adjacency come back as ordinary collections of `readonly record
struct`, so they print, deconstruct and compare like any other .NET value:

```csharp
var coldPlains = act.GetLevel(3)!;
Console.WriteLine(coldPlains.Rooms[0]);
// Room { X = 1056, Y = 1152, Width = 8, Height = 8, Type = 0, PresetType = 2, PickedFile = 0 }

foreach (var unit in coldPlains.Presets.Where(u => u.Kind == PresetKind.Object))
    Console.WriteLine($"{MapGenerator.ObjectName(unit.TxtFileNo)} at ({unit.X}, {unit.Y})");
```

## Shrines

```csharp
foreach (var s in drlg.GetShrines(1337, levelId: 3))
    Console.WriteLine($"{(s.IsWell ? "well" : "shrine")} {s.Name} at ({s.X}, {s.Y})");
```

```
shrine Shrine at (4977, 5622)
shrine Shrine at (4972, 5572)
shrine Shrine at (5252, 5492)
well Well at (5052, 5457)
shrine Shrine at (5012, 5452)
```

## Collision

A whole act of collision grids is tens of megabytes, so it is only copied out when asked for.
Until then `Level.Collision` is null:

```csharp
var act = drlg.GenerateAct(1337, includeCollision: true);
var grid = act.GetLevel(3)!.Collision!;

Console.WriteLine($"{grid.Width}x{grid.Height}");            // 400x400
Console.WriteLine(grid.IsWalkable(200, 200));                // True
Console.WriteLine((grid[200, 200] & Collision.Wall) != 0);   // raw engine flags
```

## Lifetime

`MapGenerator` holds the loaded game tables and is the only thing that owns anything native.
Dispose it when you are done.

Everything it returns is plain managed data: the native handle is released before `GenerateAct`
returns, so an `Act` cannot outlive anything, needs no disposing, and is collected like any
other object.

`MapGenerator` is not thread-safe. Give each thread its own.

## Without NuGet

If you cannot take the package, the shared library and header are attached to each GitHub
Release and the C ABI is stable and documented — see the
[API reference](c.md#reference-the-drlg-c-api). Declare the entry points with `DllImport` and
mirror the structs with `[StructLayout(LayoutKind.Sequential)]`; every list-returning function
reports the full count when called with a zero capacity, so ask for the size first and then
allocate:

```csharp
[DllImport("d2drlg", CallingConvention = CallingConvention.Cdecl)]
static extern int d2drlg_level_shrines(IntPtr ctx, uint seed, int difficulty,
                                       int levelId, [Out] Shrine[] outShrines, int cap);
```
