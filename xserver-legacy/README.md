# xorg-server-legacy-nvidia

Co-installable, **private-path** old X servers for the legacy NVIDIA blobs whose
`nvidia_drv.so` / `libglx.so` will not load on the distribution's X server.

You cannot patch the closed `nvidia_drv.so` to a newer ABI — this is the
supported way to keep the old X driver usable.

## What gets installed

```
/opt/nvidia-legacy/xserver-<abi>/bin/Xorg          the old server
/opt/nvidia-legacy/xserver-<abi>/lib/xorg/modules/ its modules (+ the nvidia blob, symlinked in)
/usr/bin/nvidia-legacy-xserver                     wrapper: picks the right xserver-<abi> for the installed driver
/usr/lib/nvidia-legacy/Xorg.wrap                   setuid helper (rootless-X not available on 1.19)
/usr/share/xsessions/nvidia-legacy.desktop         "Xorg (NVIDIA legacy)" login-manager session
/usr/share/nvidia-legacy/xorg-legacy.conf          generated Device/Screen/ServerFlags
```

The distro Xorg, Wayland sessions and everything else are untouched. The user
picks "Xorg (NVIDIA legacy)" at the greeter only when they need the old GPU's
acceleration.

## Which server for which driver

`xservers.yaml` maps driver series → xorg-server version → video ABI:

| Driver | Server | Video ABI | Status |
|---|---|---|---|
| 304xx | 1.19.7 | 23 | best-effort |
| 173xx | 1.15.1 | 19 | experimental |
| 96xx  | 1.12.4 | 12 | experimental |
| 71xx  | 1.4.2  | 2  | experimental |

340xx/390xx do **not** need this — their blobs load on the distro Xorg with
`IgnoreABI` (video ABI 24/25).

## Building an old server on a modern toolchain

Old `xorg-server` does not compile with gcc-14/15, openssl-3, current
`libxcvt`/`libtirpc`, or without `RPC`/`XKB` bits that moved. Per-version build
patches live in `debian/patches/<version>/`. The 1.19 set is the smallest;
1.15 and older are a real patch queue and are marked experimental.
`verify-xserver.sh` pins each tarball's sha256 the same way `verify-run.sh` does
for the driver blobs.

## Security

An old X server is a **larger** attack surface than the distro one and gets no
upstream fixes. `debian/patches/<version>/security/` backports the CVEs that
matter for a local session (input, XKB, render). The package Description and a
`debconf` note say this plainly. Same "isolated / offline machine" advice as the
`unsupported-modern` drivers.
