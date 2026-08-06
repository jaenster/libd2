#!/usr/bin/env bash
#
# Assemble the publishable Go module.
#   go-pack.sh <version> <artifacts-root> [dest]
#
# Go has no package registry: a module is published by pushing a tagged commit to the repository
# its module path names. That path is github.com/libd2/go, so this monorepo is where the
# bindings are developed and that repository is where they are shipped — the same split every
# other binding here already has, except the artifact is a git tree rather than an archive.
#
# What comes out of <dest> is a complete, standalone module: the sources from
# packages/go/libd2 plus one native shared library per GOOS/GOARCH. Commit and tag it in the
# mirror and `go get github.com/libd2/go@<version>` resolves.
#
# <artifacts-root> is the release job's merged download, laid out by the build matrix as:
#
#   <artifacts-root>/<package>/<zig target triple>/lib/libd2<package>.so
#   <artifacts-root>/<package>/<zig target triple>/bin/d2<package>.dll
set -euo pipefail

version="$1"; artifacts_root="$2"; dest="${3:-$PWD/libd2-go}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${repo_root}/packages/go/libd2"

rm -rf "$dest"
mkdir -p "$dest"

# The sources, without whatever a local `go-sync-natives.sh --local` left behind: the natives and
# their generated embed files are produced fresh below, from the release build.
tar -C "$src" -cf - \
  --exclude='natives' \
  --exclude='embed_*.go' \
  . | tar -C "$dest" -xf -

cp "${repo_root}/LICENSE" "${dest}/LICENSE"

# The published tree has no history of its own, so it records which upstream commit produced it.
# Without this, a bug reported against the module cannot be traced back to the source it was cut
# from — and the source is jaenster/libd2, not the mirror.
source_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
cat >"${dest}/SOURCE" <<EOF
libd2-go ${version}

Generated from https://github.com/jaenster/libd2
commit ${source_commit}
path   packages/go/libd2

Issues and pull requests belong upstream, not in the mirror this file ships in.
EOF

GO_MODULE_DIR="$dest" "${repo_root}/scripts/go-sync-natives.sh" "$artifacts_root"

# A module that cannot be built is not worth pushing, and this is the only place the assembled
# tree exists before it becomes a tag.
( cd "$dest" && go build ./... && go vet ./... )

cat <<EOF

go-pack: assembled ${dest} ($(du -sh "$dest" | cut -f1))

Publish it by committing the tree to the mirror and tagging:

  cd ${dest}
  git init -q && git add -A
  git commit -qm "libd2-go ${version} (jaenster/libd2@${source_commit})"
  git remote add origin git@github.com:libd2/go.git
  git push -f origin HEAD:main
  git tag v${version} && git push origin v${version}

Consumers then get it with:

  go get github.com/libd2/go@v${version}
EOF
