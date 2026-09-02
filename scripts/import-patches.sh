#!/usr/bin/env bash
# import-patches.sh — pull compatibility patches from the upstream sources listed
# in patches/<series>/PROVENANCE.toml into patches/<series>/{build,kernel,xorg}/.
#
#   import-patches.sh <series> [--source debian|butterfly|arch|meowice] [--dry-run]
#   import-patches.sh --check <series>     # verify PROVENANCE.toml <-> files match
#
# This does NOT auto-commit. It stages files + prints a diff of PROVENANCE gaps;
# a human reviews licence + attribution before committing (see CONTRIBUTING.md).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need git

if [ "${1:-}" = "--check" ]; then
  s="${2:?usage: import-patches.sh --check <series>}"
  pd="$COMMON_ROOT/patches/$s"
  [ -f "$pd/PROVENANCE.toml" ] || die "no PROVENANCE.toml for $s"
  rc=0
  documented="$(grep -v '^[[:space:]]*#' "$pd/PROVENANCE.toml" | grep -oP 'file[[:space:]]*=[[:space:]]*"\K[^"]+' || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$pd"/}"
    grep -qxF "$rel" <<<"$documented" || { warn "undocumented patch: $rel"; rc=1; }
  done < <(find "$pd" \( -name '*.patch' -o -name '*.patch.*' \) -not -path '*/_incoming/*' | sort)
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -e "$pd/$rel" ] || { warn "PROVENANCE lists missing file: $rel"; rc=1; }
  done <<<"$documented"
  exit $rc
fi

series="${1:?usage: import-patches.sh <series> [--source ID] [--dry-run]}"; shift
pdir="$COMMON_ROOT/patches/$series"
prov="$pdir/PROVENANCE.toml"
[ -f "$prov" ] || die "no PROVENANCE.toml for $series"

DRY=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --source)  ONLY="$2"; shift ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

fetch_source() {
  local id="$1" url="$2" ref="${3:-}"
  log "clone $id <- $url ${ref:+($ref)}"
  git clone --depth 1 ${ref:+--branch "$ref"} "$url" "$work/$id" 2>/dev/null \
    || { warn "clone failed for $id"; return 1; }
}

# Parse the [[source]] blocks with a tiny awk state machine.
python3 - "$prov" "$ONLY" "$DRY" "$pdir" "$work" <<'PY'
import sys, tomllib, subprocess, pathlib, shutil
prov, only, dry, pdir, work = sys.argv[1:6]
doc = tomllib.load(open(prov, "rb"))
pdir, work = pathlib.Path(pdir), pathlib.Path(work)
for src in doc.get("source", []):
    if only and src["id"] != only:
        continue
    dest = work / src["id"]
    ref = src.get("branch")
    cmd = ["git", "clone", "--depth", "1"] + (["--branch", ref] if ref else []) + [src["git"], str(dest)]
    print("::", " ".join(cmd))
    if dry == "1":
        continue
    try:
        subprocess.run(cmd, check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print("   WARN clone failed:", e.stderr.decode()[:200]); continue
    sub = src.get("path", "")
    root = dest / sub if sub else dest
    found = list(root.rglob("*.patch")) + list(root.rglob("*.diff"))
    print(f"   {src['id']}: {len(found)} candidate patch files")
    stage = pdir / "_incoming" / src["id"]
    stage.mkdir(parents=True, exist_ok=True)
    for f in found:
        shutil.copy2(f, stage / f.name)
    print(f"   staged -> {stage}  (review, rename with gates, move into build|kernel|xorg/, document in PROVENANCE.toml)")
PY

log "done. Review $pdir/_incoming/, then:"
log "  1. rename each kept patch with its .kmax-*/.abimin-* gate"
log "  2. move into $pdir/{build,kernel,xorg}/"
log "  3. add a [[patch]] block to PROVENANCE.toml (from, origin_commit, fixes, license)"
log "  4. run: import-patches.sh --check $series"
