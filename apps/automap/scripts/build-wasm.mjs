// Builds the combined libd2 wasm (packages/wasm) with only the generator and the router in it, and
// drops it in public/.
//
// packages/wasm bundles every subsystem's C ABI by default; the viewer asks for drlg and pf only, so
// it does not ship the item tables or the network codec it never calls.
//
// Runs as prebuild/predev. It is a no-op when the wasm is already newer than every Zig source it is
// built from, so the usual `pnpm dev` does not pay for a Zig build.

import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, "..");
const repo = resolve(app, "..", "..");
const pkg = join(repo, "packages", "wasm");
const out = join(app, "public", "libd2.wasm");
const force = process.argv.includes("--force");
const args = ["build", "-Dtarget=wasm32-freestanding", "-Doptimize=ReleaseSmall", "-Dcapi=drlg,pf"];

function newestMtime(dir) {
  let newest = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "zig-out" || entry.name === ".zig-cache") continue;
    const p = join(dir, entry.name);
    newest = Math.max(newest, entry.isDirectory() ? newestMtime(p) : statSync(p).mtimeMs);
  }
  return newest;
}

function upToDate() {
  let builtAt;
  try {
    builtAt = statSync(out).mtimeMs;
  } catch {
    return false;
  }
  // The bundle plus every libd2 package the generator and the router pull in.
  for (const p of ["wasm", "pathfinding", "world", "drlg", "core", "data", "formats", "util"]) {
    try {
      if (newestMtime(join(repo, "packages", p)) > builtAt) return false;
    } catch {
      // A package that does not exist in this checkout cannot be newer than the build.
    }
  }
  return true;
}

if (!force && upToDate()) {
  console.log("libd2.wasm is up to date");
  process.exit(0);
}

console.log(`building libd2.wasm (zig ${args.join(" ")})…`);
try {
  execFileSync("zig", args, { cwd: pkg, stdio: "inherit" });
} catch (e) {
  console.error(
    "\nCould not build libd2.wasm. Zig 0.16 must be on PATH.\n" +
    `Build it by hand with:  cd packages/wasm && zig ${args.join(" ")}\n` +
    "then copy packages/wasm/zig-out/bin/libd2.wasm to apps/automap/public/libd2.wasm\n",
  );
  throw e;
}

mkdirSync(dirname(out), { recursive: true });
copyFileSync(join(pkg, "zig-out", "bin", "libd2.wasm"), out);
console.log(`libd2.wasm -> public/libd2.wasm (${(statSync(out).size / 1048576).toFixed(2)} MB)`);
