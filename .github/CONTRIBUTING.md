# Contributing

libd2 reproduces what a specific binary does. That makes the bar here an unusual one: a change is
right when it matches the game, not when it looks reasonable or when the tests are green.

## The one rule

**Never invent a number.** Offsets, table values, bit widths, opcodes, seed arithmetic — all of it
is measurable, from the retail 1.14d binary or from the game's own `.txt` tables. If a value came
from a wiki, another project, or an inference, say so in a comment beside it and say what would
confirm it.

Guessing does not fail loudly here. A generator with one wrong constant still produces a map; it is
simply not the game's map, and nothing says so until someone compares a thousand seeds.

## Building and testing

```
zig build test            # every package's test suite
zig build test-umbrella   # check the umbrella module resolves every package
zig build verify          # the golden verification gates (drlg)
```

Zig `0.16.0`, the version `build.zig.zon` pins as its minimum. No libc: several packages target
`wasm32-freestanding`, and anything that reaches for libc breaks that quietly for everyone
downstream.

The verification suites are what make a change believable — the seeded generators are checked
against captured engine output, not against expectations written alongside the code. If you change
generation, say which seeds you ran and how many.

## Packages

Each `packages/*` stands alone and declares its own dependencies. Two rules hold that together:

- Dependencies point one way. `d2-formats` and `d2-data` depend on nothing; the model sits in
  `d2-core`; consumers sit above. A cycle is a design error, not something to break with an import.
- A concept the whole engine shares belongs in `d2-core`, under the engine's own name for it.

## Bindings and the C ABI

The bindings (Rust, .NET, Go, npm) each pin the C ABI version they were written against, and the
native library reports its own. **Both sides of that pin have shipped wrong at least once**, in
opposite directions: one binding was pinned behind a committed native, another behind a native the
release workflow builds fresh. If you change a `capi.zig` signature, bump `d2<pkg>_abi_version`,
update every binding's expected value, and check the header in `include/` still describes reality.

## Commit messages

Subject line is `area: what is now true`, in prose, no trailing period:

```
net: every command is the length the engine frames it at
save: convert a whole save between the pre-1.09 and modern layouts
```

The body is for why, and for what the symptom looked like before it was understood. No tool or
assistant attribution.

## Releases

The library and the language bindings are on **separate version tracks** on purpose, so a binding
fix does not re-release everything. The library version lives in `build.zig.zon` and is mirrored
into every `packages/*/build.zig.zon` and the npm manifest; pushing the `vX.Y.Z` tag is what
publishes. Each binding has its own `workflow_dispatch` with a `dry_run` that **defaults to true** —
always run it first.

## Scope

No Blizzard code, ever. The baked `.bin`/`.dt1`/`.ds1` blobs are data required to build and verify;
they are not source, and nothing derived from decompiled code belongs here.
