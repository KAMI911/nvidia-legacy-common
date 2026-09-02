#!/usr/bin/env python3
"""render-debian.py — render debian-template/<series>/ into a buildable debian/ tree.

    render-debian.py --series 390xx --target debian13 [--out DIR] [--distro-suite trixie]

What it does:
  * loads drivers.yaml for the series + target facts
  * decides IgnoreABI / best-effort from xorg_abi_max vs target.xserver_abi
  * expands @TOKEN@ substitutions and %if FLAG% / %else% / %endif% blocks in every
    file under debian-template/<series>/ (recursively; a `.in` suffix is stripped)
  * writes debian/patches/series by concatenating the applicable patch lists
    (see scripts/apply-patches.sh for the same selection logic)
  * prepends a debian/changelog entry with a reproducible timestamp

Deterministic: file order sorted, timestamps come from SOURCE_DATE_EPOCH or the
newest git commit touching common/, never `now`.
"""
from __future__ import annotations
import argparse, os, re, subprocess, sys, datetime, pathlib
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml required")

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKEN = re.compile(r"@([A-Z0-9_]+)@")
COND = re.compile(r"^\s*%(if|elif|else|endif)\b\s*(.*?)\s*$")


def sh(*a: str) -> str:
    return subprocess.check_output(a, cwd=ROOT, text=True).strip()


def source_date_epoch() -> int:
    if "SOURCE_DATE_EPOCH" in os.environ:
        return int(os.environ["SOURCE_DATE_EPOCH"])
    try:
        return int(sh("git", "log", "-1", "--format=%ct"))
    except Exception:
        return 0


def load_cfg(series: str, target: str) -> dict:
    doc = yaml.safe_load((ROOT / "drivers.yaml").read_text())
    if series not in doc["series"]:
        sys.exit(f"unknown series {series!r}; have {', '.join(doc['series'])}")
    if target not in doc["targets"]:
        sys.exit(f"unknown target {target!r}; have {', '.join(doc['targets'])}")
    s, t = doc["series"][series], doc["targets"][target]
    if not s.get("modern_feasible", True):
        sys.exit(f"{series} is modern_feasible: false — not buildable for {target}")
    abi_gap = t["xserver_abi"] > s["xorg_abi_max"]
    # x_via:
    #   "distro-xorg"    (default) — nvidia_drv.so loads on the distro X server
    #                    (natively, or with IgnoreABI when abi_gap)
    #   "legacy-xserver" — needs the private old xorg-server-legacy-nvidia-<abi>;
    #                    never ship xserver-xorg-video-*, Recommend the legacy server
    x_via = s.get("x_via", "distro-xorg")
    x_cap = s.get("x_driver_max_abi", s["xorg_abi_max"])
    x_driver_gap = x_via == "legacy-xserver" or t["xserver_abi"] > x_cap
    best_effort = s["status"] != "supported" or abi_gap
    archs = [a for a in s["architectures"] if a != "i386" or t["i386_kernel"] or True]
    kernel_archs = [a for a in s["architectures"]
                    if a != "i386" or t["i386_kernel"]]
    return {
        "SERIES": series,
        "SERIES_NUM": re.sub(r"\D", "", series),
        "VERSION": s["version"],
        "DKMS_NAME": f"nvidia-legacy-{series}",
        "DKMS_VERSION": s["version"],
        "MODULE_SOURCE": s.get("module_source", "kernel"),
        "MODULE_LICENSE": s.get("module_license", "NVIDIA"),
        "GPU_FAMILIES": s["gpu_families"],
        # collapse folded-scalar newlines: a blank line would break a d/control field
        "EOL_NOTE": " ".join(str(s["eol_note"]).split()),
        "STATUS": s["status"],
        "CODENAME": t["codename"],
        "OBS_REPO": t["obs_repo"],
        "TARGET": target,
        "XORG_ABI_MAX": str(s["xorg_abi_max"]),
        "TARGET_XSERVER_ABI": str(t["xserver_abi"]),
        "KERNEL_MAX": s["kernel_max"],
        "DEFAULT_KERNEL": t["default_kernel"],
        "LIB_ARCHS": " ".join(s["lib_architectures"]),
        "KERNEL_ARCHS": " ".join(kernel_archs),
        "ALL_ARCHS": " ".join(sorted(set(s["lib_architectures"]) | set(kernel_archs))),
        # flags for %if%
        "X_VIA": x_via,
        "X_LEGACY_ABI": str(x_cap),
        "_flags": {
            "ignoreabi": abi_gap and x_via == "distro-xorg",
            "x_driver_gap": x_driver_gap,
            "has_x_driver": not x_driver_gap,
            "legacy_xserver": x_via == "legacy-xserver",
            "best_effort": best_effort,
            "i386_kernel": "i386" in kernel_archs,
            "egl": s["provides_egl"],
            "vulkan": s["provides_vulkan"],
            "nvenc": s["provides_nvenc"],
            "vdpau": s.get("provides_vdpau", True),
            "insecure": series in ("340xx", "304xx", "173xx", "96xx", "71xx"),
            "open_module": s.get("module_source") == "kernel-open",
        },
        "_sde": source_date_epoch(),
    }


def expand_conditionals(text: str, flags: dict) -> str:
    out, stack = [], [True]
    for line in text.splitlines(keepends=True):
        m = COND.match(line)
        if not m:
            if all(stack):
                out.append(line)
            continue
        kind, expr = m.group(1), m.group(2)
        if kind == "if":
            stack.append(bool(flags.get(expr.strip())))
        elif kind == "elif":
            stack[-1] = not stack[-1] and bool(flags.get(expr.strip()))
        elif kind == "else":
            stack[-1] = not stack[-1]
        elif kind == "endif":
            stack.pop() if len(stack) > 1 else None
    return "".join(out)


def expand_tokens(text: str, cfg: dict) -> str:
    def repl(m: re.Match) -> str:
        k = m.group(1)
        if k not in cfg:
            sys.exit(f"undefined template token @{k}@")
        return str(cfg[k])
    return TOKEN.sub(repl, text)


def render_tree(src: pathlib.Path, dst: pathlib.Path, cfg: dict) -> None:
    for path in sorted(src.rglob("*")):
        rel = path.relative_to(src)
        if path.is_dir():
            (dst / rel).mkdir(parents=True, exist_ok=True)
            continue
        target = dst / rel
        if target.name.endswith(".in"):
            target = target.with_name(target.name[:-3])
        target.parent.mkdir(parents=True, exist_ok=True)
        raw = path.read_bytes()
        try:
            txt = raw.decode()
        except UnicodeDecodeError:
            target.write_bytes(raw)
            os.chmod(target, path.stat().st_mode)
            continue
        txt = expand_conditionals(txt, cfg["_flags"])
        txt = expand_tokens(txt, cfg)
        target.write_text(txt)
        os.chmod(target, path.stat().st_mode)


def write_patch_series(series: str, cfg: dict, dst: pathlib.Path) -> None:
    pdir = ROOT / "patches" / series
    if not pdir.is_dir():
        return
    kmax = tuple(int(x) for x in cfg["KERNEL_MAX"].split("."))
    lines: list[str] = []
    for bucket in ("build", "kernel", "xorg"):
        bdir = pdir / bucket
        if not bdir.is_dir():
            continue
        for patch in sorted(bdir.glob("*.patch")):
            # gate by filename convention: NNNN-desc[.kmax-6.12][.abi-25].patch
            mk = re.search(r"\.kmax-(\d+)\.(\d+)", patch.name)
            ma = re.search(r"\.abimin-(\d+)", patch.name)
            if mk and (int(mk.group(1)), int(mk.group(2))) < kmax:
                continue
            if ma and int(ma.group(1)) > int(cfg["TARGET_XSERVER_ABI"]):
                continue
            lines.append(f"{bucket}/{patch.name}")
    (dst / "patches").mkdir(parents=True, exist_ok=True)
    for rel in lines:
        srcp = pdir / rel
        outp = dst / "patches" / rel
        outp.parent.mkdir(parents=True, exist_ok=True)
        outp.write_bytes(srcp.read_bytes())
    (dst / "patches" / "series").write_text(
        "".join(f"{l}\n" for l in lines) if lines else "")


def prepend_changelog(dst: pathlib.Path, cfg: dict) -> None:
    cl = dst / "changelog"
    dt = datetime.datetime.fromtimestamp(cfg["_sde"], datetime.timezone.utc)
    rfc = dt.strftime("%a, %d %b %Y %H:%M:%S +0000")
    pkg = f"nvidia-legacy-{cfg['SERIES']}"
    deb_ver = f"{cfg['VERSION']}-0nvl1~{cfg['CODENAME']}1"
    entry = (
        f"{pkg} ({deb_ver}) {cfg['CODENAME']}; urgency=medium\n\n"
        f"  * Reproducible build of NVIDIA {cfg['VERSION']} ({cfg['SERIES']} legacy series)\n"
        f"    for {cfg['TARGET']} ({cfg['CODENAME']}).\n"
        f"  * Rendered by render-debian.py from nvidia-legacy-common @ "
        f"{cfg.get('_commit', 'WORKTREE')}.\n\n"
        f" -- nvidia-legacy CI <ci@nvidia-legacy.invalid>  {rfc}\n\n"
    )
    prev = cl.read_text() if cl.exists() else ""
    cl.write_text(entry + prev)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--series", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--flavour", default="dkms", choices=["dkms", "modules"])
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    cfg = load_cfg(args.series, args.target)
    cfg["FLAVOUR"] = args.flavour
    cfg["_flags"]["dkms"] = args.flavour == "dkms"
    cfg["_flags"]["modules"] = args.flavour == "modules"
    try:
        cfg["_commit"] = sh("git", "rev-parse", "--short", "HEAD")
    except Exception:
        cfg["_commit"] = "WORKTREE"

    tmpl = ROOT / "debian-template" / args.series / "debian"
    if not tmpl.is_dir():
        sys.exit(f"no template dir: {tmpl}")
    out = pathlib.Path(args.out or (ROOT.parent / f"packaging/{args.series}/{args.target}"))
    debian = out / "debian"
    if debian.exists():
        subprocess.run(["rm", "-rf", str(debian)], check=True)
    render_tree(tmpl, debian, cfg)
    write_patch_series(args.series, cfg, debian)
    prepend_changelog(debian, cfg)
    print(f"rendered -> {debian}")
    if cfg["_flags"]["best_effort"]:
        print("  NOTE: best-effort target (status != supported or Xorg ABI gap); "
              "CI treats failures as non-blocking.")


if __name__ == "__main__":
    main()
