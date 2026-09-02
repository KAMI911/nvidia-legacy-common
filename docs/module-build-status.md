# DKMS module build — status per series

The userspace + packaging is green for every series (smoke-build, reprotest).
This tracks the **kernel module** compile against modern kernels — the harder half.

| Series | Patch set | Builds on | Blocker |
|---|---|---|---|
| 580xx / 580xx-open | none needed (active upstream) | 6.16 | — (needs a real header set to confirm) |
| 470xx | joanbm / AUR nvidia-470xx-utils (to 7.3) | not yet imported | import + gate |
| 390xx | megvadulthangya nvidia-390xx-utils 0001–0021 (imported) | **fails on 6.12** | conftest: `#error kmem_cache_create() conftest failed!` + `nv_stdarg.h: stdarg.h: No such file` — the conftest compile picks the wrong `LINUX_VERSION_CODE` branch. Likely a patch-order / `conftest.sh` include-path issue. See below. |
| 340xx | megvadulthangya nvidia-340xx (per-kernel PKGBUILDs) | not yet imported | import + gate |
| 304xx | flydiscohuebr/nvidia-304 (held in _needs-build-test) | ~7.0 once re-homed | strip-level fix |
| 173/96/71xx | forward-port track (roadmap only) | — | see forward-port-status/ |

## 390xx / Linux 6.12 — what to fix next

1. Apply the 20 patches **strictly** (`patch -Np1`, no `-F3` fuzz) in `sort -V`
   order into a fresh `kernel/` tree and confirm each applies with zero offset.
2. Build with the exact dkms invocation
   `make -j KERNEL_UNAME=<ver> IGNORE_CC_MISMATCH=1 modules` from the module root,
   with `linux-headers-<ver>` + `gcc` matching the kernel's.
3. The first hard error is `conftest failed` for base APIs (`on_each_cpu`,
   `INIT_WORK` …) that still exist — meaning `conftest.sh`'s test snippets don't
   compile. Check: does `kernel-6.2.patch` / `kernel-6.8.patch` touch
   `conftest.sh` or `common/inc/nv_stdarg.h`? The `<stdarg.h>` vs
   `<linux/stdarg.h>` guard must resolve to the linux one on ≥ 5.15.
4. Once conftest compiles, work the errors kernel-version by kernel-version;
   the hangya patches are cumulative and ordered — a skipped hunk breaks a later one.

Reference apply order (from the nvidia-390xx-utils PKGBUILD `prepare()`):
4.16-mem-enc, 6.1-flag, 6.2, 6.3, 6.4, 6.5, 6.6, 6.8, gcc-14, 6.10, 6.12, 6.13,
make-modesetting, 6.14, gcc-15, 6.15, 6.17, 6.19, 7.0, 7.2.
