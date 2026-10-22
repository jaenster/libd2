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
public sealed unsafe class ItemDrawer : IDisposable
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
        var rc = Native.d2itemdraw_add_archive(_ctx, (byte*)p, len);
        if (rc != 0) throw new ItemDrawException($"not an MPQ ({rc})");
    }

    /// <summary>Adds one file under its game path ("data/global/items/invamu1.dc6"); it wins over the archives.</summary>
    public void AddFile(string name, byte[] data)
    {
        ThrowIfDisposed();
        int rc;
        fixed (byte* d = data) rc = Native.d2itemdraw_add_file(_ctx, name, d, (UIntPtr)data.Length);
        if (rc != 0) throw new ItemDrawException($"adding {name} failed ({rc})");
    }

    private static D2ItemDrawOptions OptionsOf(Viewer? viewer, int act) => viewer is null
        ? new D2ItemDrawOptions { level = 99, act = act }
        : new D2ItemDrawOptions
        {
            has_viewer = 1,
            class_id = viewer.ClassId,
            level = viewer.Level,
            strength = viewer.Strength,
            dexterity = viewer.Dexterity,
            act = act,
        };

    /// <summary>The item's tooltip text.</summary>
    public string Text(byte[] records, Viewer? viewer = null, TextMode mode = TextMode.Plain)
    {
        ThrowIfDisposed();
        var o = OptionsOf(viewer, 1);
        fixed (byte* r = records)
        {
            var n = Native.d2itemdraw_text(_ctx, r, (UIntPtr)records.Length, &o, (int)mode, null, UIntPtr.Zero);
            if (n < 0) throw new ItemDrawException($"the records do not describe an item ({n})");
            var buf = new byte[n];
            fixed (byte* b = buf) Native.d2itemdraw_text(_ctx, r, (UIntPtr)records.Length, &o, (int)mode, b, (UIntPtr)n);
            return Encoding.UTF8.GetString(buf);
        }
    }

    /// <summary>The description as alt text: top to bottom, no colours, whole lines up to
    /// <paramref name="limit"/> bytes (0: 1024, Discord's cap).</summary>
    public string AltText(byte[] records, Viewer? viewer = null, int limit = 0)
    {
        ThrowIfDisposed();
        var o = OptionsOf(viewer, 1);
        var buf = new byte[4096];
        int n;
        fixed (byte* r = records)
        fixed (byte* b = buf)
            n = Native.d2itemdraw_alt_text(_ctx, r, (UIntPtr)records.Length, &o, limit, b, (UIntPtr)buf.Length);
        if (n < 0) throw new ItemDrawException($"the records do not describe an item ({n})");
        return Encoding.UTF8.GetString(buf, 0, Math.Min(n, buf.Length));
    }

    /// <summary>The grid icon; with sockets, the sockets and their fillers as for the hovered item.</summary>
    public ItemImage Icon(byte[] records, Background background = Background.None, bool sockets = false, int act = 1)
    {
        ThrowIfDisposed();
        var o = OptionsOf(null, act);
        fixed (byte* r = records)
            return Take(Native.d2itemdraw_icon(_ctx, r, (UIntPtr)records.Length, &o, (int)background, sockets ? 1 : 0), "icon");
    }

    /// <summary>The hover box alone.</summary>
    public ItemImage Tooltip(byte[] records, Viewer? viewer = null, int act = 1)
    {
        ThrowIfDisposed();
        var o = OptionsOf(viewer, act);
        fixed (byte* r = records)
            return Take(Native.d2itemdraw_tooltip(_ctx, r, (UIntPtr)records.Length, &o), "tooltip");
    }

    /// <summary>The item as on hover: cells tinted, icon with sockets, the tooltip above.</summary>
    public ItemImage Card(byte[] records, Viewer? viewer = null, int act = 1)
    {
        ThrowIfDisposed();
        var o = OptionsOf(viewer, act);
        fixed (byte* r = records)
            return Take(Native.d2itemdraw_card(_ctx, r, (UIntPtr)records.Length, &o), "card");
    }

    /// <summary>The display list: the box, each line's colour runs and glyph cells, the icon and
    /// socket frames, in the game's pixels. Dispose it when done.</summary>
    public ItemLayout Layout(byte[] records, LayoutKind kind, Viewer? viewer = null, Background background = Background.None, bool sockets = false, int act = 1)
    {
        ThrowIfDisposed();
        var o = OptionsOf(viewer, act);
        IntPtr h;
        fixed (byte* r = records)
            h = Native.d2itemdraw_layout(_ctx, r, (UIntPtr)records.Length, &o, (int)kind, (int)background, sockets ? 1 : 0);
        if (h == IntPtr.Zero) throw new ItemDrawException("could not lay out the item");
        return new ItemLayout(h);
    }

    /// <summary>Draws a layout at <paramref name="scale"/> (1 is the game's size). A provider that is
    /// null, or returns false for a tile, leaves it to libd2's own 1.14d art from the archives.</summary>
    public ItemImage Rasterize(ItemLayout layout, GlyphProvider? glyph = null, SpriteProvider? sprite = null, int scale = 1)
    {
        ThrowIfDisposed();
        GlyphFn? gfn = null;
        SpriteFn? sfn = null;
        Exception? thrown = null;
        if (glyph != null)
            gfn = (_, g, sc, w, h, px) =>
            {
                try
                {
                    var r = new GlyphRef(Utf8(g->font), (int)g->code, (int)g->frame, (int)g->color,
                        ((g->rgb >> 16) & 0xff, (g->rgb >> 8) & 0xff, g->rgb & 0xff), RectOf(g->cell));
                    return glyph.DrawGlyph(r, (int)sc, new Tile((int)w, (int)h, px)) ? 1 : 0;
                }
                catch (Exception e) { thrown ??= e; return 0; }
            };
        if (sprite != null)
            sfn = (_, s, sc, w, h, px) =>
            {
                try
                {
                    var r = new SpriteRef(Utf8(s->path), (int)s->frame,
                        s->colormap_set < 0 ? null : (s->colormap_set, s->colormap_row), s->role, s->ethereal != 0, RectOf(s->rect));
                    return sprite.DrawSprite(r, (int)sc, new Tile((int)w, (int)h, px)) ? 1 : 0;
                }
                catch (Exception e) { thrown ??= e; return 0; }
            };
        var prov = new D2ItemDrawProviders
        {
            glyph = gfn == null ? IntPtr.Zero : Marshal.GetFunctionPointerForDelegate(gfn),
            sprite = sfn == null ? IntPtr.Zero : Marshal.GetFunctionPointerForDelegate(sfn),
            glyph_pad = (uint)(glyph?.Pad ?? 0),
        };
        var img = Native.d2itemdraw_rasterize(_ctx, layout.Handle, &prov, (uint)Math.Max(scale, 1));
        GC.KeepAlive(gfn);
        GC.KeepAlive(sfn);
        if (thrown != null)
        {
            if (img != IntPtr.Zero) Native.d2itemdraw_image_free(img);
            throw new ItemDrawException("a provider threw: " + thrown.Message);
        }
        return Take(img, "layout");
    }

    private static Rect RectOf(D2ItemDrawRect r) => new(r.x, r.y, r.w, r.h);

    private static string Utf8(IntPtr p)
    {
        if (p == IntPtr.Zero) return "";
        var b = (byte*)p;
        var n = 0;
        while (b[n] != 0) n++;
        return Encoding.UTF8.GetString(b, n);
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int GlyphFn(IntPtr user, D2ItemDrawGlyphRef* glyph, uint scale, uint w, uint h, byte* rgba);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int SpriteFn(IntPtr user, D2ItemDrawSpriteRef* sprite, uint scale, uint w, uint h, byte* rgba);

    private static ItemImage Take(IntPtr img, string what)
    {
        if (img == IntPtr.Zero) throw new ItemDrawException($"could not draw the {what} (records or art missing)");
        try
        {
            var w = (int)Native.d2itemdraw_image_width(img);
            var h = (int)Native.d2itemdraw_image_height(img);
            var rgba = new byte[w * h * 4];
            Marshal.Copy(Native.d2itemdraw_image_rgba(img), rgba, 0, rgba.Length);
            UIntPtr len;
            var p = Native.d2itemdraw_image_png(img, &len);
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
        foreach (var (ptr, len) in _archives) Native.d2itemdraw_free((byte*)ptr, len);
        _archives.Clear();
        GC.SuppressFinalize(this);
    }
}

/// <summary>What a layout covers.</summary>
public enum LayoutKind
{
    /// <summary>The grid icon.</summary>
    Icon = Native.D2ITEMDRAW_KIND_ICON,
    /// <summary>The tooltip box.</summary>
    Tooltip = Native.D2ITEMDRAW_KIND_TOOLTIP,
    /// <summary>Both, as on hover.</summary>
    Card = Native.D2ITEMDRAW_KIND_CARD,
}

/// <summary>A rectangle in layout pixels.</summary>
public readonly record struct Rect(int X, int Y, int W, int H);

/// <summary>One glyph to paint: the Font16 frame the game draws, its colour id and nominal RGB, its cell.</summary>
public readonly record struct GlyphRef(string Font, int Code, int Frame, int Color, (uint R, uint G, uint B) Rgb, Rect Cell);

/// <summary>One inventory frame to paint: the DC6, the frame, the item colour map (InvTrans file, row) if any,
/// its role (0 item, 1 socket, 2 socketed filler), ethereal, its rectangle.</summary>
public readonly record struct SpriteRef(string Path, int Frame, (int File, int Row)? ColorMap, int Role, bool Ethereal, Rect Rect);

/// <summary>The buffer a provider paints: W*H*4 bytes of straight-alpha RGBA, zeroed, valid only during the call.</summary>
public readonly unsafe ref struct Tile
{
    /// <summary>Width in pixels.</summary>
    public int W { get; }
    /// <summary>Height in pixels.</summary>
    public int H { get; }
    /// <summary>The pixels.</summary>
    public Span<byte> Rgba { get; }

    internal Tile(int w, int h, byte* px)
    {
        W = w;
        H = h;
        Rgba = new Span<byte>(px, w * h * 4);
    }
}

/// <summary>Paints glyphs in place of libd2's 1.14d font.</summary>
public abstract class GlyphProvider
{
    /// <summary>Pixels the tile extends past the glyph cell on each side.</summary>
    public virtual int Pad => 0;
    /// <summary>Paint the glyph into the tile (the cell at the scale, plus Pad on every side); false declines it.</summary>
    public abstract bool DrawGlyph(GlyphRef glyph, int scale, Tile tile);
}

/// <summary>Paints inventory frames in place of libd2's 1.14d art.</summary>
public abstract class SpriteProvider
{
    /// <summary>Paint the frame opaque into the tile (its rectangle at the scale); false declines it.</summary>
    public abstract bool DrawSprite(SpriteRef sprite, int scale, Tile tile);
}

/// <summary>A display list. Dispose it when done.</summary>
public sealed unsafe class ItemLayout : IDisposable
{
    internal IntPtr Handle { get; private set; }

    /// <summary>Width in layout pixels.</summary>
    public int Width { get; }
    /// <summary>Height in layout pixels.</summary>
    public int Height { get; }
    /// <summary>The whole list as JSON.</summary>
    public string Json { get; }

    internal ItemLayout(IntPtr h)
    {
        Handle = h;
        Width = Native.d2itemdraw_layout_width(h);
        Height = Native.d2itemdraw_layout_height(h);
        UIntPtr len;
        var p = Native.d2itemdraw_layout_json(h, &len);
        Json = Encoding.UTF8.GetString((byte*)p, (int)len);
    }

    /// <summary>The lines as plain text, whole lines up to <paramref name="limit"/> bytes (0: 1024).</summary>
    public string Text(int limit = 0)
    {
        var buf = new byte[4096];
        int n;
        fixed (byte* b = buf) n = Native.d2itemdraw_layout_text(Handle, limit, b, (UIntPtr)buf.Length);
        return Encoding.UTF8.GetString(buf, 0, Math.Max(0, Math.Min(n, buf.Length)));
    }

    /// <summary>Frees the native list.</summary>
    public void Dispose()
    {
        if (Handle != IntPtr.Zero) Native.d2itemdraw_layout_free(Handle);
        Handle = IntPtr.Zero;
    }
}
