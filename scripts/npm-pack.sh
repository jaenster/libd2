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
# Keep the hand-authored TS as the *types* source (editors/tsc read these), but
# ship compiled JS for the *runtime*: Node refuses to type-strip .ts files under
# node_modules (ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING), so a raw-.ts entry
# point is unusable as an installed dependency. esbuild transpiles each shim to
# JS (types erased); Node loads only the .js/.cjs, TS tooling reads the .ts/.cts.
cp "$npmsrc/index.ts"  "$pkgdir/index.ts"
cp "$npmsrc/index.cts" "$pkgdir/index.cts"
cp "$wasm"             "$pkgdir/d2${name}.wasm"

esb() { if command -v esbuild >/dev/null 2>&1; then esbuild "$@"; else npx --yes esbuild@0.28.1 "$@"; fi; }
esb "$npmsrc/index.ts"  --format=esm --platform=node --target=node18 --loader:.ts=ts  --outfile="$pkgdir/index.js"
esb "$npmsrc/index.cts" --format=cjs --platform=node --target=node18 --loader:.cts=ts --outfile="$pkgdir/index.cjs"

# README shown on the npm package page: the package's own npm/README.md if it has
# one, else a minimal generated stub.
if [ -f "$npmsrc/README.md" ]; then
  cp "$npmsrc/README.md" "$pkgdir/README.md"
else
  cat > "$pkgdir/README.md" <<MD
# @jaenster/d2${name}

WebAssembly build of the libd2 \`${name}\` package (clean-room Diablo II 1.14d),
behind a tiny typed shim (ESM + CommonJS, lazily loaded). See
https://github.com/jaenster/libd2 for docs.

\`\`\`sh
npm install @jaenster/d2${name}
\`\`\`
MD
fi

cat > "$pkgdir/package.json" <<JSON
{
  "name": "@jaenster/d2${name}",
  "version": "${version}",
  "description": "WebAssembly build of the libd2 '${name}' package (clean-room Diablo II 1.14d).",
  "type": "module",
  "types": "./index.ts",
  "exports": {
    ".": {
      "import": { "types": "./index.ts", "default": "./index.js" },
      "require": { "types": "./index.cts", "default": "./index.cjs" }
    }
  },
  "files": ["index.ts", "index.cts", "index.js", "index.cjs", "d2${name}.wasm", "README.md"],
  "license": "MIT",
  "repository": "github:jaenster/libd2"
}
JSON

# DRY_RUN=1 packs a tarball into the CWD instead of publishing (for local checks).
if [ -n "${DRY_RUN:-}" ]; then
  ( cd "$pkgdir" && npm pack --pack-destination "$dest" )
  echo "packed @jaenster/d2${name}@${version} (dry run)"
else
  # Under GitHub Actions, publish with build provenance via OIDC trusted publishing
  # (needs id-token: write + a recent npm; no NPM_TOKEN secret). Locally, plain
  # token/login publish — provenance requires the CI OIDC context.
  flags="--access public"
  [ -n "${GITHUB_ACTIONS:-}" ] && flags="$flags --provenance"
  ( cd "$pkgdir" && npm publish $flags )
  echo "published @jaenster/d2${name}@${version}"
fi
rm -rf "$pkgdir"
