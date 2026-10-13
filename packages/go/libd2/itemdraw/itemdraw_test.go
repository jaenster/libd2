package itemdraw

import (
	"os"
	"path/filepath"
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
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	items, _ := filepath.Glob("testdata/*.items")
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
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	records, err := os.ReadFile("testdata/thunderstroke.items")
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
	records, err := os.ReadFile("testdata/thunderstroke.items")
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
