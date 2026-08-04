#!/usr/bin/env bash
#
# Vendor the Zig engine into the Rust crate and package it.
#   crates-pack.sh [--publish]
#
# Unlike the npm and NuGet packages, the crate ships no prebuilt binaries: its build script
# compiles the engine for whatever target cargo asked for. That means the engine sources have
# to travel inside the .crate, and cargo will not include anything above the crate root, so
# they are copied into packages/rust/libd2/engine/ first. The relative paths in each
# build.zig.zon still resolve because the copy keeps the packages siblings.
#
# Test data is left behind. The goldens are ten megabytes of captured engine dumps that the
# published crate has no way to run, and crates.io caps a crate at 10 MiB.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
crate="${repo_root}/packages/rust/libd2"
engine="${crate}/engine"

# drlg and its transitive path dependencies, per build.zig.zon.
packages=(drlg core data formats)

rm -rf "$engine"
for pkg in "${packages[@]}"; do
  mkdir -p "${engine}/${pkg}"
  # -R over the declared paths, minus anything only the test steps read.
  for entry in build.zig build.zig.zon src include README.md; do
    src="${repo_root}/packages/${pkg}/${entry}"
    [ -e "$src" ] || continue
    cp -R "$src" "${engine}/${pkg}/"
  done
  rm -rf "${engine}/${pkg}/src/golden" "${engine}/${pkg}/src/testdata"
  find "${engine}/${pkg}" -name '*_test.zig' -o -name 'verify_tests.zig' | xargs -r rm -f
done

# The DT1 pixel blob is eight megabytes of tile art for rendering, and generation never
# touches it: zig only evaluates an @embedFile whose decl is actually referenced, and nothing
# on the C ABI path references this one. Dropping it takes the crate from 9.2 MiB to well
# under the limit. The build below is what proves it is genuinely unreachable rather than
# merely unused today.
rm -f "${engine}/formats/src/blobs/dt1pix_blob.bin"

echo "vendored engine: $(du -sh "$engine" | cut -f1)"

# The vendored tree must build on its own, or the crate is broken for everyone downloading it
# and fine for us. Building here is the only way to tell the difference.
tmp="$(mktemp -d)"
( cd "${engine}/drlg" && zig build -Doptimize=ReleaseFast -Dcli=false --cache-dir "${tmp}/cache" --prefix "${tmp}/out" )
echo "vendored engine builds"

cd "$crate"
cargo package --all-features --allow-dirty

# The exact version, so a stale .crate from an earlier version cannot be measured instead.
version="$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -1)"
crate_file="target/package/libd2-${version}.crate"
[ -f "$crate_file" ] || { echo "crates-pack: expected ${crate_file}"; exit 1; }
size=$(du -k "$crate_file" | cut -f1)
echo "packaged: libd2 ${version}, ${size} KiB (crates.io allows 10240 KiB)"
[ "$size" -lt 10240 ] || { echo "crates-pack: over the crates.io size limit"; exit 1; }

if [ "${1:-}" = "--publish" ]; then
  cargo publish --all-features --allow-dirty
fi
