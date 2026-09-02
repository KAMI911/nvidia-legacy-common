#!/usr/bin/env bash
# Shared helpers for the nvidia-legacy-common scripts. Source, don't execute.
set -euo pipefail

COMMON_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVERS_YAML="${DRIVERS_YAML:-$COMMON_ROOT/drivers.yaml}"
CACHE_DIR="${NVL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nvidia-legacy}"

log()  { printf '\033[1;34m[nvl]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[nvl] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[nvl] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# yq (mikefarah, v4) is the query engine. Fall back to a tiny python shim so the
# scripts still run on a bare machine.
yq_get() {
  # yq_get '.series.390xx.version'
  if command -v yq >/dev/null 2>&1; then
    yq -r "$1 // \"\"" "$DRIVERS_YAML"
  else
    python3 - "$DRIVERS_YAML" "$1" <<'PY'
import sys, yaml, re
doc = yaml.safe_load(open(sys.argv[1]))
# tokenise .a."b c".d[0] into ['a', 'b c', 'd', 0]
parts = re.findall(r'"([^"]+)"|\[(\d+)\]|([^.\[\]]+)', sys.argv[2])
cur = doc
for q, idx, bare in parts:
    if cur is None:
        break
    if idx:
        cur = cur[int(idx)]
    else:
        cur = (cur or {}).get(q or bare)
print('' if cur is None else cur)
PY
  fi
}

series_list() {
  if command -v yq >/dev/null 2>&1; then
    yq -r '.series | keys | .[]' "$DRIVERS_YAML"
  else
    python3 - "$DRIVERS_YAML" <<'PY'
import sys, yaml
print('\n'.join(yaml.safe_load(open(sys.argv[1]))['series']))
PY
  fi
}

run_url() {
  # run_url <series> <arch>
  local series="$1" arch="$2"
  local ver run kind tmpl arch_dir
  ver="$(yq_get ".series.\"$series\".version")"
  run="$(yq_get ".series.\"$series\".runs.$arch.run")"
  kind="$(yq_get ".series.\"$series\".runs.$arch.url_kind")"
  [ -n "$run" ] || die "no .run defined for $series/$arch"
  case "$arch" in
    amd64) arch_dir="x86_64" ;;
    i386)  arch_dir="x86" ;;
    *) die "unknown arch $arch" ;;
  esac
  if [ "$kind" = "legacy" ]; then
    tmpl="$(yq_get '.defaults.url_template_legacy')"
  else
    tmpl="$(yq_get '.defaults.url_template')"
  fi
  echo "${tmpl//\{arch_dir\}/$arch_dir}" | sed "s|{ver}|$ver|g; s|{run}|$run|g"
}

expected_sha() { yq_get ".series.\"$1\".runs.$2.sha256"; }
