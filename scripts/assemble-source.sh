#!/usr/bin/env bash
# assemble-source.sh — build the .orig tarball for a series from the verified .run.
#
#   assemble-source.sh <series> [<outdir>] [--split-i386]
#
# Produces, in <outdir> (default $PWD):
#   nvidia-legacy-<series>_<version>.orig.tar.xz
#
# ONE tarball by default: the amd64 .run already ships the 32-bit compat
# libraries (payload/32/) and the kernel module source (payload/kernel/ or
# payload/kernel-open/), so a separate i386 .run is not needed for packaging.
# --split-i386 additionally emits ...orig-i386.tar.xz from the i386 .run for the
# rare series where the 64-bit blob lacks compat32.
#
# The .run is a self-extracting makeself archive; extracted read-only with
# --extract-only. Deterministic tar: sorted names, fixed mtime/uid/gid.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need tar; need xz; need sha256sum

series="${1:?usage: assemble-source.sh <series> [outdir] [--split-i386]}"
shift
outdir="$PWD"; split_i386=0
while [ $# -gt 0 ]; do
  case "$1" in
    --split-i386) split_i386=1 ;;
    *) outdir="$(cd "$1" && pwd)" ;;
  esac
  shift
done
version="$(yq_get ".series.\"$series\".version")"
[ -n "$version" ] || die "unknown series $series"
SDE="${SOURCE_DATE_EPOCH:-$(git -C "$COMMON_ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
top="nvidia-legacy-${series}-${version}"

extract() {  # extract() <arch> -> echoes the payload dir
  local arch="$1"
  local run; run="$(yq_get ".series.\"$series\".runs.$arch.run")"
  [ -n "$run" ] || return 1
  local blob="$CACHE_DIR/$run"
  [ -s "$blob" ] || die "missing $blob — run verify-run.sh $series first"
  local exp got
  exp="$(expected_sha "$series" "$arch")"
  got="$(sha256sum "$blob" | awk '{print $1}')"
  { [ "$exp" != "UNVERIFIED" ] && [ -n "$exp" ]; } || die "$series/$arch sha256 not verified"
  [ "$got" = "$exp" ] || die "$series/$arch sha256 mismatch"
  local ex="$work/x-$arch"; mkdir -p "$ex"
  log "extracting $run"
  ( cd "$ex" && sh "$blob" --extract-only >/dev/null 2>&1 </dev/null \
      || sh "$blob" -x >/dev/null 2>&1 </dev/null )
  find "$ex" -maxdepth 1 -type d -name 'NVIDIA-*' | head -1
}

deterministic_tar() {  # deterministic_tar <srcdir-parent> <name> <outfile>
  tar --sort=name --owner=0 --group=0 --numeric-owner \
      --mtime="@${SDE}" --format=gnu --exclude-vcs \
      -C "$1" -cf - "$2" | xz "${NVL_XZ_LEVEL:--6}" -T0 > "$3"
}

payload="$(extract amd64)" || payload="$(extract i386)" || die "no .run for $series"
[ -d "$payload" ] || die "extraction produced no payload dir"
# strip only installer scaffolding we never ship (keep 32/, kernel/, kernel-open/)
rm -rf "$payload"/{.manifest,nvidia-installer,nvidia-installer.1.gz,html,.nvidia-installer.swp} 2>/dev/null || true
mv "$payload" "$work/$top"

tarball="$outdir/${top%-$version}_${version}.orig.tar.xz"
tarball="$outdir/nvidia-legacy-${series}_${version}.orig.tar.xz"
log "packing $(basename "$tarball")"
deterministic_tar "$work" "$top" "$tarball"
( cd "$outdir" && sha256sum "$(basename "$tarball")" )
rm -rf "$work/$top"

if [ "$split_i386" = 1 ]; then
  p32="$(extract i386)" && [ -d "$p32" ] || die "--split-i386: no i386 .run"
  rm -rf "$p32"/{.manifest,nvidia-installer,nvidia-installer.1.gz,html} 2>/dev/null || true
  mv "$p32" "$work/$top"
  t32="$outdir/nvidia-legacy-${series}_${version}.orig-i386.tar.xz"
  log "packing $(basename "$t32")"
  deterministic_tar "$work" "$top" "$t32"
  ( cd "$outdir" && sha256sum "$(basename "$t32")" )
fi
log "done -> $outdir"
