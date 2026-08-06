# libd2 for Go

Go bindings for **[libd2](https://github.com/jaenster/libd2)** — a clean-room reimplementation of
the **Diablo II 1.14d** engine core. Give it a seed and it produces the same world, the same item
drops and the same routes the game does.

```
go get github.com/libd2/go
```

> This repository is **generated**. The bindings are developed in
> [jaenster/libd2](https://github.com/jaenster/libd2) under `packages/go/libd2` and published here
> as a tagged tree, because that is how a Go module is published. Issues, pull requests and
> discussion belong upstream: **https://github.com/jaenster/libd2**.

Requires Go 1.24 or newer. **No cgo**, no toolchain setup, no `pkg-config`: the native library is
called through [purego](https://github.com/ebitengine/purego) and ships inside the module.

## Generating a world

```go
package main

import (
	"fmt"

	"github.com/libd2/go/drlg"
)

func main() {
	g, err := drlg.New()
	if err != nil {
		panic(err)
	}
	defer g.Close()

	act, err := g.GenerateAct(0x10000000, drlg.Normal, 0) // act 0 is Act I
	if err != nil {
		panic(err)
	}
	for _, l := range act.Levels {
		fmt.Printf("%-28s %-11s rooms=%d npcs+objects=%d\n", l.Name, l.Type, len(l.Rooms), len(l.Presets))
	}
}
```

`GenerateAct` copies everything out before it returns, so an `Act` is ordinary Go data — nothing
to release, nothing that can be used after free. Pass `drlg.WithCollision()` or `drlg.WithWalk()`
to also copy each level's subtile grids; they are off by default because a whole act's worth is
tens of megabytes.

## Rolling item drops

```go
c, _ := item.New()
defer c.Close()

drops, _ := c.Roll(0x10000000, "Act 5 (H) Super Cx", 87, 800)
for _, d := range drops {
	fmt.Println(d) // rare 7fb ilvl 87
}
```

## Routing

`pathfinding` routes over a world `drlg` generated, sharing that generator's loaded tables:

```go
g, _ := drlg.New()
defer g.Close()

w, _ := pathfinding.New(g, 0x10000000, drlg.Normal)
defer w.Close()
w.LoadAct(0)

route, _ := w.Route(
	pathfinding.Pos{Level: 1, X: 120, Y: 120},
	pathfinding.Pos{Level: 3, X: 200, Y: 200},
	nil,
)
for _, leg := range route.Legs {
	fmt.Printf("level %d: %d moves, exits into %d\n", leg.Level, len(leg.Moves), leg.Exit)
}
```

A nil route with a nil error is an answer, not a failure: some pairs genuinely are not connected.

Every coordinate in `pathfinding` — and every preset and grid cell in `drlg` — is a **level-local
subtile**. Room rectangles and a level's origin and size are in **world tiles**; multiply the
origin by 5 to get from one frame to the other.

## The whole thing at once

[`examples/tour`](examples/tour) walks every subsystem against one fixed seed — levels, warps, the
three coordinate frames, both grids, routing on foot and by teleport, and a drop roll:

```
go run github.com/libd2/go/examples/tour@latest
```

Its output is snapshotted in its own test, so it doubles as an end-to-end check and as the source
of every number quoted in the guide.

## Where the native library comes from

Each subsystem package embeds one shared library, for the GOOS/GOARCH being built, and writes it
to the user cache directory the first time it is opened. Only the subsystems you import cost
anything:

| binary | size |
|-|-|
| a Go program with no libd2 | 2.1 MB |
| `+ drlg` | 4.1 MB |
| `+ item + pathfinding` | 5.5 MB |
| `-tags libd2_nolib` | 2.8 MB |

The libraries are stripped and gzipped, so that is what a binary carries; they are decompressed
into the cache directory the first time a version runs. The module download is larger, because it
carries every platform's binary — but a build only ever compiles in its own.

To use a library from disk instead — a local libd2 build, or a platform we ship no binary for:

| variable | meaning |
|-|-|
| `LIBD2_D2DRLG_PATH` | an exact file, per library (`D2ITEM`, `D2PF` likewise) |
| `LIBD2_PATH` | a directory holding platform-named libraries |

These are checked before the embedded copy, so overriding a shipped binary with a local build
needs no rebuild. Building with `-tags libd2_nolib` leaves the embedded copy out entirely, for a
small binary against a system-installed library.

Alpine and other musl systems: the shipped Linux binaries are glibc builds. Point `LIBD2_PATH` at
a musl build of the shared libraries.

FreeBSD needs `CGO_ENABLED=1`, which purego's FreeBSD support requires and which is the default
on a FreeBSD host anyway. Every other platform builds with cgo off.

## Costs

On an M3 Max, generating a whole act:

| | |
|-|-|
| `drlg.New()`, once | 13 ms |
| `GenerateAct`, Act I | 198 ms, of which 175 ms is the generator itself |
| a trivial FFI call | 0.6 µs |

The boundary is not the expensive part of generating a world. It is worth knowing about for the
small calls, though: `Walkable` and `LineOfSight` cost most of a microsecond each, so per-cell
loops belong on the native side — that is what `Route` is for.

## Threading

A `Generator`, `Context` or `World` serialises its own calls, so sharing one between goroutines
is safe but not concurrent. Give each goroutine its own to actually parallelise; the tables cost
13 ms to load and nothing after that.

## Where the rest of it is

Everything about the engine itself lives upstream in
[jaenster/libd2](https://github.com/jaenster/libd2):

- [How faithful is it?](https://github.com/jaenster/libd2/blob/main/docs/VERIFICATION.md) — what
  each subsystem is actually verified against, per subsystem, and where the evidence is weaker.
- [The Go guide](https://github.com/jaenster/libd2/blob/main/docs/usage/go.md) — the longer
  version of this file, including the three coordinate frames.
- The same engine [from Rust, .NET, Node, Zig, C and C++](https://github.com/jaenster/libd2#using-it),
  all calling the same C ABI.
- [Sponsor the work](https://github.com/sponsors/jaenster) if it is useful to you.

## Licence

Same as libd2. See [LICENSE](LICENSE), and
[jaenster/libd2](https://github.com/jaenster/libd2) for the project it comes from.
