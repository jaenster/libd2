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
	api   *api
	ctx   uintptr
	owned []nativeBuf
}

type nativeBuf struct {
	p uintptr
	n uintptr
}

// New loads the tables. Close it when you are done.
func New() (*Context, error) {
	a, err := load()
	if err != nil {
		return nil, err
	}
	ctx := a.create()
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
		c.api.destroy(c.ctx)
		c.ctx = 0
	}
	for _, b := range c.owned {
		c.api.free(b.p, b.n)
	}
	c.owned = nil
	return nil
}

// ABIVersion is the C ABI version of the native library in use.
func ABIVersion() (uint32, error) {
	a, err := load()
	if err != nil {
		return 0, err
	}
	return a.abiVersion(), nil
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
	p := c.api.alloc(uintptr(len(mpq)))
	if p == 0 {
		return errors.New("libd2/itemdraw: out of memory")
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(p)), len(mpq)), mpq)
	c.owned = append(c.owned, nativeBuf{p, uintptr(len(mpq))})
	if rc := c.api.addArchive(c.ctx, p, uintptr(len(mpq))); rc != 0 {
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
	rc := c.api.addFile(c.ctx, name, unsafe.Pointer(&data[0]), uintptr(len(data)))
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
	n := c.api.text(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o), int32(mode), nil, 0)
	if n < 0 {
		return "", fmt.Errorf("libd2/itemdraw: the records do not describe an item (%d)", n)
	}
	if n == 0 {
		return "", nil
	}
	buf := make([]byte, n)
	c.api.text(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o), int32(mode), unsafe.Pointer(&buf[0]), uintptr(n))
	runtime.KeepAlive(records)
	runtime.KeepAlive(o)
	return string(buf), nil
}

func (c *Context) image(img uintptr, what string) (*Image, error) {
	if img == 0 {
		return nil, fmt.Errorf("libd2/itemdraw: could not draw the %s (records or art missing)", what)
	}
	defer c.api.imageFree(img)
	w := int(c.api.imageWidth(img))
	h := int(c.api.imageHeight(img))
	rgba := make([]byte, w*h*4)
	copy(rgba, unsafe.Slice((*byte)(unsafe.Pointer(c.api.imageRGBA(img))), w*h*4))
	var n uintptr
	p := c.api.imagePNG(img, unsafe.Pointer(&n))
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
	img := c.api.icon(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o), int32(bg), s)
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
	img := c.api.tooltip(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o))
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
	img := c.api.card(c.ctx, unsafe.Pointer(&records[0]), uintptr(len(records)), optsPtr(o))
	runtime.KeepAlive(records)
	return c.image(img, "card")
}
