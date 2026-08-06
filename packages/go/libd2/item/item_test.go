package item

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"unsafe"
)

// Drop is filled by the native side in place, so its layout is the ABI. These are the offsets
// d2item.h defines; get one wrong and every field after it reads the neighbour's bytes.
func TestDropLayout(t *testing.T) {
	if got, want := unsafe.Sizeof(Drop{}), uintptr(52); got != want {
		t.Fatalf("sizeof(Drop) = %d, want %d", got, want)
	}
	for _, c := range []struct {
		field string
		got   uintptr
		want  uintptr
	}{
		{"Kind", unsafe.Offsetof(Drop{}.Kind), 0},
		{"ItemCode", unsafe.Offsetof(Drop{}.ItemCode), 1},
		{"Quality", unsafe.Offsetof(Drop{}.Quality), 5},
		{"PrefixID", unsafe.Offsetof(Drop{}.PrefixID), 6},
		{"SuffixID", unsafe.Offsetof(Drop{}.SuffixID), 8},
		{"RarePrefixIDs", unsafe.Offsetof(Drop{}.RarePrefixIDs), 10},
		{"RareSuffixIDs", unsafe.Offsetof(Drop{}.RareSuffixIDs), 16},
		{"RarePrefixName", unsafe.Offsetof(Drop{}.RarePrefixName), 22},
		{"RareSuffixName", unsafe.Offsetof(Drop{}.RareSuffixName), 24},
		{"UniqueID", unsafe.Offsetof(Drop{}.UniqueID), 26},
		{"SetID", unsafe.Offsetof(Drop{}.SetID), 28},
		{"QualityID", unsafe.Offsetof(Drop{}.QualityID), 30},
		{"LowQualityID", unsafe.Offsetof(Drop{}.LowQualityID), 32},
		{"AutoPrefixID", unsafe.Offsetof(Drop{}.AutoPrefixID), 34},
		{"Sockets", unsafe.Offsetof(Drop{}.Sockets), 36},
		{"Ethereal", unsafe.Offsetof(Drop{}.Ethereal), 37},
		{"Quantity", unsafe.Offsetof(Drop{}.Quantity), 40},
		{"ItemLevel", unsafe.Offsetof(Drop{}.ItemLevel), 44},
		{"ItemSeed", unsafe.Offsetof(Drop{}.ItemSeed), 48},
	} {
		if c.got != c.want {
			t.Errorf("offsetof(Drop.%s) = %d, want %d", c.field, c.got, c.want)
		}
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

// The rolls the golden covers, in the order the Zig CLI produced them.
var goldenRolls = []struct {
	seed uint32
	tc   string
	mlvl int32
	mf   int32
}{
	{1, "Act 1 Equip A", 45, 300},
	{7, "Act 1 Equip A", 45, 300},
	{12345, "Act 1 Equip A", 45, 300},
	{424242, "Act 1 Equip A", 45, 300},
	{1, "Act 5 (H) Super Cx", 87, 800},
	{2, "Act 5 (H) Super Cx", 87, 800},
	{5, "Act 5 (H) Super Cx", 87, 800},
	{6, "Act 5 (H) Super Cx", 87, 800},
	{7, "Act 5 (H) Super Cx", 87, 800},
	{99999, "Act 5 (H) Super Cx", 87, 800},
}

// TestRollsMatchEngine reproduces the Zig CLI's `d2-item <seed> <tc> <mlvl> <mf>` output from
// the Go bindings and requires it byte for byte. The golden came from that CLI, so a field read
// at the wrong offset fails here rather than quietly returning a plausible item.
func TestRollsMatchEngine(t *testing.T) {
	want := readGolden(t, "testdata/rolls.txt")

	c := newContext(t)
	var b strings.Builder
	for _, r := range goldenRolls {
		drops, err := c.Roll(r.seed, r.tc, r.mlvl, r.mf)
		if err != nil {
			t.Fatalf("seed %d %q: %v", r.seed, r.tc, err)
		}
		fmt.Fprintf(&b, "seed=%d tc=%q mlvl=%d mf=%d -> %d drop(s):\n", r.seed, r.tc, r.mlvl, r.mf, len(drops))
		for i, d := range drops {
			b.WriteString(formatDrop(i, d))
		}
	}

	if got := b.String(); got != want {
		t.Errorf("roll mismatch\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// formatDrop is the Zig CLI's line format, reproduced field for field so the comparison is of
// the values and not of two different renderings of them.
func formatDrop(i int, d Drop) string {
	switch d.Kind {
	case Gold:
		return fmt.Sprintf("  [%d] %d gold\n", i, d.Quantity)
	case Item:
		eth := ""
		if d.IsEthereal() {
			eth = " ethereal"
		}
		return fmt.Sprintf("  [%d] %s quality=%s%s pfx=%d sfx=%d rare=%d/%d rare_pfx=%s rare_sfx=%s "+
			"uid=%d sid=%d qid=%d auto=%d sockets=%d qty=%d\n",
			i, d.Code(), d.Quality, eth, d.PrefixID, d.SuffixID, d.RarePrefixName, d.RareSuffixName,
			formatIDs(d.RarePrefixIDs), formatIDs(d.RareSuffixIDs),
			d.UniqueID, d.SetID, d.QualityID, d.AutoPrefixID, d.Sockets, d.Quantity)
	default:
		return fmt.Sprintf("  [%d] %s\n", i, d.Kind)
	}
}

func formatIDs(ids [3]uint16) string {
	return fmt.Sprintf("{ %d, %d, %d }", ids[0], ids[1], ids[2])
}

// The same seed has to produce the same drops every time — that property is the whole point of
// the generator, and it is also what a stale native context or a reused buffer would break.
func TestRollIsDeterministic(t *testing.T) {
	c := newContext(t)
	first, err := c.Roll(5, "Act 5 (H) Super Cx", 87, 800)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) == 0 {
		t.Fatal("seed 5 dropped nothing, which makes this test vacuous")
	}
	for i := 0; i < 3; i++ {
		again, err := c.Roll(5, "Act 5 (H) Super Cx", 87, 800)
		if err != nil {
			t.Fatal(err)
		}
		if len(again) != len(first) {
			t.Fatalf("run %d produced %d drops, first run produced %d", i, len(again), len(first))
		}
		for j := range first {
			if again[j] != first[j] {
				t.Fatalf("run %d drop %d = %+v, first run had %+v", i, j, again[j], first[j])
			}
		}
	}
}

// An unknown treasure class is an empty result, not an error: the tables simply have no such
// row, and the caller finding that out as "nothing dropped" is the engine's own behaviour.
func TestUnknownTreasureClass(t *testing.T) {
	c := newContext(t)
	drops, err := c.Roll(1, "no such treasure class", 45, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(drops) != 0 {
		t.Errorf("got %d drops for an unknown treasure class, want 0", len(drops))
	}
}

func TestLifecycle(t *testing.T) {
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Close(); err != nil {
		t.Fatal(err)
	}
	if err := c.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if _, err := c.Roll(1, "Act 1 Equip A", 45, 0); err != ErrClosed {
		t.Errorf("Roll after Close = %v, want %v", err, ErrClosed)
	}
}

func newContext(t *testing.T) *Context {
	t.Helper()
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func readGolden(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
