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
freestanding wasm module:

```sh
cd packages/items
zig build                                   # zig-out/lib/libd2items.* + zig-out/include/d2items.h
zig build -Dtarget=aarch64-macos            # cross-compile (any target Zig supports)
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall   # zig-out/bin/d2items.wasm
```

## Releases

Pushing to `main` runs `.github/workflows/release.yml`, which detects packages
changed since their last `<pkg>-vX.Y.Z` tag, auto-patch-bumps, cross-compiles all
targets + wasm, cuts per-package GitHub Releases, and publishes the wasm to npm.
See `scripts/detect-changes.sh` for the versioning logic.

## Note on the two known drlg test failures

`packages/drlg` has two long-standing failing tests in `materialize.zig`
(collision reproduction: town and Crypt), a known residual in the clean-room
port. They are expected; every other package is fully green.
