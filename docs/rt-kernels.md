# Real-time / low-latency kernels

## DKMS repo — automatic

The `nvidia-legacy-<series>-kernel-dkms` packages rebuild for **every** installed
kernel that has matching headers, RT included. Nothing series-specific is needed:

- Debian: `apt install linux-image-rt-amd64 linux-headers-rt-amd64` → DKMS builds
  the nvidia modules for `*-rt-amd64` on the next `dpkg-reconfigure` / kernel
  install trigger.
- Ubuntu: `linux-lowlatency` / `linux-lowlatency-hwe-*` works the same way;
  Ubuntu Pro's true `linux-realtime` also (headers from the Pro archive).

CI: `tests/dkms-matrix/kernels.yaml` carries `variant: rt` / `lowlatency`
entries (non-blocking) so a compile regression against the RT config is caught.
The only RT-specific build risk is `PREEMPT_RT`-guarded APIs (raw spinlocks,
`local_lock`, migrate-disable); the compile check flags those.

## Modules repo — explicit per-ABI

Prebuilt `.ko` are ABI-specific, so RT needs its own entries:
`tools/kernels.yaml` lists `*-rt-amd64` / `*-lowlatency` ABIs. `gen-kernel-packages.py`
emits `nvidia-legacy-<series>-kernel-<rt-abi>` exactly like the generic ones;
they `Depends: linux-image-<rt-abi>` and `Provides` the uname-r handle.

Metapackages: `nvidia-legacy-<series>-kernel-rt-amd64` (tracks newest RT ABI)
alongside `...-kernel-amd64`.

## Not covered

- Out-of-tree RT patchsets the user applies themselves (only packaged RT kernels).
- The ancient 173/96/71 series against RT — they barely build against mainline;
  RT is out of scope there.
