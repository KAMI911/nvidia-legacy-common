#!/usr/bin/env bash
# apply-patches.sh — dry-run / apply the gated patch series for a (series, target).
#
#   apply-patches.sh <series> <target> <source-tree> [--check|--apply]
#
# Selection logic MUST match render-debian.py:write_patch_series():
#   patches/<series>/{build,kernel,xorg}/NNNN-desc[.kmax-<maj>.<min>][.abimin-<n>].patch
#     .kmax-6.12  -> skipped when target kernel_max < 6.12
#     .abimin-25  -> skipped when target xserver_abi < 25
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need patch

series="${1:?series}"; target="${2:?target}"; tree="${3:?source tree}"
mode="${4:---check}"
pdir="$COMMON_ROOT/patches/$series"
[ -d "$pdir" ] || { log "no patches for $series"; exit 0; }

kmax="$(yq_get ".series.\"$series\".xorg_abi_max")"   # placeholder, real gate below
kernel_max="$(yq_get ".series.\"$series\".kernel_max")"
tgt_abi="$(yq_get ".targets.$target.xserver_abi")"
[ -n "$tgt_abi" ] || die "unknown target $target"
IFS=. read -r kmaj kmin <<<"$kernel_max"

selected=()
for bucket in build kernel xorg; do
  [ -d "$pdir/$bucket" ] || continue
  while IFS= read -r p; do
    b="$(basename "$p")"
    if [[ "$b" =~ \.kmax-([0-9]+)\.([0-9]+) ]]; then
      pk="${BASH_REMATCH[1]}"; pm="${BASH_REMATCH[2]}"
      (( kmaj > pk || (kmaj == pk && kmin >= pm) )) || continue
    fi
    if [[ "$b" =~ \.abimin-([0-9]+) ]]; then
      (( tgt_abi >= BASH_REMATCH[1] )) || continue
    fi
    selected+=("$bucket/$b")
  done < <(find "$pdir/$bucket" -maxdepth 1 -name '*.patch' | sort)
done

log "$series/$target: ${#selected[@]} patch(es) selected"
rc=0
for rel in "${selected[@]}"; do
  if [ "$mode" = --apply ]; then
    log "apply $rel"
    patch -d "$tree" -p1 --no-backup-if-mismatch < "$pdir/$rel" || { rc=1; break; }
  else
    if ! patch -d "$tree" -p1 --dry-run --silent < "$pdir/$rel" >/dev/null; then
      warn "would NOT apply cleanly: $rel"; rc=1
    fi
  fi
done
exit $rc
