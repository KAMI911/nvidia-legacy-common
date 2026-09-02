# Can the older NVIDIA legacy series still run? (feasibility study)

Two separate questions per series: **(a)** does the *kernel module* still build
against current kernels, and **(b)** does the *X driver* still load against the
X server the target distro ships. They have very different answers.

## Summary table

| Series | Driver | GPUs | Kernel module ceiling | X driver ceiling (xserver / video ABI) | Verdict on our targets (Debian ≥11 / Ubuntu ≥20.04) |
|---|---|---|---|---|---|
| **580xx** | 580.95.05 | Maxwell/Pascal/Volta | active upstream (≥6.16) | current (ABI 25) | ✅ full |
| **470xx** | 470.256.02 | Kepler | ~7.3 (AUR/joanbm/hangya) | current (ABI 25) | ✅ full |
| **390xx** | 390.157 | Fermi/Kepler | ~7.2 (hangya nvidia-390xx-utils) | ABI 25 w/ IgnoreABI | ✅ full (X = best-effort on 25) |
| **340xx** | 340.108 | GeForce 8–300 | ~7.2 (hangya nvidia-340xx) | ABI 24; 25 w/ IgnoreABI | ✅ full (X best-effort on 25); ⚠ security |
| **304xx** | 304.137 | GeForce 6/7 | **~7.0** (flydiscohuebr, 30 patches) | **ABI ≤ 23 only** (xorg-server ≤ 1.19) | ⚠ **kernel module + compute/VDPAU yes; X only on old targets** |
| **173xx** | 173.14.39 | GeForce FX 5xxx | **~4.13** (breaks at 4.14: `spin_unlock_wait`) | xserver ≤ 1.15 | ❌ not on any current target |
| **96xx** | 96.43.23 | GeForce 2–4 Ti | **~3.13** | xserver ≤ 1.12 | ❌ |
| **71xx** | 71.86.15 | TNT2 / GF2-4 MX | **~2.6.38** | xserver ≤ 1.4 | ❌ |

## 304xx — the interesting middle case

The kernel module is genuinely maintainable: `flydiscohuebr/nvidia-304`
(active 2026, 34★) carries `0001..0030` patches taking 304.137 from kernel
3.19 to **7.0**, plus gcc-14/15 fixes.

The blocker is X. 304.137's `nvidia_drv.so` + `libglx.so` target xserver video
driver **ABI 23 (xorg-server 1.19)**. On 1.20 (ABI 24, Debian 11 / Ubuntu 20.04)
and 1.21 (ABI 25) `IgnoreABI` gets you past the version check but GLX then fails
on missing/renamed server symbols and input handling differs. Upstream community
workaround = *rebuild and pin xorg-server 1.19* (which flydiscohuebr does) — not
portable to Debian/Ubuntu where the whole desktop expects the distro X server.

**Our approach for 304xx:**

- `debian12` / `debian13` / `ubuntu2204` / `ubuntu2404` (ABI 25):
  ship `nvidia-legacy-304xx-kernel-dkms` + `-driver-libs` (+ `:i386`) +
  `-vdpau-driver` + `-driver-bin`. **Do not** ship
  `xserver-xorg-video-nvidia-legacy-304xx`. Package description says
  "compute / VDPAU / offline render only — no X acceleration on this release".
- `debian11` / `ubuntu2004` (ABI 24): additionally ship the X driver as
  **best-effort** with `IgnoreABI` and a `debconf` warning. CI records the
  `xorg-dummy` result but does not gate on it.
- render-debian.py already computes `abi_gap = target.xserver_abi > series.xorg_abi_max`;
  the 304xx template drops the `xserver-xorg-video-*` binary package when
  `x_driver_max_abi < target.xserver_abi`.

## 173 / 96 / 71xx — kept as metadata only

`drivers.yaml` keeps their entries (`status: unsupported-modern`,
`modern_feasible: false`) for documentation and in case someone adds a
Debian-10-era "vintage" target later. `regen.sh` / `gen-kernel-packages.py` /
the CI matrix all skip any series with `modern_feasible: false`. They are **not**
in either repo's `series.yaml` build set.

Why they can't move forward:

- **173.14**: the module uses `spin_unlock_wait()`, removed in Linux 4.14
  (commit 952111d7db02). No shim exists; the code paths that need it
  (RM lock semantics) are not trivially portable. Also depends on
  `struct file_operations` / `get_user_pages` signatures from the 3.x era.
- **96.43 / 71.86**: additionally pre-date the `Module.symvers` / modern Kbuild
  layout and the pci_driver API changes of 3.8; the X drivers pre-date
  RandR 1.2. Effectively frozen at their release-era stack.

## Rechecking

`common/scripts/feasibility-recheck.sh <series>` (TODO) will, per series:
attempt a `dkms build` of the raw upstream module against the newest kernel in
`tests/dkms-matrix/kernels.yaml` with **no** patches, then with the candidate
patch set, and report the first failing kernel. Run it when a new patch source
appears (e.g. someone revives 173xx).
