package itemdraw

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unsafe"
)

// Options is passed to the native side as a pointer, so its layout is the ABI.
func TestOptionsLayout(t *testing.T) {
	if got, want := unsafe.Sizeof(Options{}), uintptr(24); got != want {
		t.Fatalf("sizeof(Options) = %d, want %d", got, want)
	}
	if got := unsafe.Offsetof(Options{}.Act); got != 20 {
		t.Fatalf("offsetof(Options.Act) = %d, want 20", got)
	}
}

func TestABIVersion(t *testing.T) {
	got, err := ABIVersion()
	if err != nil {
		t.Fatal(err)
	}
	if got != abiVersion {
		t.Fatalf("ABIVersion() = %d, want %d", got, abiVersion)
	}
}

// The fixtures came from the Zig side's own C ABI (packages/itemdraw golden tests); the Go side has
// to reproduce them byte for byte, neutral and as seen by a level 80 sorceress.
func TestTextMatchesEngine(t *testing.T) {
	if fixtures == "" {
		t.Skip("no fixtures")
	}
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	items, _ := filepath.Glob(filepath.Join(fixtures, "*.items"))
	if len(items) == 0 {
		t.Fatal("no fixtures")
	}
	for _, path := range items {
		records, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		base := path[:len(path)-len(".items")]
		for _, v := range []struct {
			suffix string
			opts   *Options
		}{
			{".txt", nil},
			{".viewer.txt", Viewer(1, 80, 100, 50)},
		} {
			want, err := os.ReadFile(base + v.suffix)
			if err != nil {
				t.Fatal(err)
			}
			got, err := c.Text(records, v.opts, Colored)
			if err != nil {
				t.Fatalf("%s: %v", path, err)
			}
			if got != string(want) {
				t.Errorf("%s%s:\n--- got ---\n%s\n--- want ---\n%s", base, v.suffix, got, want)
			}
		}
	}
}

// Without the art the pictures fail with an error, not a crash.
func TestPicturesNeedArt(t *testing.T) {
	if fixtures == "" {
		t.Skip("no fixtures")
	}
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	records, err := os.ReadFile(filepath.Join(fixtures, "thunderstroke.items"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Card(records, nil); err == nil {
		t.Fatal("drawing without any art succeeded")
	}
}

// With the game's archives in $D2_DIR the card draws; skipped otherwise.
func TestCardWithArchives(t *testing.T) {
	dir := os.Getenv("D2_DIR")
	if dir == "" {
		t.Skip("D2_DIR not set")
	}
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for _, m := range []string{"Patch_D2.mpq", "d2exp.mpq", "d2data.mpq"} {
		b, err := os.ReadFile(filepath.Join(dir, m))
		if err != nil {
			t.Fatal(err)
		}
		if err := c.AddArchive(b); err != nil {
			t.Fatal(err)
		}
	}
	records, err := os.ReadFile(filepath.Join(fixtures, "thunderstroke.items"))
	if err != nil {
		t.Fatal(err)
	}
	img, err := c.Card(records, nil)
	if err != nil {
		t.Fatal(err)
	}
	if img.Width < 100 || img.Height < 100 || len(img.RGBA) != img.Width*img.Height*4 || len(img.PNG) < 100 {
		t.Fatalf("card %dx%d, %d RGBA bytes, %d PNG bytes", img.Width, img.Height, len(img.RGBA), len(img.PNG))
	}
}

// The fixtures live once, at the repository root; the Zig tests write them through the same C ABI.
// A copy of this module without the repository (the published mirror) skips the tests that need them.
var fixtures = filepath.Join("..", "..", "..", "..", "testdata", "itemdraw", "bindings")

func init() {
	if _, err := os.Stat(fixtures); err != nil {
		fixtures = ""
	}
}

func stripColors(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '{' {
			if j := strings.IndexByte(s[i:], '}'); j > 0 {
				i += j
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// The alt text is the colour runs' text, capped at 1024 bytes by default.
func TestAltText(t *testing.T) {
	if fixtures == "" {
		t.Skip("no fixtures")
	}
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	items, _ := filepath.Glob(filepath.Join(fixtures, "*.items"))
	for _, path := range items {
		records, _ := os.ReadFile(path)
		want, _ := os.ReadFile(strings.TrimSuffix(path, ".items") + ".txt")
		got, err := c.AltText(records, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		if got != stripColors(string(want)) {
			t.Errorf("%s:\n%s\nwant\n%s", path, got, stripColors(string(want)))
		}
		short, _ := c.AltText(records, nil, 20)
		if len(short) > 20 {
			t.Errorf("%s: a 20-byte limit gave %d bytes", path, len(short))
		}
	}
}

type boxGlyphs struct{ n int }

func (b *boxGlyphs) DrawGlyph(g GlyphRef, scale int, t Tile) bool {
	b.n++
	if t.W != g.Cell.W*scale || t.H != g.Cell.H*scale {
		return false
	}
	for i := 0; i < len(t.RGBA); i += 4 {
		t.RGBA[i], t.RGBA[i+1], t.RGBA[i+2], t.RGBA[i+3] = g.RGB[0], g.RGB[1], g.RGB[2], 255
	}
	return true
}

// With the archives: the layout JSON is the one the Zig side wrote, and a Go glyph provider draws
// into the same layout at scale 2 and 4.
func TestLayoutAndProviders(t *testing.T) {
	dir := os.Getenv("D2_DIR")
	if dir == "" || fixtures == "" {
		t.Skip("D2_DIR not set")
	}
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for _, m := range []string{"Patch_D2.mpq", "d2exp.mpq", "d2data.mpq"} {
		b, err := os.ReadFile(filepath.Join(dir, m))
		if err != nil {
			t.Fatal(err)
		}
		if err := c.AddArchive(b); err != nil {
			t.Fatal(err)
		}
	}
	records, _ := os.ReadFile(filepath.Join(fixtures, "griffons-eye.items"))
	l, err := c.Layout(records, nil, KindCard, NoBackground, false)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	want, _ := os.ReadFile(filepath.Join(fixtures, "griffons-eye.layout.json"))
	if string(l.JSON) != string(want) {
		t.Fatal("the layout JSON differs from the Zig side's")
	}
	for _, scale := range []int{2, 4} {
		b := &boxGlyphs{}
		img, err := c.Rasterize(l, b, 0, nil, scale)
		if err != nil {
			t.Fatal(err)
		}
		if img.Width != l.Width*scale || img.Height != l.Height*scale || b.n < 100 {
			t.Fatalf("scale %d: %dx%d for a %dx%d layout, %d glyphs", scale, img.Width, img.Height, l.Width, l.Height, b.n)
		}
	}
}
