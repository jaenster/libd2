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
  "types": "index.d.ts",
  "files": ["index.mjs", "index.d.ts", "d2${name}.wasm"],
  "license": "MIT",
  "repository": "github:jaenster/libd2"
}
JSON

cat > "$pkgdir/index.d.ts" <<TS
// TypeScript definitions for @jaenster/d2${name} (libd2 '${name}' wasm build).

/** The module's C-ABI exports: d2${name}_* functions (numbers in, number out —
 *  strings/structs are byte offsets into \`memory\`) plus the wasm memory. */
export interface D2Exports {
  memory: WebAssembly.Memory;
  [fn: string]: WebAssembly.ExportValue;
}

export interface D2Instance {
  exports: D2Exports;
  memory: WebAssembly.Memory;
}

/** Instantiate the wasm module. \`imports\` is usually unnecessary (the module is
 *  self-contained). Returns the raw C-ABI exports + memory. */
export function instantiate(imports?: WebAssembly.Imports): Promise<D2Instance>;
export default instantiate;
TS

cat > "$pkgdir/index.mjs" <<JS
// Thin loader: instantiate the wasm module and hand back its exports + memory.
// The exports are the package's C-ABI functions (d2${name}_*). Strings/structs
// are passed as pointers into \`memory\` — see the libd2 USAGE docs for helpers.
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const WASM = 'd2${name}.wasm';

// Some packages link wasi-libc (their generator uses libc); the module then
// imports wasi_snapshot_preview1. These are deterministic, seed-driven compute
// modules, so a minimal no-op WASI shim is enough to instantiate them. Pass your
// own \`imports.wasi_snapshot_preview1\` (e.g. from node:wasi) to override.
const wasiShim = new Proxy({}, { get: () => (() => 0) });

export async function instantiate(imports = {}) {
  const bytes = await readFile(fileURLToPath(new URL('./' + WASM, import.meta.url)));
  const merged = { wasi_snapshot_preview1: wasiShim, env: {}, ...imports };
  const { instance } = await WebAssembly.instantiate(bytes, merged);
  if (typeof instance.exports._initialize === 'function') instance.exports._initialize();
  return { exports: instance.exports, memory: instance.exports.memory };
}
export default instantiate;
JS

# DRY_RUN=1 packs a tarball into the CWD instead of publishing (for local checks).
if [ -n "${DRY_RUN:-}" ]; then
  ( cd "$pkgdir" && npm pack --pack-destination "$OLDPWD" )
  echo "packed @jaenster/d2${name}@${version} (dry run)"
else
  ( cd "$pkgdir" && npm publish --access public )
  echo "published @jaenster/d2${name}@${version}"
fi
rm -rf "$pkgdir"
