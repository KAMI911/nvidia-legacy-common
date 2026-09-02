#!/usr/bin/env python3
"""render-xserver.py --abi 23 [--out DIR]

Render xserver-legacy/debian/ for one old xorg-server (from xservers.yaml) into a
buildable source tree. Mirrors render-debian.py's @TOKEN@ / %if% handling but for
the xorg-server-legacy-nvidia-<abi> package.
"""
from __future__ import annotations
import argparse, os, pathlib, re, sys, datetime, subprocess
try:
    import yaml
except ImportError:
    sys.exit("python3-yaml required")

ROOT = pathlib.Path(__file__).resolve().parent.parent
XS = ROOT / "xserver-legacy"
TOKEN = re.compile(r"@([A-Z0-9_]+)@")


def sde() -> int:
    if "SOURCE_DATE_EPOCH" in os.environ:
        return int(os.environ["SOURCE_DATE_EPOCH"])
    try:
        return int(subprocess.check_output(["git", "-C", str(ROOT), "log", "-1", "--format=%ct"], text=True))
    except Exception:
        return 0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--abi", required=True)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    doc = yaml.safe_load((XS / "xservers.yaml").read_text())["servers"]
    entry = next((v for v in doc.values() if str(v["video_abi"]) == str(a.abi)), None)
    if not entry:
        sys.exit(f"no xserver with video_abi {a.abi} in xservers.yaml")

    cfg = {
        "XABI": str(entry["video_abi"]),
        "XVER": entry["version"],
        "SERVES": entry["serves"][0],
        "STATUS": entry["status"],
        "TARBALL": entry["tarball"],
        "SHA256": entry["sha256"],
    }
    out = pathlib.Path(a.out or (ROOT.parent / f"packaging/xserver-{a.abi}"))
    debian = out / "debian"
    if debian.exists():
        subprocess.run(["rm", "-rf", str(debian)], check=True)

    for path in sorted((XS / "debian").rglob("*")):
        rel = path.relative_to(XS / "debian")
        dst = debian / (rel.with_name(rel.name[:-3]) if rel.name.endswith(".in") else rel)
        if path.is_dir():
            dst.mkdir(parents=True, exist_ok=True)
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            txt = path.read_text()
        except UnicodeDecodeError:
            dst.write_bytes(path.read_bytes()); os.chmod(dst, path.stat().st_mode); continue
        txt = TOKEN.sub(lambda m: cfg.get(m.group(1), m.group(0)), txt)
        dst.write_text(txt); os.chmod(dst, path.stat().st_mode)

    # wrapper files travel with the package
    wdst = debian / "wrapper"
    wdst.mkdir(parents=True, exist_ok=True)
    for w in (XS / "wrapper").iterdir():
        (wdst / w.name).write_bytes(w.read_bytes())
        os.chmod(wdst / w.name, 0o755 if not w.name.endswith(".desktop") else 0o644)

    dt = datetime.datetime.fromtimestamp(sde(), datetime.timezone.utc)
    (debian / "changelog").write_text(
        f"xorg-server-legacy-nvidia-{cfg['XABI']} ({cfg['XVER']}-0nvl1) unstable; urgency=medium\n\n"
        f"  * Private xorg-server {cfg['XVER']} (video ABI {cfg['XABI']}) for NVIDIA "
        f"{cfg['SERVES']}.\n\n"
        f" -- nvidia-legacy CI <ci@nvidia-legacy.invalid>  "
        f"{dt.strftime('%a, %d %b %Y %H:%M:%S +0000')}\n")
    print(f"rendered -> {debian}  (status: {cfg['STATUS']})")


if __name__ == "__main__":
    main()
