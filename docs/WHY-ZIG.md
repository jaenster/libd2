# Why Zig

libd2 is a port of a 1998 C codebase, recovered from a compiled binary, that has to stay
bit-identical to it. That is a narrow job, and it turns out to want a specific set of things.

## It speaks C without being C

The engine's structures are not an interface anyone designed for us. They are whatever the
original compiler laid out, and generation reads them by offset. `extern struct` and `packed
struct` say exactly that, so a recovered layout can be written down as-is and checked field by
field against the disassembly, rather than approximated and hoped over.

The same property runs the other way. `export fn` produces an ordinary C ABI, so `drlg` and
`item` ship native shared libraries with a plain C header and no binding layer, glue code or
FFI shim on either side. The [language guides](usage/) are all calling the same symbols.

What we did not want was to actually write C. The port is full of the things C gets wrong
quietly: unchecked arithmetic on tile coordinates, arrays indexed by a value read out of a
table, unions reinterpreted by tag. Those are the bugs that would silently produce a *nearly*
correct map, which is the worst possible outcome for this project, because it still looks like a
Diablo II level. Zig makes them loud in debug builds and leaves them fast in release.

## comptime, instead of a build system that generates code

The game's excel tables are `@embedFile`d into the binary and looked up by name through a
comptime table. The parser itself is an ordinary runtime function. The point is that there is
no code generator, no build step emitting `.zig` files, and no checked-in generated source to
drift out of date with the `.txt` sitting next to it.

It also means unused tables cost nothing. `d2data.file("Levels")` resolves at compile time, so
dead-code elimination drops every table a given build never names, so a WebAssembly build
carries the tables it uses instead of all 72.

## Allocators are arguments, not ambient, and the choice is comptime

This is the one that changed the code most. It is not really a language feature, but a
convention the standard library commits to hard enough to be one.

The important part is *where the decision lives*. An allocator is a parameter, so which strategy
a call uses is fixed by the program's structure and visible in the signature. Not by ambient
global state, not by a dynamic scope, not by whatever the caller happened to install. Reading
`fn collectLevelFull(out_alloc, sa, ...)` tells you there are two lifetimes in play before you
read the body. The interface is a plain struct of function pointers over an opaque context, so
where the concrete allocator is visible at the call site there is nothing clever left for the
optimiser to defeat; and where you want the abstraction gone entirely, a function can take the
allocator's *type* as a `comptime` parameter and be monomorphised on it.

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
freestanding, with an import object of literally `{}`. That is the entire reason the npm package
runs in a browser as well as in Node.

## The mindset this has to serve

Three rules shape every port in this repo, and they are what actually rule languages in or out.

1. **Transliterate first, improve second.** The first version of a ported function reproduces the
   original as literally as possible, including the parts nobody would defend. Only once a golden
   pins its output does it get cleaned up, because only then can a change be shown not to have
   altered behaviour.
2. **The binary is the authority.** A rule is recovered from the disassembly and implemented as
   recovered. Where we cannot express the original's shape directly, we are guessing.
3. **No adapters.** A wrapper layer is a place for the two sides to disagree silently. The C ABI
   is the exported functions themselves, not a translation of something else.

## Why not Rust

The borrow checker is the whole answer, and not for the reason people expect. It is not that the
engine's memory model is unsafe. It is that rule 1 forbids fixing the model before there is a test
that would notice you changing behaviour.

The engine threads intrusive linked lists through structures it also holds raw pointers into,
hands out interior pointers, and frees through a pool that outlives everything. Rust will let you
write that, in `unsafe`, with raw pointers, having opted out of exactly the analysis you chose the
language for. The realistic outcome is C semantics with more ceremony, and a reviewer who now
has to audit `unsafe` blocks instead of reading a transliteration next to its disassembly.

Two smaller frictions point the same way. Our allocators are function arguments resolved by
program structure, but Rust's `allocator_api` is still unstable, so the practical options are a
global allocator (ambient state, the exact thing we wanted out of the signature) or threading
`&'a Bump`, which puts a lifetime on every type that touches it, and that lifetime then infects
the handle the caller holds. And with no comptime, the embed-and-select trick becomes `build.rs`
or a proc macro: generated source, which is the thing rule 2 is trying to avoid.

None of this makes Rust a bad language. It makes it a bad fit for a job whose first requirement is
faithfully reproducing code that was never written to be safe.

## Why not C++

C++ can express the engine, obviously, since the engine *is* C++. It is also already part of this
project: the reconstruction pipeline emits C++ from the decompiler, and that source is compiled and
transformed on the way to Zig. C++ is where the port comes *from*.

What it is not is a good thing to ship. Cross-compiling the release matrix (three operating
systems, two architectures, plus freestanding WebAssembly) means a toolchain and sysroot per
target, where `zig build` does the whole matrix from any host. The comptime story degrades to
constexpr plus macros, and the header/build surface grows the kind of generated, checked-in
artifacts rule 2 warns about. Exporting a C ABI needs `extern "C"` wrappers around the real
functions, which is an adapter layer by rule 3. And proving a code path does not leak needs
external tooling rather than a test that simply fails.

Most of all, the failure mode is wrong. C++ undefined behaviour is silent, and here the silent
failure is a map that is *nearly* right, the exact bug this project cannot afford to ship.

## One toolchain, every target

`zig build` cross-compiles the whole matrix from any host, with no cross-toolchain to install:
linux, macos and windows, x64 and arm64, plus freestanding WebAssembly. For a project whose
artifacts are "native libs for six targets and a wasm bundle", that is most of a release pipeline
that does not have to exist.

## What it costs

Zig is pre-1.0 and the standard library moves under you; a compiler upgrade is real work rather
than a version bump. Some of the sharp edges are structural, not transitional: a libc-free build
has no `std.time.Timer`, so the handful of places that need a monotonic clock reach for the C one
directly and carry a comment explaining why the library itself still links nothing.

That is a genuine cost. It is worth paying because the job itself is narrow and awkward:
matching a compiled binary's behaviour exactly, from decompiled C source, on six targets and in
a browser. That is what this language happens to be unusually good at.
