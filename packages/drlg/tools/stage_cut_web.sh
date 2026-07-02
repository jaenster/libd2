#!/usr/bin/env bash
# Stage the recovered "cut" Arena + Guild preset maps into web/public/cut/ so the
# web tile viewer's "Other (Cut)" act can fetch + render them. web/public is
# gitignored (copyrighted Blizzard-derived art), so this reproduces the served
# layout from the committed source under assets/cut-content/.
#
#   Arena DM2/DM3 : DS1 staged here; they reuse the retail Act II Tomb tileset
#                   already served under web/public/dt1/act2/tomb/ (run the tile
#                   extractor first — see tools/extract_tiles.zig).
#   Guild 1..7    : DS1 + the bespoke color-corrected NEW_*.dt1 tileset.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/assets/cut-content/raw-ds1-dt1"
dst="$root/web/public/cut"
mkdir -p "$dst/dt1/guild"

# Arena DS1 layouts (lowercased).
for f in "$src"/arena/*.ds1; do
  cp "$f" "$dst/$(basename "$f" | tr 'A-Z' 'a-z')"
done

# Guild DS1 layouts (lowercased).
for f in "$src"/guild/*.ds1; do
  cp "$f" "$dst/$(basename "$f" | tr 'A-Z' 'a-z')"
done

# Guild bespoke DT1 tileset (lowercased) → cut/dt1/guild/.
for f in "$src"/guild/*.dt1; do
  cp "$f" "$dst/dt1/guild/$(basename "$f" | tr 'A-Z' 'a-z')"
done

echo "staged cut maps into $dst"
ls "$dst"/*.ds1 "$dst"/dt1/guild/*.dt1
