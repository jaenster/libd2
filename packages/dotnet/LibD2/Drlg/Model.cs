using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LibD2.Drlg;

/// <summary>Which difficulty a world is generated for. Nine levels change size with it.</summary>
public enum Difficulty
{
    /// <summary>Normal.</summary>
    Normal = 0,
    /// <summary>Nightmare.</summary>
    Nightmare = 1,
    /// <summary>Hell.</summary>
    Hell = 2,
}

/// <summary>How a level is laid out.</summary>
public enum DrlgType
{
    /// <summary>Built from maze tiles (the Catacombs, the Durance).</summary>
    Maze = 1,
    /// <summary>A hand-authored preset area (towns, the Cathedral).</summary>
    Preset = 2,
    /// <summary>Open outdoor ground (Cold Plains, the Jungle).</summary>
    Wilderness = 3,
}

/// <summary>What a preset unit is.</summary>
public enum PresetKind
{
    /// <summary>A monster, identified by its MonStats id.</summary>
    Monster = 1,
    /// <summary>An object, identified by its Objects.txt row.</summary>
    Object = 2,
    /// <summary>A warp out of the level, identified by its warp id.</summary>
    Exit = 5,
}

/// <summary>
/// One generated room, as a world rectangle in TILES. Multiply by 5 for the subtile frame
/// that in-game coordinates use.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public readonly record struct Room(
    int X,
    int Y,
    int Width,
    int Height,
    int Type,
    int PresetType,
    int PickedFile);

/// <summary>A seeded outdoor shrine or well, at world SUBTILE coordinates.</summary>
[StructLayout(LayoutKind.Sequential)]
public readonly record struct Shrine(int ClassId, int X, int Y)
{
    /// <summary>True for a well rather than a shrine.</summary>
    public bool IsWell => ClassId == 130;

    /// <summary>The Objects.txt name, for example <c>Waypoint</c> or <c>shrine</c>.</summary>
    public string Name => MapGenerator.ObjectName(ClassId);
}

/// <summary>
/// A monster, object or exit the level's preset data places, at LEVEL-LOCAL subtile
/// coordinates. <see cref="TxtFileNo"/> is a MonStats id, an Objects.txt row or a warp id
/// depending on <see cref="Kind"/>.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public readonly record struct PresetUnit(PresetKind Kind, int TxtFileNo, int X, int Y);

/// <summary>
/// A place you can cross into another level, at LEVEL-LOCAL subtile coordinates.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
public readonly record struct Adjacent(int DestinationLevelId, int X, int Y);

/// <summary>
/// A level's subtile collision, one cell per subtile, row-major from the level's top-left.
/// Index it with <c>grid[x, y]</c>.
/// </summary>
public sealed class CollisionGrid
{
    private readonly ushort[] _cells;

    internal CollisionGrid(ushort[] cells, int width, int height)
    {
        _cells = cells;
        Width = width;
        Height = height;
    }

    /// <summary>Width in subtiles.</summary>
    public int Width { get; }
    /// <summary>Height in subtiles.</summary>
    public int Height { get; }

    /// <summary>The raw engine collision flags at a subtile. See <see cref="Collision"/>.</summary>
    public ushort this[int x, int y] =>
        (uint)x < (uint)Width && (uint)y < (uint)Height ? _cells[y * Width + x] : Collision.Void;

    /// <summary>True where a walking player fits.</summary>
    public bool IsWalkable(int x, int y) => (this[x, y] & Collision.PlayerPath) == 0;

    /// <summary>Every cell, row-major.</summary>
    public ReadOnlySpan<ushort> Cells => _cells;
}

/// <summary>The engine's collision bits and the masks built from them.</summary>
public static class Collision
{
    /// <summary>Blocks movement outright.</summary>
    public const ushort Wall = 0x0001;
    /// <summary>Line of sight passes, movement does not.</summary>
    public const ushort Visible = 0x0002;
    /// <summary>Stops a missile but not a walking player.</summary>
    public const ushort MissileBarrier = 0x0004;
    /// <summary>Players may not stand here.</summary>
    public const ushort NoPlayer = 0x0008;
    /// <summary>Placed by the level preset rather than the tile art.</summary>
    public const ushort Preset = 0x0010;
    /// <summary>No floor tile covers this cell.</summary>
    public const ushort NoFloor = 0x0020;

    /// <summary>Cells no room covers.</summary>
    public const ushort Void = 0xFFFF;

    /// <summary>What blocks a walking player.</summary>
    public const ushort PlayerPath = 0x1C09;

    /// <summary>What blocks a missile in flight.</summary>
    public const ushort MissileFlight = 0x0005;
}

/// <summary>One level of a generated act.</summary>
public sealed class Level
{
    internal Level(int id, string name, DrlgType type, bool placed,
                   int originX, int originY, int width, int height,
                   IReadOnlyList<Room> rooms, IReadOnlyList<PresetUnit> presets,
                   IReadOnlyList<Adjacent> adjacents, CollisionGrid? collision)
    {
        Id = id;
        Name = name;
        Type = type;
        IsPlaced = placed;
        OriginX = originX;
        OriginY = originY;
        Width = width;
        Height = height;
        Rooms = rooms;
        Presets = presets;
        Adjacents = adjacents;
        Collision = collision;
    }

    /// <summary>The Levels.txt id, stable across seeds.</summary>
    public int Id { get; }

    /// <summary>The in-game name, for example <c>Cold Plains</c>.</summary>
    public string Name { get; }

    /// <summary>How the level is laid out.</summary>
    public DrlgType Type { get; }

    /// <summary>True when the act's placement graph positioned it on the surface.</summary>
    public bool IsPlaced { get; }

    /// <summary>World origin in TILES.</summary>
    public int OriginX { get; }
    /// <inheritdoc cref="OriginX"/>
    public int OriginY { get; }

    /// <summary>Size in TILES. Multiply by 5 for subtiles.</summary>
    public int Width { get; }
    /// <inheritdoc cref="Width"/>
    public int Height { get; }

    /// <summary>The rooms the generator placed.</summary>
    public IReadOnlyList<Room> Rooms { get; }
    /// <summary>Monsters, objects and exits the preset data places.</summary>
    public IReadOnlyList<PresetUnit> Presets { get; }

    /// <summary>Where this level touches others.</summary>
    public IReadOnlyList<Adjacent> Adjacents { get; }

    /// <summary>
    /// The seeded outdoor shrines and wells of this level, at world SUBTILE coordinates.
    /// The generator folds every one of them into <see cref="Presets"/> as an object at the same
    /// position, so this is a filter over data the level already carries: it generates nothing.
    /// Only Act I and Act II wilderness levels have any.
    /// </summary>
    public IReadOnlyList<Shrine> Shrines => _shrines ??= FindShrines();

    private IReadOnlyList<Shrine>? _shrines;

    /// <summary>
    /// Presets are level-local subtiles and shrines are world subtiles, so each one moves by the
    /// level's origin, which is in tiles and therefore worth five subtiles apiece.
    /// </summary>
    private IReadOnlyList<Shrine> FindShrines()
    {
        List<Shrine>? found = null;
        foreach (var unit in Presets)
        {
            if (unit.Kind != PresetKind.Object || !IsShrineObject(unit.TxtFileNo)) continue;
            found ??= new List<Shrine>();
            found.Add(new Shrine(unit.TxtFileNo, OriginX * 5 + unit.X, OriginY * 5 + unit.Y));
        }
        return found ?? (IReadOnlyList<Shrine>)Array.Empty<Shrine>();
    }

    /// <summary>The Objects.txt rows the outdoor shrine spawner draws from: four shrines and the well.</summary>
    private static bool IsShrineObject(int txtFileNo) =>
        txtFileNo == 2 || txtFileNo == 81 || txtFileNo == 83 || txtFileNo == 84 || txtFileNo == 130;

    /// <summary>
    /// The subtile collision grid, or null unless the act was generated with
    /// <c>includeCollision: true</c>. A whole act of grids is tens of megabytes, so it is not
    /// copied out unless asked for.
    /// </summary>
    public CollisionGrid? Collision { get; }

    /// <inheritdoc/>
    public override string ToString() => $"{Name} (level {Id}, {Rooms.Count} rooms)";
}
