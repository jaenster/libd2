#!/usr/bin/env bash
#
# Assemble and publish the `libd2` npm package.
#   npm-libd2-pack.sh <version> [<wasm>]
#
# One npm package for the whole library, matching `libd2` on crates.io and `LibD2` on NuGet,
# and one wasm inside it. The subsystems are not separate modules: a route is computed over an
# act the generator produced, and two wasm modules would mean two linear memories and a copy of
# every collision grid across the boundary. `packages/wasm` bundles them into one instead, so
# the shim hands a pointer where it would otherwise hand a megabyte.
#
# What ships is `packages/npm/libd2/src` — the hand-written TypeScript that turns those C-ABI
# exports into an API worth calling: `open()` a seed, ask an `Area` for its rooms, `route()`
# between two points. Node cannot type-strip `.ts` under node_modules, so the package carries
# emitted `.js` + `.d.ts`; `rewriteRelativeImportExtensions` is what makes tsc turn the source's
# `./x.ts` imports into `./x.js` on the way out.
#
# <wasm> is optional. Given a path, that build is used (the release job's freshly compiled one).
# Without one, the committed `src/libd2.wasm` — enough for a local pack.
#
# Publishing requires npm auth. DRY_RUN=1 packs a tarball into the CWD instead.
set -euo pipefail

version="$1"; wasm_in="${2:-}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$PWD"
src="${repo_root}/packages/npm/libd2"
pkgdir="$(mktemp -d)"

wasm="${wasm_in:-${src}/src/libd2.wasm}"
[ -f "$wasm" ] || { echo "libd2-pack: no wasm at ${wasm} — refusing to publish a package that cannot run"; exit 1; }

# The package's own tests run against the source, not the tarball, so they are the fastest way
# to find out that an export was renamed out from under the emit below.
( cd "$src" && npm --silent install --no-audit --no-fund && npm test )

# tsconfig has noEmit for the edit loop; packing is the one place that wants output. `include`
# is narrowed to src so the test files do not land in the package. It has to live beside the
# real tsconfig rather than in the temp dir: `types: ["node"]` resolves node_modules relative
# to the config file, and from /tmp there is none.
pack_cfg="${src}/tsconfig.pack.json"
trap 'rm -f "$pack_cfg"' EXIT
cat > "$pack_cfg" <<JSON
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "noEmit": false,
    "declaration": true,
    "declarationMap": false,
    "sourceMap": false,
    "rootDir": "./src",
    "outDir": "${pkgdir}"
  },
  "include": ["src/**/*.ts"]
}
JSON
( cd "$src" && ./node_modules/.bin/tsc -p tsconfig.pack.json )

cp "$wasm" "${pkgdir}/libd2.wasm"
cp "${src}/README.md" "${pkgdir}/README.md"

[ -f "${pkgdir}/index.js" ] && [ -f "${pkgdir}/index.d.ts" ] || { echo "libd2-pack: tsc emitted no entry point"; exit 1; }

VERSION="$version" PKGDIR="$pkgdir" python3 - "$src/package.json" "$pkgdir/package.json" <<'PY'
import json, os, sys

base = json.load(open(sys.argv[1]))
pkgdir = os.environ["PKGDIR"]

base["version"] = os.environ["VERSION"]
base.pop("dependencies", None)      # the wasm is carried, not depended on
base.pop("devDependencies", None)   # nothing is built from the tarball
base.pop("scripts", None)
base["types"] = "./index.d.ts"
base["exports"] = {".": {"types": "./index.d.ts", "default": "./index.js"}}
# Whatever tsc actually emitted, so the manifest cannot name a file that is not there.
base["files"] = sorted(e for e in os.listdir(pkgdir) if e != "package.json")
json.dump(base, open(sys.argv[2], "w"), indent=2)
PY

echo "libd2-pack: $(find "$pkgdir" -name '*.js' | wc -l | tr -d ' ') modules + libd2.wasm ($(( $(wc -c <"$wasm") / 1024 )) KB)"

if [ -n "${DRY_RUN:-}" ]; then
  ( cd "$pkgdir" && npm pack --pack-destination "$dest" )
  echo "packed libd2 ${version} (dry run)"
else
  flags="--access public"
  [ -n "${GITHUB_ACTIONS:-}" ] && flags="$flags --provenance"
  ( cd "$pkgdir" && npm publish $flags )
  echo "published libd2 ${version}"
fi
