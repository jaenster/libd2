using System;
using System.Collections.Generic;
using System.Text;

namespace LibD2.Drlg;

/// <summary>Thrown when generation fails.</summary>
public sealed class DrlgException : Exception
{
    /// <summary>Creates the exception with a message describing what failed.</summary>
    public DrlgException(string message) : base(message) { }
}

/// <summary>
/// Generates Diablo II 1.14d worlds from a seed.
/// </summary>
/// <example>
/// <code>
/// using var drlg = new MapGenerator();
/// var act = drlg.GenerateAct(seed: 1337, act: 0);   // 0 is Act I, 4 is Act V
/// foreach (var level in act.Levels)
///     Console.WriteLine($"{level.Name}: {level.Rooms.Count} rooms");
/// </code>
/// </example>
/// <remarks>
/// This is the only type here that owns anything native: it holds the loaded game tables, which
/// are the expensive part, so keep one around rather than creating one per call. Everything it
/// returns is ordinary managed data with no native lifetime attached. Not thread-safe: give each
/// thread its own.
/// </remarks>
public sealed class MapGenerator : IDisposable
{
    private IntPtr _ctx;

    /// <summary>Loads the game tables. Dispose it when you are done with them.</summary>
    public MapGenerator()
    {
        var abi = Native.d2drlg_abi_version();
        if (abi != Native.ExpectedAbi)
            throw new DrlgException(
                $"native d2drlg reports ABI {abi}, this package expects {Native.ExpectedAbi}. " +
                "The native library and the package version have to match.");

        _ctx = Native.d2drlg_ctx_create();
        if (_ctx == IntPtr.Zero) throw new DrlgException("could not load the game tables");
    }

    /// <summary>The native ABI version in use.</summary>
    public static uint AbiVersion => Native.d2drlg_abi_version();

    /// <summary>
    /// Generate every level of one act.
    /// </summary>
    /// <param name="seed">The game seed. The same seed always produces the same world.</param>
    /// <param name="difficulty">Nine levels change size with this.</param>
    /// <param name="act">0 for Act I through 4 for Act V, the way the engine numbers them.</param>
    /// <param name="includeCollision">
    /// Also copy every level's subtile collision grid. Off by default because a whole act is
    /// tens of megabytes; when it is off, <see cref="Level.Collision"/> is null.
    /// </param>
    /// <remarks>
    /// The returned <see cref="Act"/> is a plain managed object. Everything is copied out here and
    /// the native handle is released before this returns, so there is nothing to dispose and
    /// nothing that can be used after free.
    /// </remarks>
    public Act GenerateAct(uint seed, Difficulty difficulty = Difficulty.Normal, int act = 0,
                           bool includeCollision = false)
    {
        ThrowIfDisposed();
        if (act is < 0 or > 4)
            throw new ArgumentOutOfRangeException(nameof(act), act, "act is 0 (Act I) to 4 (Act V)");

        var handle = Native.d2drlg_gen_act(_ctx, seed, (int)difficulty, act);
        if (handle == IntPtr.Zero)
            throw new DrlgException($"generating act {act + 1} for seed {seed} failed");

        try
        {
            return new Act(seed, difficulty, act, ReadLevels(handle, includeCollision));
        }
        finally
        {
            Native.d2drlg_act_free(handle);
        }
    }

    private IReadOnlyList<Level> ReadLevels(IntPtr act, bool includeCollision)
    {
        var count = Native.d2drlg_act_level_count(act);
        if (count < 0) throw new DrlgException("reading the act's level count failed");

        var levels = new List<Level>(count);
        for (var i = 0; i < count; i++)
        {
            var id = Native.d2drlg_act_level_id(act, i);
            Native.d2drlg_act_level_origin(act, i, out var ox, out var oy);
            Native.d2drlg_act_level_size(act, i, out var w, out var h);

            var index = i;
            levels.Add(new Level(
                id,
                ReadString((buf, cap) => Native.d2drlg_level_name(_ctx, id, buf, cap)),
                (DrlgType)Native.d2drlg_act_level_drlg_type(act, i),
                Native.d2drlg_act_level_placed(act, i) == 1,
                ox, oy, w, h,
                Read<Room>((b, c) => Native.d2drlg_act_rooms(act, index, b, c)),
                Read<PresetUnit>((b, c) => Native.d2drlg_act_level_presets(act, index, b, c)),
                Read<Adjacent>((b, c) => Native.d2drlg_act_level_adjacents(act, index, b, c)),
                includeCollision ? ReadCollision(act, index) : null));
        }
        return levels;
    }

    /// <summary>
    /// Ask for the count first, then the data. Every list-returning entry point reports the FULL
    /// count even when it wrote nothing, which is what makes a zero-capacity probe safe.
    /// </summary>
    private static IReadOnlyList<T> Read<T>(Func<T[], int, int> call) where T : struct
    {
        var n = call(Array.Empty<T>(), 0);
        if (n <= 0) return Array.Empty<T>();
        var buf = new T[n];
        return call(buf, n) == n ? buf : Array.Empty<T>();
    }

    private static CollisionGrid ReadCollision(IntPtr act, int levelIndex)
    {
        var n = Native.d2drlg_act_level_collision(act, levelIndex, Array.Empty<ushort>(), 0, out var w, out var h);
        if (n <= 0) return new CollisionGrid(Array.Empty<ushort>(), 0, 0);
        var cells = new ushort[n];
        Native.d2drlg_act_level_collision(act, levelIndex, cells, n, out w, out h);
        return new CollisionGrid(cells, w, h);
    }

    /// <summary>The seeded outdoor shrines and wells of one level.</summary>
    /// <remarks>This regenerates the act internally. Prefer <see cref="GenerateAct"/> when you
    /// need more than one thing from the same world.</remarks>
    public IReadOnlyList<Shrine> GetShrines(uint seed, int levelId, Difficulty difficulty = Difficulty.Normal)
    {
        ThrowIfDisposed();
        var n = Native.d2drlg_level_shrines(_ctx, seed, (int)difficulty, levelId, Array.Empty<Shrine>(), 0);
        if (n < 0) throw new DrlgException($"reading shrines of level {levelId} failed");
        if (n == 0) return Array.Empty<Shrine>();

        var buf = new Shrine[n];
        Native.d2drlg_level_shrines(_ctx, seed, (int)difficulty, levelId, buf, n);
        return buf;
    }

    /// <summary>The in-game name of a level id, or an empty string if unknown.</summary>
    public string GetLevelName(int levelId)
    {
        ThrowIfDisposed();
        return ReadString((buf, cap) => Native.d2drlg_level_name(_ctx, levelId, buf, cap));
    }

    /// <summary>The Objects.txt name of an object id, or an empty string if unknown.</summary>
    public static string ObjectName(int txtFileNo) =>
        ReadString((buf, cap) => Native.d2drlg_object_name(txtFileNo, buf, cap));

    private static string ReadString(Func<byte[], int, int> call)
    {
        var n = call(Array.Empty<byte>(), 0);
        if (n <= 0) return string.Empty;
        var buf = new byte[n + 1];
        var got = call(buf, buf.Length);
        return got <= 0 ? string.Empty : Encoding.UTF8.GetString(buf, 0, Math.Min(got, buf.Length));
    }

    private void ThrowIfDisposed()
    {
        if (_ctx == IntPtr.Zero) throw new ObjectDisposedException(nameof(MapGenerator));
    }

    /// <summary>Releases the game tables.</summary>
    public void Dispose()
    {
        if (_ctx == IntPtr.Zero) return;
        Native.d2drlg_ctx_destroy(_ctx);
        _ctx = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }

    /// <summary>Releases the game tables if <see cref="Dispose"/> was never called.</summary>
    ~MapGenerator() => Dispose();
}

/// <summary>
/// One generated act: every level, with its rooms, presets and adjacency.
/// </summary>
/// <remarks>
/// Ordinary managed data. It holds no native memory, so it needs no disposing and the garbage
/// collector reclaims it like anything else.
/// </remarks>
public sealed class Act
{
    internal Act(uint seed, Difficulty difficulty, int number, IReadOnlyList<Level> levels)
    {
        Seed = seed;
        Difficulty = difficulty;
        Number = number;
        Levels = levels;
    }

    /// <summary>The seed this act was generated from.</summary>
    public uint Seed { get; }

    /// <summary>The difficulty it was generated at.</summary>
    public Difficulty Difficulty { get; }

    /// <summary>
    /// 0 for Act I through 4 for Act V, the same value you passed to
    /// <see cref="MapGenerator.GenerateAct"/>. Note that <see cref="ToString"/> renders it the
    /// way people say it, so this is 0 where that prints "Act 1".
    /// </summary>
    public int Number { get; }

    /// <summary>Every level of the act.</summary>
    public IReadOnlyList<Level> Levels { get; }

    /// <summary>The level with this Levels.txt id, or null if the act has no such level.</summary>
    public Level? GetLevel(int levelId)
    {
        foreach (var l in Levels)
            if (l.Id == levelId) return l;
        return null;
    }

    /// <inheritdoc/>
    public override string ToString() => $"Act {Number + 1} of seed {Seed} ({Levels.Count} levels)";
}
