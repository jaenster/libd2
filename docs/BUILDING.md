# Building libd2 from source

Requires Zig `0.16.0`.

```sh
zig build test            # run every package's test suite
zig build test-formats    # run one package's suite (test-<pkg>)
```

Or build/test a single package on its own — each is self-contained:

```sh
cd packages/formats && zig build test
```

## C-ABI libraries + wasm

Packages with a C-ABI shim (`src/capi.zig`) build native shared/static libs and a
wasm module:

```sh
cd packages/item
zig build                                   # zig-out/lib/libd2item.* + zig-out/include/d2item.h
zig build -Dtarget=aarch64-macos            # cross-compile (any target Zig supports)
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall   # zig-out/bin/d2item.wasm
```

The packages are libc-free, so the wasm build is `wasm32-freestanding` — it
imports nothing and instantiates in any wasm runtime (Node, browser) with no WASI
shim.

## Releases

One version for the whole library: `build.zig.zon`'s `.version`, mirrored in every
package's manifest.

Pushing a `vX.Y.Z` tag publishes the npm package (`.github/workflows/npm.yml`), and
that is the only thing a tag does. The other three bindings are released on their own
so a binding fix does not re-release everything else — `crates.yml`, `nuget.yml` and
`go.yml`, each `workflow_dispatch` with a version input and defaulting to a dry run.
All four publish over OIDC trusted publishing, so there is no stored token anywhere;
each registry's policy names its own workflow file, which is why they cannot be merged
back into one.

There are no prebuilt native archives to download. Nothing consumed them, so the
workflow that cross-compiled sixteen targets into a GitHub Release was deleted; NuGet
and Go carry their own natives, and everyone else builds from source as above.

## Reading the test output

`zig build test` exits 0. It is not silent, and should not be: `packages/drlg`'s suite pulls
in the golden gates, which print what they compared because those numbers are the evidence
([docs/VERIFICATION.md](VERIFICATION.md) quotes them). Everything else has nothing to say and
now says nothing.

One thing does look alarming and is not. Anything a test writes to stderr makes Zig's build
runner print

```
failed command: ./.zig-cache/o/<hash>/test --cache-dir=./.zig-cache --seed=0x… --listen=-
```

even though every assertion in that binary passed. A *real* failure looks different — it ends
with a `Build Summary` naming the failed steps and `error: the following build command failed`,
and the build exits non-zero. Trust the exit code, not that line.

So the lines to expect from a green run are the golden gates' — collision cell counts, the
objpop tally, the 0x10 footprint — and `zig build verify` runs those and nothing else. The
unit-test fidelity dumps are off by default and come back with `-Dverbose`:

```sh
zig build test -Dverbose      # in packages/formats or packages/drlg
```
