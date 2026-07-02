#!/usr/bin/env bash
#
# Per-package change detection + auto-patch versioning for the release pipeline.
#
# For every packages/<name>, find its most recent release tag `<name>-vX.Y.Z`.
# If the package tree changed since that tag (or was never released), emit a new
# version: the last tag's version with patch+1, or — for a never-released package
# — the .version declared in its build.zig.zon (its first release, as-is).
#
# Output: a JSON array on stdout, one object per package that needs releasing:
#   [{"name":"items","version":"0.1.1","tag":"items-v0.1.1","dir":"packages/items"}]
# Empty array [] when nothing changed. Meant for `$GITHUB_OUTPUT` matrices but
# runs fine locally too.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bump_patch() { # X.Y.Z -> X.Y.(Z+1)
  local IFS=.; read -r ma mi pa <<<"$1"; echo "${ma}.${mi}.$((pa + 1))"
}

zon_version() { # read .version = "X.Y.Z" from a build.zig.zon
  sed -nE 's/.*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$1" | head -1
}

out="[]"
for dir in packages/*/; do
  name="$(basename "$dir")"
  [ -f "$dir/build.zig.zon" ] || continue
  # Only packages with a C-ABI shim are release candidates (they produce the
  # cross-compiled libs + wasm the pipeline ships). A package joins releases the
  # moment it gains src/capi.zig.
  [ -f "$dir/src/capi.zig" ] || continue

  last="$(git tag --list "${name}-v*" --sort=-v:refname | head -1 || true)"
  if [ -z "$last" ]; then
    version="$(zon_version "$dir/build.zig.zon")"      # first ever release
    [ -n "$version" ] || version="0.1.0"
  else
    # released before — only include if the tree changed since that tag
    if git diff --quiet "$last" HEAD -- "$dir"; then
      continue
    fi
    version="$(bump_patch "${last#"${name}"-v}")"
  fi

  out="$(printf '%s' "$out" | jq -c \
    --arg n "$name" --arg v "$version" --arg d "$dir" \
    '. + [{name:$n, version:$v, tag:($n+"-v"+$v), dir:$d}]')"
done

printf '%s\n' "$out"
