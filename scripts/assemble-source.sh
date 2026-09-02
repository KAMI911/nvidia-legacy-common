#!/usr/bin/env bash
# assemble-source.sh — build the .orig tarball(s) for a series from verified .run files.
#
#   assemble-source.sh <series> [<outdir>]
#
# Produces, in <outdir> (default $PWD):
#   nvidia-legacy-<series>_<version>.orig.tar.xz          (amd64 payload)
#   nvidia-legacy-<series>_<version>.orig-i386.tar.xz     (i386 payload, if any)
#
# The .run is a self-extracting shell + makeself archive; we extract read-only
# with `--extract-only` equivalent (`-x`) and strip the installer cruft we never
# ship. Deterministic tar: sorted, fixed mtime/uid/gid, no acls/xattrs.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need tar; need xz; need sha256sum

series="${1:?usage: assemble-source.sh <series> [outdir]}"
outdir="$(cd "${2:-$PWD}" && pwd)"
version="$(yq_get ".series.\"$series\".version")"
[ -n "$version" ] || die "unknown series $series"
SDE="${SOURCE_DATE_EPOCH:-$(git -C "$COMMON_ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

pack() {
  local arch="$1" suffix="$2"
  local run; run="$(yq_get ".series.\"$series\".runs.$arch.run")"
  [ -n "$run" ] || return 0
  local blob="$CACHE_DIR/$run"
  [ -s "$blob" ] || die "missing $blob — run verify-run.sh $series first"
  # integrity re-check before we trust the payload
  local exp got
  exp="$(expected_sha "$series" "$arch")"
  got="$(sha256sum "$blob" | awk '{print $1}')"
  [ "$exp" != "UNVERIFIED" ] && [ -n "$exp" ] || die "$series/$arch sha256 not verified"
  [ "$got" = "$exp" ] || die "$series/$arch sha256 mismatch"

  local ex="$work/extract-$arch"; mkdir -p "$ex"
  log "extracting $run"
  ( cd "$ex" && sh "$blob" --target payload -x >/dev/null 2>&1 || \
      sh "$blob" --extract-only >/dev/null 2>&1 || \
      { warn "makeself flags failed, trying -x"; sh "$blob" -x >/dev/null 2>&1; } )
  local payload; payload="$(find "$ex" -maxdepth 1 -type d -name 'NVIDIA-*' -o -maxdepth 1 -type d -name 'payload' | head -1)"
  [ -d "$payload" ] || die "extraction produced no payload dir"

  # drop things we regenerate or never install from the blob
  rm -rf "$payload"/{.manifest,nvidia-installer,nvidia-installer.1.gz,html,kernel-open} 2>/dev/null || true

  local top="nvidia-legacy-$series-$version"
  mv "$payload" "$work/$top"
  local tarball="$outdir/nvidia-legacy-${series}_${version}.orig${suffix}.tar.xz"
  log "packing $(basename "$tarball")"
  tar --sort=name --owner=0 --group=0 --numeric-owner \
      --mtime="@${SDE}" --format=gnu \
      -C "$work" -cf - "$top" | xz "${NVL_XZ_LEVEL:--6}" -T0 > "$tarball"
  ( cd "$outdir" && sha256sum "$(basename "$tarball")" )
  rm -rf "$work/$top"
}

pack amd64 ""
pack i386 "-i386"
log "done -> $outdir"
