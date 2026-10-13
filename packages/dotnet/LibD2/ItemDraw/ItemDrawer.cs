using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace LibD2.ItemDraw;

/// <summary>Thrown when an item cannot be described or drawn.</summary>
public sealed class ItemDrawException : Exception
{
    /// <summary>Creates the exception with a message describing what failed.</summary>
    public ItemDrawException(string message) : base(message) { }
}

/// <summary>Who looks at the item; null everywhere means the neutral character.</summary>
/// <param name="ClassId">0 Amazon, 1 Sorceress, 2 Necromancer, 3 Paladin, 4 Barbarian, 5 Druid, 6 Assassin.</param>
/// <param name="Level">Character level: the level requirement and the per-level stats.</param>
/// <param name="Strength">Strength the strength requirement is checked against.</param>
/// <param name="Dexterity">Dexterity the dexterity requirement is checked against.</param>
public sealed record Viewer(int ClassId, int Level, int Strength, int Dexterity);

/// <summary>The form of <see cref="ItemDrawer.Text"/>.</summary>
public enum TextMode
{
    /// <summary>The game's own string: first line at the bottom, colour codes "ÿcN".</summary>
    Engine = 0,
    /// <summary>Top to bottom, no colours.</summary>
    Plain = 1,
    /// <summary>Top to bottom, each colour run as "{N}text".</summary>
    Colored = 2,
}

/// <summary>The tint the grid draws behind an icon.</summary>
public enum Background
{
    /// <summary>No tint.</summary>
    None = 0,
    /// <summary>Usable (blue).</summary>
    Normal = 1,
    /// <summary>Under the cursor (green).</summary>
    Hovered = 2,
    /// <summary>The character cannot use it (red).</summary>
    Unusable = 3,
    /// <summary>Not identified.</summary>
    Unidentified = 4,
}

/// <summary>A drawn picture: straight-alpha RGBA rows top-down, and the same as a PNG.</summary>
public sealed class ItemImage
{
    internal ItemImage(int width, int height, byte[] rgba, byte[] png)
    {
        Width = width;
        Height = height;
        Rgba = rgba;
        Png = png;
    }

    /// <summary>Width in pixels.</summary>
    public int Width { get; }
    /// <summary>Height in pixels.</summary>
    public int Height { get; }
    /// <summary>Width * Height * 4 bytes.</summary>
    public byte[] Rgba { get; }
    /// <summary>The picture as a PNG file.</summary>
    public byte[] Png { get; }
}

/// <summary>
/// Draws a Diablo II 1.14d item the way the game does: the grid icon, the hover tooltip, and the two
/// together as on hover. The art is yours: add the game's MPQs (Patch_D2, d2exp, d2data, in that
/// order). The text needs no art.
/// </summary>
/// <remarks>Item input is the item's save-form records: its own "JM" record, then those of the items
/// socketed into it. Not thread-safe: give each thread its own.</remarks>
public sealed class ItemDrawer : IDisposable
{
    private IntPtr _ctx;
    private readonly List<(IntPtr Ptr, UIntPtr Len)> _archives = new();

    /// <summary>Loads the tables. Dispose it when you are done.</summary>
    public ItemDrawer()
    {
        var abi = Native.d2itemdraw_abi_version();
        if (abi != Native.ExpectedAbi)
            throw new ItemDrawException(
                $"native d2itemdraw reports ABI {abi}, this package expects {Native.ExpectedAbi}.");
        _ctx = Native.d2itemdraw_create();
        if (_ctx == IntPtr.Zero) throw new ItemDrawException("could not load the tables");
    }

    /// <summary>The native ABI version in use.</summary>
    public static uint AbiVersion => Native.d2itemdraw_abi_version();

    /// <summary>Adds an MPQ, searched after those added before it. Copied into native memory kept until Dispose.</summary>
    public void AddArchive(byte[] mpq)
    {
        ThrowIfDisposed();
        if (mpq.Length == 0) throw new ArgumentException("empty archive", nameof(mpq));
        var len = (UIntPtr)mpq.Length;
        var p = Native.d2itemdraw_alloc(len);
        if (p == IntPtr.Zero) throw new ItemDrawException("out of memory");
        Marshal.Copy(mpq, 0, p, mpq.Length);
        _archives.Add((p, len));
        var rc = Native.d2itemdraw_add_archive(_ctx, p, len);
        if (rc != 0) throw new ItemDrawException($"not an MPQ ({rc})");
    }

    /// <summary>Adds one file under its game path ("data/global/items/invamu1.dc6"); it wins over the archives.</summary>
    public void AddFile(string name, byte[] data)
    {
        ThrowIfDisposed();
        var rc = Native.d2itemdraw_add_file(_ctx, name, data, (UIntPtr)data.Length);
        if (rc != 0) throw new ItemDrawException($"adding {name} failed ({rc})");
    }

    private static Native.Options OptionsOf(Viewer? viewer, int act) => viewer is null
        ? new Native.Options { Level = 99, Act = act }
        : new Native.Options
        {
            HasViewer = 1,
            ClassId = viewer.ClassId,
            Level = viewer.Level,
            Strength = viewer.Strength,
            Dexterity = viewer.Dexterity,
            Act = act,
        };

    /// <summary>The item's tooltip text.</summary>
    public string Text(byte[] records, Viewer? viewer = null, TextMode mode = TextMode.Plain)
    {
        ThrowIfDisposed();
        var o = OptionsOf(viewer, 1);
        var n = Native.d2itemdraw_text(_ctx, records, (UIntPtr)records.Length, ref o, (int)mode, null, UIntPtr.Zero);
        if (n < 0) throw new ItemDrawException($"the records do not describe an item ({n})");
        var buf = new byte[n];
        Native.d2itemdraw_text(_ctx, records, (UIntPtr)records.Length, ref o, (int)mode, buf, (UIntPtr)n);
        return Encoding.UTF8.GetString(buf);
    }

    /// <summary>The grid icon; with sockets, the sockets and their fillers as for the hovered item.</summary>
    public ItemImage Icon(byte[] records, Background background = Background.None, bool sockets = false, int act = 1)
    {
        ThrowIfDisposed();
        var o = OptionsOf(null, act);
        return Take(Native.d2itemdraw_icon(_ctx, records, (UIntPtr)records.Length, ref o, (int)background, sockets ? 1 : 0), "icon");
    }

    /// <summary>The hover box alone.</summary>
    public ItemImage Tooltip(byte[] records, Viewer? viewer = null, int act = 1)
    {
        ThrowIfDisposed();
        var o = OptionsOf(viewer, act);
        return Take(Native.d2itemdraw_tooltip(_ctx, records, (UIntPtr)records.Length, ref o), "tooltip");
    }

    /// <summary>The item as on hover: cells tinted, icon with sockets, the tooltip above.</summary>
    public ItemImage Card(byte[] records, Viewer? viewer = null, int act = 1)
    {
        ThrowIfDisposed();
        var o = OptionsOf(viewer, act);
        return Take(Native.d2itemdraw_card(_ctx, records, (UIntPtr)records.Length, ref o), "card");
    }

    private static ItemImage Take(IntPtr img, string what)
    {
        if (img == IntPtr.Zero) throw new ItemDrawException($"could not draw the {what} (records or art missing)");
        try
        {
            var w = (int)Native.d2itemdraw_image_width(img);
            var h = (int)Native.d2itemdraw_image_height(img);
            var rgba = new byte[w * h * 4];
            Marshal.Copy(Native.d2itemdraw_image_rgba(img), rgba, 0, rgba.Length);
            var p = Native.d2itemdraw_image_png(img, out var len);
            if (p == IntPtr.Zero) throw new ItemDrawException("PNG encoding failed");
            var png = new byte[(int)len];
            Marshal.Copy(p, png, 0, png.Length);
            return new ItemImage(w, h, rgba, png);
        }
        finally
        {
            Native.d2itemdraw_image_free(img);
        }
    }

    private void ThrowIfDisposed()
    {
        if (_ctx == IntPtr.Zero) throw new ObjectDisposedException(nameof(ItemDrawer));
    }

    /// <summary>Releases the native context and the archives.</summary>
    public void Dispose()
    {
        if (_ctx != IntPtr.Zero)
        {
            Native.d2itemdraw_destroy(_ctx);
            _ctx = IntPtr.Zero;
        }
        foreach (var (ptr, len) in _archives) Native.d2itemdraw_free(ptr, len);
        _archives.Clear();
        GC.SuppressFinalize(this);
    }
}
