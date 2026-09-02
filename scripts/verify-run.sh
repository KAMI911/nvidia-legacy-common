#!/usr/bin/env bash
# verify-run.sh — download and checksum-verify the upstream NVIDIA .run installers.
#
#   verify-run.sh <series> [<series>...]     verify (CI mode: fails on UNVERIFIED)
#   verify-run.sh --all                      verify every series
#   verify-run.sh --update <series>          download and WRITE the sha256 into drivers.yaml
#   verify-run.sh --print-url <series> <arch>
#
# Artifacts land in $NVL_CACHE_DIR (default ~/.cache/nvidia-legacy).
# Exit non-zero if any expected hash is missing/mismatched — this is a release gate.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need curl; need sha256sum

MODE=verify
case "${1:-}" in
  --all)        MODE=verify;  shift; set -- $(series_list) ;;
  --update)     MODE=update;  shift ;;
  --print-url)  run_url "$2" "$3"; exit 0 ;;
  "" )          die "usage: verify-run.sh <series>... | --all | --update <series>" ;;
esac

mkdir -p "$CACHE_DIR"
rc=0

fetch() {
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then return 0; fi
  log "downloading $(basename "$dest")"
  curl -fSL --retry 3 --retry-delay 2 -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

for series in "$@"; do
  yq_get ".series.\"$series\".version" | grep -q . || die "unknown series: $series"
  for arch in amd64 i386; do
    run="$(yq_get ".series.\"$series\".runs.$arch.run")"
    [ -n "$run" ] || continue
    url="$(run_url "$series" "$arch")"
    dest="$CACHE_DIR/$run"
    if ! fetch "$url" "$dest"; then
      warn "$series/$arch: download failed from $url"; rc=1; continue
    fi
    got="$(sha256sum "$dest" | awk '{print $1}')"
    b2="$(b2sum "$dest" 2>/dev/null | awk '{print $1}')"
    exp="$(expected_sha "$series" "$arch")"
    if [ "$MODE" = update ]; then
      log "$series/$arch  sha256=$got"
      [ -n "$b2" ] && log "$series/$arch  blake2b=$b2  (cross-check vs AUR b2sums / Gentoo)"
      if command -v yq >/dev/null 2>&1; then
        yq -i ".series.\"$series\".runs.$arch.sha256 = \"$got\"" "$DRIVERS_YAML"
      else
        python3 - "$DRIVERS_YAML" "$series" "$arch" "$got" <<'PY'
import sys, re
path, series, arch, digest = sys.argv[1:5]
lines = open(path).read().splitlines(keepends=True)
in_series = in_arch = False
for i, ln in enumerate(lines):
    s = ln.rstrip("\n")
    if re.match(rf'^  "{re.escape(series)}":\s*$', s): in_series = True; continue
    if in_series and re.match(r'^  "[^"]+":\s*$', s): in_series = False
    if in_series and re.match(rf'^      {re.escape(arch)}:\s*$', s): in_arch = True; continue
    if in_arch and re.match(r'^      \w+:\s*$', s): in_arch = False
    if in_series and in_arch and 'sha256:' in s:
        lines[i] = re.sub(r'sha256:\s*"[^"]*"', f'sha256: "{digest}"', ln); break
open(path, "w").writelines(lines)
print(f"  wrote {series}/{arch} sha256 into {path}")
PY
      fi
    else
      exp512="$(yq_get ".series.\"$series\".runs.$arch.sha512")"
      got512="$(sha512sum "$dest" | awk '{print $1}')"
      if [ "$exp" = "UNVERIFIED" ] || [ -z "$exp" ]; then
        warn "$series/$arch: drivers.yaml has no verified sha256 (run --update)"; rc=1
      elif [ "$got" != "$exp" ]; then
        warn "$series/$arch: sha256 MISMATCH"; warn "  expected $exp"; warn "  got      $got"; rc=1
      elif [ -n "$exp512" ] && [ "$got512" != "$exp512" ]; then
        warn "$series/$arch: sha512 MISMATCH (sha256 matched — investigate!)"
        warn "  expected $exp512"; warn "  got      $got512"; rc=1
      else
        log "$series/$arch: OK  sha256=$got${exp512:+  sha512 ok}"
      fi
    fi
  done
done
exit $rc
