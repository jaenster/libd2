#!/usr/bin/env bash
#
# Assemble and publish the `libd2` npm package.
#   npm-libd2-pack.sh <version> [<wasm-root>]
#
# One npm package for the whole library, matching `libd2` on crates.io and `LibD2` on NuGet,
# rather than one package per subsystem. Each subsystem is a namespace carrying its own wasm:
#
#   libd2/index.js        export * as drlg from './drlg/index.js'
#   libd2/drlg/index.js   libd2/drlg/d2drlg.wasm
#   libd2/item/index.js   libd2/item/d2item.wasm
#
# and each is also a subpath export, so `import * as drlg from 'libd2/drlg'` lets a bundler
# pull in one wasm instead of all of them. The shims resolve their wasm with
# `new URL('./d2<name>.wasm', import.meta.url)`, which works unchanged from a subdirectory.
#
# <wasm-root> is optional. Given one, wasm is taken from <wasm-root>/<name>/**/*.wasm (the
# release job's artifact layout). Without one, from packages/<name>/npm/d2<name>.wasm if that
# is checked in — enough for a local pack. A namespace with no wasm is skipped, so this
# produces whatever is actually available rather than a broken package.
#
# Publishing requires npm auth. DRY_RUN=1 packs a tarball into the CWD instead.
set -euo pipefail

version="$1"; wasm_root="${2:-}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$PWD"
src="${repo_root}/packages/npm/libd2"
pkgdir="$(mktemp -d)"

# Every subsystem that ships a C ABI + wasm. Add a name here when it grows one.
namespaces=(drlg item)

esb() { if command -v esbuild >/dev/null 2>&1; then esbuild "$@"; else npx --yes esbuild@0.28.1 "$@"; fi; }

found=()
for name in "${namespaces[@]}"; do
  shim="${repo_root}/packages/${name}/npm/index.ts"
  [ -f "$shim" ] || { echo "libd2-pack: no shim for ${name}, skipping"; continue; }

  if [ -n "$wasm_root" ]; then
    wasm="$(find "${wasm_root}/${name}" -name '*.wasm' 2>/dev/null | head -1 || true)"
  else
    wasm="${repo_root}/packages/${name}/npm/d2${name}.wasm"
    [ -f "$wasm" ] || wasm=""
  fi
  [ -n "$wasm" ] || { echo "libd2-pack: no wasm for ${name}, skipping"; continue; }

  mkdir -p "${pkgdir}/${name}"
  # The hand-authored TS stays the types source; Node cannot type-strip .ts under
  # node_modules, so the runtime entry is transpiled JS. Same split as npm-pack.sh.
  cp "$shim" "${pkgdir}/${name}/index.ts"
  cp "$wasm" "${pkgdir}/${name}/d2${name}.wasm"
  esb "$shim" --format=esm --platform=neutral --target=es2022 --loader:.ts=ts \
      --outfile="${pkgdir}/${name}/index.js" >/dev/null
  found+=("$name")
  echo "libd2-pack: ${name} -> ${name}/index.js + d2${name}.wasm ($(( $(wc -c <"$wasm") / 1024 )) KB)"
done

[ ${#found[@]} -gt 0 ] || { echo "libd2-pack: no namespaces had a wasm build — refusing to publish an empty package"; exit 1; }

# Root entry: every namespace, re-exported. Written from the set actually assembled, so it can
# never name a namespace whose wasm is missing.
{
  for name in "${found[@]}"; do echo "export * as ${name} from './${name}/index.js';"; done
} > "${pkgdir}/index.js"
{
  for name in "${found[@]}"; do echo "export * as ${name} from './${name}/index.js';"; done
} > "${pkgdir}/index.d.ts"

cp "${src}/README.md" "${pkgdir}/README.md"

FOUND="${found[*]}" VERSION="$version" python3 - "$src/package.json" "$pkgdir/package.json" <<'PY'
import json, os, sys

base = json.load(open(sys.argv[1]))
names = os.environ["FOUND"].split()

base["version"] = os.environ["VERSION"]
base.pop("dependencies", None)          # the wasm is carried, not depended on
base["exports"] = {".": {"types": "./index.d.ts", "default": "./index.js"}}
files = ["index.js", "index.d.ts", "README.md"]
for n in names:
    base["exports"][f"./{n}"] = {"types": f"./{n}/index.ts", "default": f"./{n}/index.js"}
    files += [f"{n}/index.ts", f"{n}/index.js", f"{n}/d2{n}.wasm"]
base["files"] = files
json.dump(base, open(sys.argv[2], "w"), indent=2)
PY

if [ -n "${DRY_RUN:-}" ]; then
  ( cd "$pkgdir" && npm pack --pack-destination "$dest" )
  echo "packed libd2 ${version} with namespaces: ${found[*]} (dry run)"
else
  flags="--access public"
  [ -n "${GITHUB_ACTIONS:-}" ] && flags="$flags --provenance"
  ( cd "$pkgdir" && npm publish $flags )
  echo "published libd2 ${version} with namespaces: ${found[*]}"
fi
