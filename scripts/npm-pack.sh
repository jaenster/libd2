#!/usr/bin/env bash
#
# Package a package's wasm build as an npm module and publish it.
#   npm-pack.sh <name> <version> <path-to-wasm>
# Publishes @jaenster/d2<name> containing the .wasm + a thin ESM loader that
# instantiates it and returns its exports + memory. Requires NODE_AUTH_TOKEN.
set -euo pipefail

name="$1"; version="$2"; wasm="$3"
pkgdir="$(mktemp -d)"
cp "$wasm" "$pkgdir/d2${name}.wasm"

cat > "$pkgdir/package.json" <<JSON
{
  "name": "@jaenster/d2${name}",
  "version": "${version}",
  "description": "WebAssembly build of the libd2 '${name}' package (clean-room Diablo II 1.14d).",
  "type": "module",
  "main": "index.mjs",
  "files": ["index.mjs", "d2${name}.wasm"],
  "license": "MIT",
  "repository": "github:jaenster/libd2"
}
JSON

cat > "$pkgdir/index.mjs" <<JS
// Thin loader: instantiate the wasm module and hand back its exports + memory.
// The exports are the package's C-ABI functions (d2${name}_*). Strings/structs
// are passed as pointers into \`memory\` — see the libd2 USAGE docs for helpers.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const WASM = 'd2${name}.wasm';

export async function instantiate(imports = {}) {
  const bytes = await readFile(fileURLToPath(new URL('./' + WASM, import.meta.url)));
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  return { exports: instance.exports, memory: instance.exports.memory };
}
export default instantiate;
JS

( cd "$pkgdir" && npm publish --access public )
echo "published @jaenster/d2${name}@${version}"
rm -rf "$pkgdir"
