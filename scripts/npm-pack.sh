#!/usr/bin/env bash
#
# Package a package's wasm build as an npm module and publish it.
#   npm-pack.sh <name> <version> <path-to-wasm>
# If packages/<name>/npm/ exists, builds a dual ESM+CommonJS package from its
# index.ts + index.cts + the wasm (as d2<name>.wasm). Packages with no npm/ dir
# are skipped. Publishing requires NODE_AUTH_TOKEN.
set -euo pipefail

name="$1"; version="$2"; wasm="$3"

# Resolve package sources relative to the repo root (this script lives in scripts/),
# so the script works from any CWD. Tarballs still land in the invoking CWD.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$PWD"
npmsrc="${repo_root}/packages/${name}/npm"
if [ ! -d "$npmsrc" ]; then
  echo "npm-pack: packages/${name}/npm not found — skipping npm for '${name}'"
  exit 0
fi
if [ ! -f "$npmsrc/index.ts" ] || [ ! -f "$npmsrc/index.cts" ]; then
  echo "npm-pack: ${npmsrc} missing index.ts or index.cts — skipping '${name}'"
  exit 0
fi

pkgdir="$(mktemp -d)"
cp "$npmsrc/index.ts"  "$pkgdir/index.ts"
cp "$npmsrc/index.cts" "$pkgdir/index.cts"
cp "$wasm"             "$pkgdir/d2${name}.wasm"

cat > "$pkgdir/package.json" <<JSON
{
  "name": "@jaenster/d2${name}",
  "version": "${version}",
  "description": "WebAssembly build of the libd2 '${name}' package (clean-room Diablo II 1.14d).",
  "type": "module",
  "types": "./index.ts",
  "exports": {
    ".": {
      "import": "./index.ts",
      "require": "./index.cts"
    }
  },
  "files": ["index.ts", "index.cts", "d2${name}.wasm"],
  "license": "MIT",
  "repository": "github:jaenster/libd2"
}
JSON

# DRY_RUN=1 packs a tarball into the CWD instead of publishing (for local checks).
if [ -n "${DRY_RUN:-}" ]; then
  ( cd "$pkgdir" && npm pack --pack-destination "$dest" )
  echo "packed @jaenster/d2${name}@${version} (dry run)"
else
  ( cd "$pkgdir" && npm publish --access public )
  echo "published @jaenster/d2${name}@${version}"
fi
rm -rf "$pkgdir"
