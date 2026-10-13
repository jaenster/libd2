// Package itemdraw draws a Diablo II 1.14d item the way the game draws it: the inventory icon, the
// hover tooltip, and the two together as the game shows them on hover. It also gives the tooltip's
// text on its own.
//
// The art is yours: add the game's MPQs (Patch_D2.mpq, d2exp.mpq, d2data.mpq, in that order) or
// loose files. libd2 ships none of it, and the text needs none of it.
//
//	c, err := itemdraw.New()
//	if err != nil {
//		return err
//	}
//	defer c.Close()
//	for _, mpq := range []string{"Patch_D2.mpq", "d2exp.mpq", "d2data.mpq"} {
//		b, _ := os.ReadFile(mpq)
//		c.AddArchive(b)
//	}
//	card, err := c.Card(records, nil) // records: the item's save-form bytes and its socketed items'
//	png := card.PNG
//
// The native library is bound with purego, so nothing here needs cgo.
//
// Part of libd2: https://github.com/jaenster/libd2. These bindings are generated from that
// repository; issues and pull requests belong there.
package itemdraw

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
)

// ErrClosed is returned by every method of a Context that has been closed.
var ErrClosed = errors.New("libd2/itemdraw: context is closed")

// Options says who looks at the item; nil is the neutral character (every requirement met, no
// class). Its layout is the C ABI's D2ItemDrawOptions.
type Options struct {
	HasViewer int32
	// ClassID: 0 Amazon, 1 Sorceress, 2 Necromancer, 3 Paladin, 4 Barbarian, 5 Druid, 6 Assassin.
	ClassID   int32
	Level     int32
	Strength  int32
	Dexterity int32
	// Act whose palette pictures are drawn in, 1..5 (0 means 1).
	Act int32
}

// Viewer is the Options of a character of that class and level with that strength and dexterity.
func Viewer(class, level, strength, dexterity int32) *Options {
	return &Options{HasViewer: 1, ClassID: class, Level: level, Strength: strength, Dexterity: dexterity, Act: 1}
}

// TextMode picks the form of Text.
type TextMode int32

const (
	// Engine is the game's own string: first line at the bottom, colour codes "ÿcN".
	Engine TextMode = 0
	// Plain is the text top to bottom without colours.
	Plain TextMode = 1
	// Colored is top to bottom with each colour run as "{N}text".
	Colored TextMode = 2
)

// Background is the tint the grid draws behind an icon.
type Background int32

const (
	NoBackground Background = 0
	Normal       Background = 1
	Hovered      Background = 2
	Unusable     Background = 3
	Unidentified Background = 4
)

// Image is a drawn picture: straight-alpha RGBA rows top-down, and the same as a PNG.
type Image struct {
	Width, Height int
	RGBA          []byte
	PNG           []byte
}

// Context holds the tables, the archives you added and the art loaded from them. Calls are
// serialised; give each goroutine its own Context to parallelise.
type Context struct {
	mu    sync.Mutex
	api   *API
	ctx   uintptr
	owned []nativeBuf
}

type nativeBuf struct {
	p uintptr
	n uintptr
}

// New loads the tables. Close it when you are done.
func New() (*Context, error) {
	a, err := Load()
	if err != nil {
		return nil, err
	}
	ctx := a.Create()
	if ctx == 0 {
		return nil, errors.New("libd2/itemdraw: could not load the tables")
	}
	return &Context{api: a, ctx: ctx}, nil
}

// Close releases the context and the archives it holds. It is safe to call more than once.
func (c *Context) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx != 0 {
		c.api.Destroy(c.ctx)
		c.ctx = 0
	}
	for _, b := range c.owned {
		c.api.Free(unsafe.Pointer(b.p), b.n)
	}
	c.owned = nil
	return nil
}

// ABIVersion is the C ABI version of the native library in use.
func ABIVersion() (uint32, error) {
	a, err := Load()
	if err != nil {
		return 0, err
	}
	return a.AbiVersion(), nil
}

// AddArchive adds an MPQ, searched after those added before it. The bytes are copied into native
// memory, which the context keeps until Close.
func (c *Context) AddArchive(mpq []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return ErrClosed
	}
	if len(mpq) == 0 {
		return errors.New("libd2/itemdraw: empty archive")
	}
	p := c.api.Alloc(uintptr(len(mpq)))
	if p == 0 {
		return errors.New("libd2/itemdraw: out of memory")
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(p)), len(mpq)), mpq)
	c.owned = append(c.owned, nativeBuf{p, uintptr(len(mpq))})
	if rc := c.api.AddArchive(c.ctx, unsafe.Pointer(p), uintptr(len(mpq))); rc != 0 {
		return fmt.Errorf("libd2/itemdraw: not an MPQ (%d)", rc)
	}
	return nil
}

// AddFile adds one file under its game path ("data/global/items/invamu1.dc6"). It wins over the
// archives.
func (c *Context) AddFile(name string, data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return ErrClosed
	}
	if len(data) == 0 {
		return errors.New("libd2/itemdraw: empty file")
	}
	rc := c.api.AddFile(c.ctx, name, unsafe.Pointer(&data[0]), uintptr(len(data)))
	runtime.KeepAlive(data)
	if rc != 0 {
		return fmt.Errorf("libd2/itemdraw: adding %s failed (%d)", name, rc)
	}
	return nil
}

func optsPtr(o *Options) unsafe.Pointer {
	if o == nil {
		return nil
	}
	return unsafe.Pointer(o)
}

// Text is the item's tooltip text. records are the item's save-form bytes ("JM" record) followed
// by those of the items socketed into it.
func (c *Context) Text(records []byte, o *Options, mode TextMode) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return "", ErrClosed
	}
	if len(records) == 0 {
		return "", errors.New("libd2/itemdraw: no records")
	}
	n := c.api.Text(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o), int32(mode), nil, 0)
	if n < 0 {
		return "", fmt.Errorf("libd2/itemdraw: the records do not describe an item (%d)", n)
	}
	if n == 0 {
		return "", nil
	}
	buf := make([]byte, n)
	c.api.Text(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o), int32(mode), unsafe.Pointer(&buf[0]), uintptr(n))
	runtime.KeepAlive(records)
	runtime.KeepAlive(o)
	return string(buf), nil
}

func (c *Context) image(img uintptr, what string) (*Image, error) {
	if img == 0 {
		return nil, fmt.Errorf("libd2/itemdraw: could not draw the %s (records or art missing)", what)
	}
	defer c.api.ImageFree(img)
	w := int(c.api.ImageWidth(img))
	h := int(c.api.ImageHeight(img))
	rgba := make([]byte, w*h*4)
	copy(rgba, unsafe.Slice((*byte)(unsafe.Pointer(c.api.ImageRgba(img))), w*h*4))
	var n uintptr
	p := c.api.ImagePng(img, unsafe.Pointer(&n))
	if p == 0 {
		return nil, errors.New("libd2/itemdraw: PNG encoding failed")
	}
	png := make([]byte, n)
	copy(png, unsafe.Slice((*byte)(unsafe.Pointer(p)), n))
	return &Image{Width: w, Height: h, RGBA: rgba, PNG: png}, nil
}

// Icon is the grid icon. With sockets, the sockets and their fillers are drawn as the game does for
// the hovered item.
func (c *Context) Icon(records []byte, o *Options, bg Background, sockets bool) (*Image, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return nil, ErrClosed
	}
	if len(records) == 0 {
		return nil, errors.New("libd2/itemdraw: no records")
	}
	s := int32(0)
	if sockets {
		s = 1
	}
	img := c.api.Icon(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o), int32(bg), s)
	runtime.KeepAlive(records)
	return c.image(img, "icon")
}

// Tooltip is the hover box alone.
func (c *Context) Tooltip(records []byte, o *Options) (*Image, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return nil, ErrClosed
	}
	if len(records) == 0 {
		return nil, errors.New("libd2/itemdraw: no records")
	}
	img := c.api.Tooltip(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o))
	runtime.KeepAlive(records)
	return c.image(img, "tooltip")
}

// Card is the item as on hover: its cells tinted, the icon with its sockets, the tooltip above.
func (c *Context) Card(records []byte, o *Options) (*Image, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return nil, ErrClosed
	}
	if len(records) == 0 {
		return nil, errors.New("libd2/itemdraw: no records")
	}
	img := c.api.Card(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o))
	runtime.KeepAlive(records)
	return c.image(img, "card")
}

// AltText is the item's description top to bottom as plain text, whole lines up to limit bytes (0 or
// less: 1024, what Discord takes as alt text). It needs no art.
func (c *Context) AltText(records []byte, o *Options, limit int) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return "", ErrClosed
	}
	if len(records) == 0 {
		return "", errors.New("libd2/itemdraw: no records")
	}
	buf := make([]byte, 4096)
	n := c.api.AltText(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o), int32(limit), unsafe.Pointer(&buf[0]), uintptr(len(buf)))
	runtime.KeepAlive(records)
	if n < 0 {
		return "", fmt.Errorf("libd2/itemdraw: the records do not describe an item (%d)", n)
	}
	return string(buf[:min(int(n), len(buf))]), nil
}

// Kind picks what a layout covers.
type Kind int32

const (
	KindIcon    Kind = D2ITEMDRAW_KIND_ICON
	KindTooltip Kind = D2ITEMDRAW_KIND_TOOLTIP
	KindCard    Kind = D2ITEMDRAW_KIND_CARD
)

// Layout is a display list: where 1.14d puts every part of the picture, in the game's pixels. JSON is
// the whole list as plain data (the box, each line's spans and glyph cells, the icon and socket
// frames). Close it when done; Rasterize draws it.
type Layout struct {
	c             *Context
	h             uintptr
	Width, Height int
	JSON          []byte
}

// Layout makes the display list of an item. bg and sockets apply to KindIcon.
func (c *Context) Layout(records []byte, o *Options, kind Kind, bg Background, sockets bool) (*Layout, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return nil, ErrClosed
	}
	if len(records) == 0 {
		return nil, errors.New("libd2/itemdraw: no records")
	}
	s := int32(0)
	if sockets {
		s = 1
	}
	h := c.api.Layout(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o), int32(kind), int32(bg), s)
	runtime.KeepAlive(records)
	if h == 0 {
		return nil, errors.New("libd2/itemdraw: no layout (records or the font missing)")
	}
	var n uintptr
	p := c.api.LayoutJson(h, unsafe.Pointer(&n))
	js := make([]byte, n)
	copy(js, unsafe.Slice((*byte)(unsafe.Pointer(p)), n))
	return &Layout{c: c, h: h, Width: int(c.api.LayoutWidth(h)), Height: int(c.api.LayoutHeight(h)), JSON: js}, nil
}

// Text is the layout's lines as plain text, whole lines up to limit bytes (0 or less: 1024).
func (l *Layout) Text(limit int) string {
	buf := make([]byte, 4096)
	n := l.c.api.LayoutText(l.h, int32(limit), unsafe.Pointer(&buf[0]), uintptr(len(buf)))
	if n < 0 {
		return ""
	}
	return string(buf[:min(int(n), len(buf))])
}

// Close frees the layout.
func (l *Layout) Close() {
	if l.h != 0 {
		l.c.api.LayoutFree(l.h)
		l.h = 0
	}
}

// Rect is a rectangle in layout pixels.
type Rect struct{ X, Y, W, H int }

// GlyphRef is one glyph to draw: its Font16 frame, code point, text colour id (0..12) with its
// nominal RGB, and the glyph cell.
type GlyphRef struct {
	Font  string
	Code  rune
	Frame int
	Color int
	RGB   [3]byte
	Cell  Rect
}

// SpriteRef is one inventory frame to draw: the DC6's game path, the frame, the item colour map
// (set -1: none), its role (0 item, 1 socket frame, 2 socketed filler) and its rectangle.
type SpriteRef struct {
	Path                     string
	Frame                    int
	ColormapSet, ColormapRow int
	Role                     int
	Ethereal                 bool
	Rect                     Rect
}

// Tile is the buffer a provider paints: W*H*4 bytes of straight-alpha RGBA, zeroed, valid only during
// the call.
type Tile struct {
	W, H int
	RGBA []byte
}

// GlyphProvider paints a glyph into its cell at the given scale (plus GlyphPad pixels on every side).
// Returning false leaves the glyph to libd2's own 1.14d font.
type GlyphProvider interface {
	DrawGlyph(g GlyphRef, scale int, t Tile) bool
}

// SpriteProvider paints an inventory frame into its rectangle at the given scale. Returning false
// leaves it to libd2's own 1.14d art.
type SpriteProvider interface {
	DrawSprite(s SpriteRef, scale int, t Tile) bool
}

type providers struct {
	glyph  GlyphProvider
	sprite SpriteProvider
}

var (
	cbOnce     sync.Once
	glyphCB    uintptr
	spriteCB   uintptr
	providerMu sync.Mutex
	active     = map[uintptr]providers{}
	nextID     uintptr
)

func cString(p uintptr) string {
	if p == 0 {
		return ""
	}
	n := 0
	for *(*byte)(unsafe.Add(unsafe.Pointer(p), n)) != 0 {
		n++
	}
	return string(unsafe.Slice((*byte)(unsafe.Pointer(p)), n))
}

func lookup(user uintptr) providers {
	providerMu.Lock()
	defer providerMu.Unlock()
	return active[user]
}

func callbacks() {
	cbOnce.Do(func() {
		glyphCB = purego.NewCallback(func(user, ref, scale, w, h, rgba uintptr) uintptr {
			p := lookup(user)
			if p.glyph == nil {
				return 0
			}
			r := (*D2ItemDrawGlyphRef)(unsafe.Pointer(ref))
			g := GlyphRef{
				Font: cString(r.Font), Code: rune(r.Code), Frame: int(r.Frame), Color: int(r.Color),
				RGB:  [3]byte{byte(r.Rgb >> 16), byte(r.Rgb >> 8), byte(r.Rgb)},
				Cell: Rect{int(r.Cell.X), int(r.Cell.Y), int(r.Cell.W), int(r.Cell.H)},
			}
			t := Tile{W: int(uint32(w)), H: int(uint32(h)), RGBA: unsafe.Slice((*byte)(unsafe.Pointer(rgba)), int(uint32(w))*int(uint32(h))*4)}
			if p.glyph.DrawGlyph(g, int(uint32(scale)), t) {
				return 1
			}
			return 0
		})
		spriteCB = purego.NewCallback(func(user, ref, scale, w, h, rgba uintptr) uintptr {
			p := lookup(user)
			if p.sprite == nil {
				return 0
			}
			r := (*D2ItemDrawSpriteRef)(unsafe.Pointer(ref))
			s := SpriteRef{
				Path: cString(r.Path), Frame: int(r.Frame), ColormapSet: int(r.ColormapSet), ColormapRow: int(r.ColormapRow),
				Role: int(r.Role), Ethereal: r.Ethereal != 0,
				Rect: Rect{int(r.Rect.X), int(r.Rect.Y), int(r.Rect.W), int(r.Rect.H)},
			}
			t := Tile{W: int(uint32(w)), H: int(uint32(h)), RGBA: unsafe.Slice((*byte)(unsafe.Pointer(rgba)), int(uint32(w))*int(uint32(h))*4)}
			if p.sprite.DrawSprite(s, int(uint32(scale)), t) {
				return 1
			}
			return 0
		})
	})
}

// Rasterize draws a layout at scale (1 is the game's size) through the providers; nil providers, or
// a provider returning false, use libd2's own 1.14d DC6 art from the context's archives.
// glyphPad is how many pixels a glyph tile extends past the cell on each side.
func (c *Context) Rasterize(l *Layout, glyph GlyphProvider, glyphPad int, sprite SpriteProvider, scale int) (*Image, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return nil, ErrClosed
	}
	var prov D2ItemDrawProviders
	if glyph != nil || sprite != nil {
		callbacks()
		providerMu.Lock()
		nextID++
		id := nextID
		active[id] = providers{glyph: glyph, sprite: sprite}
		providerMu.Unlock()
		defer func() {
			providerMu.Lock()
			delete(active, id)
			providerMu.Unlock()
		}()
		prov.User = id
		if glyph != nil {
			prov.Glyph = glyphCB
			prov.GlyphPad = uint32(glyphPad)
		}
		if sprite != nil {
			prov.Sprite = spriteCB
		}
	}
	img := c.api.Rasterize(c.ctx, l.h, unsafe.Pointer(&prov), uint32(scale))
	runtime.KeepAlive(&prov)
	return c.image(img, "layout")
}
