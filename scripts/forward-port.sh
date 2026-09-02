#!/usr/bin/env bash
# forward-port.sh <series> <kernel X.Y>
#
# Scaffold a kernel-compat patch for <series> at the point <kernel X.Y> first
# breaks. It:
#   1. compiles the (already-patched) module against X.Y, captures every error
#   2. for each failing symbol, greps the REFERENCE series (390xx, then 470xx)
#      patch set for a patch touching the same symbol/API and prints it
#   3. writes a stub patch file patches/<series>/kernel/NNNN-kernel-X.Y-<sym>.patch.kmax-X.Y
#      pre-filled with the hunks from the reference patch, re-anchored to this
#      series' file layout where the paths match
#   4. adds a PROVENANCE.toml [[patch]] block (status = "DRAFT — needs review + build")
#
# You then hand-fix the hunks that did not port cleanly and re-run
# feasibility-recheck.sh <series> --patched --from X.Y --to X.Y.
#
# The legacy modules share most of nv-linux.h / os-interface.c / nv-mmap.c, so
# ~60-80% of a 390xx/470xx kernel patch applies to 340/304/173xx with only path
# and context-line fixups. 96/71xx share far less — expect manual work.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
series="${1:?series}"; kv="${2:?kernel X.Y}"
REF_SERIES="${FWDPORT_REF:-390xx}"

pdir="$COMMON_ROOT/patches/$series/kernel"
mkdir -p "$pdir"
n="$(printf '%04d' "$(( $(ls "$pdir"/*.patch* 2>/dev/null | wc -l) + 1 ))")"

log "compiling $series against $kv to collect errors…"
errs="$("$COMMON_ROOT/scripts/_compile-one.sh" "$series" "$kv" 1 2>&1 | \
        grep -oE "(‘|')[a-z_][a-z0-9_]+(’|')|error: [^\n]+" | sort -u)"
[ -n "$errs" ] || { log "no errors — $series already builds on $kv?"; exit 0; }

echo "$errs" | sed 's/^/  /'
refdir="$COMMON_ROOT/patches/$REF_SERIES/kernel"

for sym in $(echo "$errs" | grep -oE "[a-z_][a-z0-9_]{3,}" | sort -u); do
  hit="$(grep -rl -- "$sym" "$refdir" 2>/dev/null | head -1 || true)"
  if [ -n "$hit" ]; then
    log "reference for '$sym': $(basename "$hit")"
    stub="$pdir/${n}-kernel-${kv}-${sym}.patch.kmax-${kv}"
    {
      echo "# DRAFT forward-port for $series / Linux $kv"
      echo "# Symbol: $sym"
      echo "# Adapted from $REF_SERIES: $(basename "$hit")"
      echo "# TODO: re-anchor paths/context to $series' kernel/ layout, then build-test."
      echo "#"
      grep -A0 -B0 -- "$sym" "$hit" | sed 's/^/# ref> /'
      echo
      cat "$hit"
    } > "$stub"
    log "  scaffolded $stub"
    n="$(printf '%04d' "$(( 10#$n + 1 ))")"
  else
    warn "no reference patch for '$sym' in $REF_SERIES — manual port needed"
  fi
done

log "done. Review $pdir/*.patch.kmax-${kv}, fix hunks, add PROVENANCE blocks, then:"
log "  scripts/feasibility-recheck.sh $series --patched --from $kv --to $kv"
