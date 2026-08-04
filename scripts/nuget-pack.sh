#!/usr/bin/env bash
#
# Build and publish the LibD2 NuGet package.
#   nuget-pack.sh <version> <artifacts-root>
#
# There is ONE .NET package for the whole library rather than one per subsystem, so a consumer
# writes `dotnet add package LibD2` once and reaches everything through namespaces. It carries
# every subsystem's native library, for every platform, in a single download.
#
# <artifacts-root> is the release job's merged download, laid out by the build matrix as:
#
#   <artifacts-root>/<package>/<zig target triple>/lib/libd2<package>.so
#   <artifacts-root>/<package>/<zig target triple>/bin/d2<package>.dll
#
# which is rewritten into the runtimes/{rid}/native/ layout NuGet expects. The .NET host then
# picks the right binary per platform, so DllImport can name a library without a suffix or path.
# Packages with no C ABI have no shared library and are skipped.
#
# Publishing requires NUGET_API_KEY. DRY_RUN=1 packs into the CWD instead.
set -euo pipefail

version="$1"; artifacts_root="$2"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$PWD"
proj="${repo_root}/packages/dotnet/LibD2"

# zig target triple -> .NET runtime identifier. Anything not listed is skipped rather than
# guessed, because a wrong RID fails at the consumer's runtime rather than here.
#
# freebsd and riscv64 are included even though `dotnet publish -r` cannot build an app for them
# (the SDK has no apphost): a PORTABLE app resolves native assets by the host's own RID at run
# time, so shipping them is what makes those platforms work at all.
rid_for() {
  case "$1" in
    x86_64-linux-gnu)      echo "linux-x64" ;;
    aarch64-linux-gnu)     echo "linux-arm64" ;;
    arm-linux-gnueabihf)   echo "linux-arm" ;;
    x86_64-linux-musl)     echo "linux-musl-x64" ;;
    aarch64-linux-musl)    echo "linux-musl-arm64" ;;
    arm-linux-musleabihf)  echo "linux-musl-arm" ;;
    riscv64-linux-gnu)     echo "linux-riscv64" ;;
    x86_64-freebsd)        echo "freebsd-x64" ;;
    aarch64-freebsd)       echo "freebsd-arm64" ;;
    x86_64-macos)          echo "osx-x64" ;;
    aarch64-macos)         echo "osx-arm64" ;;
    x86-windows-gnu)       echo "win-x86" ;;
    x86_64-windows-gnu)    echo "win-x64" ;;
    aarch64-windows-gnu)   echo "win-arm64" ;;
    *)                     echo "" ;;
  esac
}

rm -rf "${proj}/runtimes"
found=0
for pkgdir in "${artifacts_root}"/*/; do
  pkg="$(basename "$pkgdir")"
  for tdir in "${pkgdir}"*/; do
    [ -d "$tdir" ] || continue
    triple="$(basename "$tdir")"
    rid="$(rid_for "$triple")"
    [ -z "$rid" ] && continue

    lib="$(find "$tdir" -type f \( -name "*d2${pkg}.so" -o -name "*d2${pkg}.dylib" -o -name "d2${pkg}.dll" \) | head -1)"
    [ -z "$lib" ] && continue

    mkdir -p "${proj}/runtimes/${rid}/native"
    out="${proj}/runtimes/${rid}/native/$(basename "$lib")"
    cp "$lib" "$out"
    # ELF carries debug info that triples its size, and this package ships one binary per
    # platform per subsystem. GNU strip only understands the HOST architecture, so on an x86_64
    # runner it silently leaves every arm/riscv build unstripped; llvm-strip handles them all.
    # Never fatal, but say so when a binary could not be stripped rather than shipping 10 MB
    # quietly.
    stripped=""
    for tool in llvm-strip llvm-strip-20 llvm-strip-19 llvm-strip-18 llvm-strip-17 llvm-strip-16 strip; do
      command -v "$tool" >/dev/null 2>&1 || continue
      if "$tool" "$out" 2>/dev/null; then stripped="$tool"; break; fi
    done
    [ -z "$stripped" ] && echo "nuget-pack: WARNING could not strip $(basename "$out") for ${rid}; shipping it unstripped"
    echo "nuget-pack: ${pkg} ${triple} -> runtimes/${rid}/native/$(basename "$out") ($(( $(wc -c <"$out") / 1024 )) KB)"
    found=$((found + 1))
  done
done

if [ "$found" -eq 0 ]; then
  echo "nuget-pack: no native libraries found under ${artifacts_root} — refusing to publish a managed-only package"
  exit 1
fi

dotnet pack "$proj" -c Release -o "$dest" -p:Version="$version" --nologo

if [ -n "${DRY_RUN:-}" ]; then
  echo "packed LibD2 ${version} with ${found} native binaries (dry run)"
else
  dotnet nuget push "${dest}/LibD2.${version}.nupkg" \
    --source https://api.nuget.org/v3/index.json \
    --api-key "${NUGET_API_KEY:?NUGET_API_KEY is required to publish}" \
    --skip-duplicate
  echo "published LibD2 ${version} with ${found} native binaries"
fi
