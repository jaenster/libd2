using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using LibD2.ItemDraw;
using Xunit;

namespace LibD2.Tests;

/// <summary>The item drawing wrapper against the fixtures the Zig side writes through the same C ABI
/// (testdata/itemdraw/bindings at the repository root).</summary>
public class ItemDrawTests
{
    private static readonly string Fixtures = FindFixtures();

    private static string FindFixtures()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
        {
            var p = Path.Combine(d.FullName, "testdata", "itemdraw", "bindings");
            if (Directory.Exists(p)) return p;
        }
        throw new DirectoryNotFoundException("testdata/itemdraw/bindings above " + AppContext.BaseDirectory);
    }

    private static readonly Viewer Sorc = new(1, 80, 100, 50);

    [Fact]
    public void TextAndAltTextMatchTheFixtures()
    {
        using var d = new ItemDrawer();
        var items = Directory.GetFiles(Fixtures, "*.items");
        Assert.Equal(5, items.Length);
        foreach (var path in items)
        {
            var records = File.ReadAllBytes(path);
            var want = File.ReadAllText(Path.ChangeExtension(path, ".txt"));
            Assert.Equal(want, d.Text(records, null, TextMode.Colored));
            Assert.Equal(File.ReadAllText(Path.ChangeExtension(path, ".viewer.txt")), d.Text(records, Sorc, TextMode.Colored));
            Assert.Equal(Regex.Replace(want, @"\{\d+\}", ""), d.AltText(records));
            Assert.True(d.AltText(records, null, 20).Length <= 20);
        }
    }

    private sealed class Boxes : GlyphProvider
    {
        public int Count;

        public override bool DrawGlyph(GlyphRef g, int scale, Tile tile)
        {
            Assert.Equal(g.Cell.W * scale, tile.W);
            Count++;
            for (var i = 0; i < tile.Rgba.Length; i += 4)
            {
                tile.Rgba[i] = (byte)g.Rgb.R;
                tile.Rgba[i + 1] = (byte)g.Rgb.G;
                tile.Rgba[i + 2] = (byte)g.Rgb.B;
                tile.Rgba[i + 3] = 255;
            }
            return true;
        }
    }

    [Fact]
    public void LayoutJsonAndAProviderAtScale2And4()
    {
        var dir = Environment.GetEnvironmentVariable("D2_DIR");
        if (string.IsNullOrEmpty(dir)) return;
        using var d = new ItemDrawer();
        foreach (var m in new[] { "Patch_D2.mpq", "d2exp.mpq", "d2data.mpq" })
            d.AddArchive(File.ReadAllBytes(Path.Combine(dir, m)));
        var records = File.ReadAllBytes(Path.Combine(Fixtures, "griffons-eye.items"));
        using var l = d.Layout(records, LayoutKind.Card);
        Assert.Equal(File.ReadAllText(Path.Combine(Fixtures, "griffons-eye.layout.json")), l.Json);
        Assert.Equal(d.Card(records).Png, d.Rasterize(l).Png);
        foreach (var scale in new[] { 2, 4 })
        {
            var b = new Boxes();
            var img = d.Rasterize(l, b, null, scale);
            Assert.Equal(l.Width * scale, img.Width);
            Assert.True(b.Count > 100);
        }
    }
}
