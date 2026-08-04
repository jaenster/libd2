# Why Zig

libd2 is a port of a 1998 C codebase, recovered from a compiled binary, that has to stay
bit-identical to it. That is a narrow job, and it turns out to want a specific set of things.

## It speaks C without being C

The engine's structures are not an interface anyone designed for us — they are whatever the
original compiler laid out, and generation reads them by offset. `extern struct` and `packed
struct` say exactly that, so a recovered layout can be written down as-is and checked field by
field against the disassembly, rather than approximated and hoped over.

The same property runs the other way. `export fn` produces an ordinary C ABI, so `drlg` and
`item` ship native shared libraries with a plain C header and no binding layer, glue code or
FFI shim on either side — the [language guides](usage/) are all calling the same symbols.

What we did not want was to actually write C. The port is full of the things C gets wrong
quietly: unchecked arithmetic on tile coordinates, arrays indexed by a value read out of a
table, unions reinterpreted by tag. Those are the bugs that would silently produce a *nearly*
correct map, which is the worst possible outcome for this project — it still looks like a
Diablo II level. Zig makes them loud in debug builds and leaves them fast in release.

## comptime, instead of a build system that generates code

The game's excel tables are `@embedFile`d into the binary and looked up by name through a
comptime table. The parser itself is an ordinary runtime function — the point is that there is
no code generator, no build step emitting `.zig` files, and no checked-in generated source to
drift out of date with the `.txt` sitting next to it.

It also means unused tables cost nothing. `d2data.file("Levels")` resolves at compile time, so
dead-code elimination drops every table a given build never names — which is why a WebAssembly
build carries the tables it uses instead of all 72.

## Allocators are arguments, not ambient

This is the one that changed the code most, and it is not really a language feature — it is a
convention the standard library commits to hard enough to be one.

Generation allocates constantly and most of it is garbage the moment a level is done. Because
every function takes the allocator it should use, that is expressible directly: `generateActFull`
threads a per-level scratch arena that is reset after each level, and a separate long-lived
allocator for the handful of slices the caller keeps. The transient high-water mark is one
level's worth rather than all thirty-nine accumulated, and saying so took a parameter rather
than an architecture.

The same convention is why the tests can prove there are no leaks. `std.testing.allocator` fails
a test that leaks a single byte, so "does this path leak" is not a question anyone has to
remember to ask.

And it is why there is no libc. The pool allocator is a faithful replica of the engine's own
`Fog::Memory` slab allocator, the packages never call `malloc`, and so the WebAssembly build is
freestanding — its import object is literally `{}`. That is the entire reason the npm package
runs in a browser as well as in Node.

## No borrow checker, deliberately

Rust is the obvious alternative and it would have been the wrong tool here, for one reason: the
first version of every ported function has to be a faithful transliteration of the original,
including the parts that are ugly.

The engine threads intrusive linked lists through structures it also holds raw pointers into,
hands out interior pointers, and frees through a pool that outlives everything. That is not a
design to defend — but while porting, the *only* thing that matters is that the output matches
byte for byte. A borrow checker would demand the shape be fixed first, before there is any test
that can tell you whether you changed behaviour while fixing it. Zig lets the ugly version exist,
get pinned by a golden, and be cleaned up afterwards against a test that will notice.

Safety comes back through the checks that do not need ownership information: bounds, overflow,
and a leak-checking allocator in every test.

## One toolchain, every target

`zig build` cross-compiles the whole matrix — linux, macos and windows, x64 and arm64, plus
freestanding WebAssembly — from any host, with no cross-toolchain to install. For a project
whose artifacts are "native libs for six targets and a wasm bundle", that is most of a release
pipeline that does not have to exist.

## What it costs

Zig is pre-1.0 and the standard library moves under you; a compiler upgrade is real work rather
than a version bump. Some of the sharp edges are structural, not transitional: a libc-free build
has no `std.time.Timer`, so the handful of places that need a monotonic clock reach for the C one
directly and carry a comment explaining why the library itself still links nothing.

That is a genuine cost. It is worth it here because the alternative — matching a compiled
binary's behaviour exactly, from a decompiled C source, on six targets and in a browser — is
what the language is unusually good at.
