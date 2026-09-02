# nvidia-legacy-common

Shared source of truth for the two packaging repos:

- [`nvidia-legacy-dkms`](https://github.com/kami911/nvidia-legacy-dkms) — DKMS module, rebuilt per kernel
- [`nvidia-legacy-modules`](https://github.com/kami911/nvidia-legacy-modules) — prebuilt `.ko` per kernel ABI

Both consume this repo as the `common/` git submodule.

## Contents

| Path | What |
|---|---|
| `drivers.yaml` | Every legacy series: version, `.run` URLs + sha256, archs, max Xorg ABI, max kernel. **Edit this, not the templates.** |
| `debian-template/<series>/` | `@TOKEN@` + `%if%` templated `debian/` tree per series |
| `patches/<series>/{build,kernel,xorg}/` | Gated compatibility patches, with `PROVENANCE.toml` |
| `scripts/verify-run.sh` | Download + checksum-verify the upstream installers (release gate) |
| `scripts/assemble-source.sh` | Deterministic `.orig.tar.xz` from a verified `.run` |
| `scripts/render-debian.py` | `debian-template/<series>/` + `drivers.yaml` + target → buildable `debian/` |
| `scripts/apply-patches.sh` | Dry-run / apply the gated patch series (same selection as the renderer) |
| `scripts/import-patches.sh` | Pull patches from Debian / butterfly / Arch / MeowIce for review |

## Series covered

`71xx 96xx 173xx 304xx 340xx 390xx 470xx` — see `drivers.yaml` for per-series
status (`supported` / `best-effort` / `experimental`) and hardware coverage.

## Patch gate naming

`NNNN-desc[.kmax-<maj>.<min>][.abimin-<abi>].patch`

- `.kmax-6.12` → included only when the target's `kernel_max` ≥ 6.12
- `.abimin-25` → included only when the target's `xserver_abi` ≤ 25

## Bumping

1. Change `drivers.yaml` (e.g. new patch, corrected hash via `verify-run.sh --update`).
2. Commit here.
3. In each flavour repo: `git submodule update --remote common && make regen && commit`.
