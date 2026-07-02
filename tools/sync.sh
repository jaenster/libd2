#!/usr/bin/env bash
#
# Re-mirror the libd2 public packages from the three PRIVATE canonical dev repos.
#
# libd2 is a curated, scrubbed, public COPY (never a move — the canonical sources
# stay private; they carry the raw copyrighted Blizzard assets, the web viewer and
# the multi-GB golden corpora). Run this on every release to refresh packages/.
#
# The file set is driven by `git ls-files` in each source repo (i.e. exactly what
# that repo commits), then filtered to strip the parts that must not go public:
# the web app, the wasm binding, the raw asset trees and the huge local scratch
# (untracked, so already absent). A few drlg files are hand-maintained HERE (the
# build.zig + the *_data.zig blob shims) and are never overwritten.
#
# Source locations come from the environment (see .env.example); nothing here is
# machine-specific. Copy .env.example to .env and adjust, or export the vars.
#
#   D2_DRLG_SRC   path to the canonical d2-drlg repo
#   D2_ITEMS_SRC  path to the canonical d2-items repo
#   D2_SIM_SRC    path to the canonical d2-sim repo
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$here/.env" ] && set -a && . "$here/.env" && set +a

: "${D2_DRLG_SRC:=$here/../d2-drlg}"
: "${D2_ITEMS_SRC:=$here/../d2-items}"
: "${D2_SIM_SRC:=$here/../d2-sim}"

for v in D2_DRLG_SRC D2_ITEMS_SRC D2_SIM_SRC; do
  [ -d "${!v}" ] || { echo "!! $v=${!v} is not a directory" >&2; exit 1; }
done

pkg="$here/packages"

# mirror_repo SRC DST [extra grep -Ev filter regex]
# Copies every git-tracked file in SRC into DST, minus a default strip set and an
# optional extra exclude regex. --files-from keeps it to exactly that list; we
# clean DST of stale .zig files first so deletions in the source propagate.
mirror_repo() {
  local src="$1" dst="$2" extra="${3:-}"
  local strip='^(zig-out/|\.zig-cache/|\.idea/|\.env$)'
  mkdir -p "$dst"
  ( cd "$src" && git ls-files ) \
    | grep -Ev "$strip" \
    | { [ -n "$extra" ] && grep -Ev "$extra" || cat; } \
    | rsync -a --files-from=- "$src"/ "$dst"/
}

echo ":: items  <- $D2_ITEMS_SRC"
mirror_repo "$D2_ITEMS_SRC" "$pkg/items" '^assets/'

echo ":: sim    <- $D2_SIM_SRC"
mirror_repo "$D2_SIM_SRC" "$pkg/sim"

# drlg: strip the web viewer, the wasm binding + its build-time asset bakers, the
# raw asset trees, the RE scratch, and the hand-maintained blob shims (kept here).
echo ":: drlg   <- $D2_DRLG_SRC (code + tracked golden fixtures, no raw assets)"
mirror_repo "$D2_DRLG_SRC" "$pkg/drlg" \
  '^(web/|assets/|recon/|docs/|out/|src/wasm\.zig$|build\.zig$|tools/(gen_|extract_)|src/(ds1|dt1|dt1pix|automap)_data\.zig$)'

# Bake the four asset blobs from the private source's assets/ ONCE and commit the
# derived .bin here, so the public repo builds with no raw Blizzard art present.
echo ":: drlg   baking asset blobs"
( cd "$D2_DRLG_SRC" && zig build >/dev/null )
mkdir -p "$pkg/drlg/src/blobs"
for name in ds1 dt1 dt1pix automap; do
  src="$(find "$D2_DRLG_SRC/.zig-cache" -name "${name}_blob.bin" -type f \
        -exec stat -f '%m %N' {} + | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$src" ] || { echo "!! could not find ${name}_blob.bin in source cache" >&2; exit 1; }
  cp "$src" "$pkg/drlg/src/blobs/${name}_blob.bin"
  echo "   ${name}_blob.bin  <- $(du -h "$src" | cut -f1)"
done

echo ":: done. review 'git status', then build: (cd libd2 && zig build test)"
