// Package item rolls Diablo II 1.14d item drops from a seed.
//
// A roll reproduces exactly what the game drops for a treasure class at a monster level, down to
// the affixes and the item's own mod seed:
//
//	c, err := item.New()
//	if err != nil {
//		return err
//	}
//	defer c.Close()
//
//	drops, err := c.Roll(1337, "Act 5 (H) Super Cx", 87, 300)
//	for _, d := range drops {
//		fmt.Println(d.Kind, d.Code(), d.Quality)
//	}
//
// The native library is bound with purego, so nothing here needs cgo.
//
// Part of libd2: https://github.com/jaenster/libd2 — the engine itself, what each subsystem is
// verified against, and the same C ABI from other languages. These bindings are generated from
// that repository; issues and pull requests belong there.
package item

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"
)

// ErrClosed is returned by every method of a Context that has been closed.
var ErrClosed = errors.New("libd2/item: context is closed")

// Context owns the loaded tables and treasure sets. Building them is the expensive part, so keep
// one and reuse it.
//
// Calls are serialised: the native context is single-threaded. Give each goroutine its own
// Context to actually parallelise.
type Context struct {
	mu  sync.Mutex
	api *api
	ctx uintptr
}

// New loads the tables and treasure sets. Close it when you are done.
func New() (*Context, error) {
	a, err := load()
	if err != nil {
		return nil, err
	}
	ctx := a.create()
	if ctx == 0 {
		return nil, errors.New("libd2/item: could not load the tables")
	}
	return &Context{api: a, ctx: ctx}, nil
}

// Close releases the tables. It is safe to call more than once.
func (c *Context) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx != 0 {
		c.api.destroy(c.ctx)
		c.ctx = 0
	}
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

// Roll produces the drops for one kill: the treasure class named by tc, at monster level mlvl,
// with mf points of magic find. The same seed always produces the same drops.
//
// An empty result is an answer, not an error — most rolls drop nothing.
func (c *Context) Roll(seed uint32, tc string, mlvl, mf int32) ([]Drop, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx == 0 {
		return nil, ErrClosed
	}

	// Roll once into a buffer big enough for almost every treasure class, and only redo it in
	// the rare case that reports more. A count probe would be the other option, but unlike the
	// map generator's list accessors this call does the work each time it is asked.
	buf := make([]Drop, 8)
	for {
		got := c.api.roll(c.ctx, seed, tc, mlvl, mf, unsafe.Pointer(&buf[0]), int32(len(buf)))
		runtime.KeepAlive(buf)
		if got < 0 {
			return nil, fmt.Errorf("libd2/item: rolling %q at mlvl %d failed (%d)", tc, mlvl, got)
		}
		if int(got) <= len(buf) {
			if got == 0 {
				return nil, nil
			}
			return buf[:got], nil
		}
		buf = make([]Drop, got)
	}
}
