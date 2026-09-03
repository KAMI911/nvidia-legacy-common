#!/bin/sh
# build-prebuilt-module.sh <payload-dir> <dkms-name> <version>
# `modules` flavour: compile the .ko set against the single linux-headers-<ABI>
# package the build chroot installed, then stage it for the per-ABI binary
# package. render/gen-kernel-packages emit one source package per ABI, so this
# runs once per ABI.
set -eu
PAYLOAD="$1"; NAME="$2"; VER="$3"

# the chroot has exactly one kernel headers tree
KVER="$(ls -1 /lib/modules/ 2>/dev/null | sort -V | tail -1)"
KSRC="/lib/modules/$KVER/build"
[ -n "$KVER" ] && [ -d "$KSRC" ] || { echo "no kernel headers in chroot"; exit 1; }
echo "build-prebuilt-module.sh: KVER=$KVER"

STAGE="debian/tmp/lib/modules/$KVER/updates/dkms"
install -d "$STAGE"

BUILD="$(mktemp -d)"
# modular layout (390/470/580) ships kernel/; flat legacy (340/304/17x) may ship
# kernel/ or usr/src/nv
SRCD=kernel
[ -d "$PAYLOAD/$SRCD" ] || SRCD="$(test -d "$PAYLOAD/usr/src/nv" && echo usr/src/nv || echo kernel)"
cp -a "$PAYLOAD/$SRCD/." "$BUILD/"

for p in $(ls debian/patches/kernel/*.patch* debian/patches/build/*.patch* 2>/dev/null | sort -V); do
  echo "  module-patch $(basename "$p")"
  patch -d "$BUILD" -p1 --forward --no-backup-if-mismatch -F3 -r /dev/null < "$p" || test $? -le 1
done

# Build exactly the way DKMS does (proven on Debian split headers): pass
# KERNEL_UNAME so NVIDIA's Makefile picks /lib/modules/$KVER/build itself —
# do NOT force SYSSRC (that misroutes conftest -> "stdarg.h: No such file").
# modular kernel/Makefile has a `modules` target; flat legacy has `module`.
if grep -qE '^modules:' "$BUILD/Makefile" 2>/dev/null; then
  make -C "$BUILD" -j"$(nproc)" IGNORE_PREEMPT_RT_PRESENCE=1 KERNEL_UNAME="$KVER" modules
else
  make -C "$BUILD" -j"$(nproc)" IGNORE_PREEMPT_RT_PRESENCE=1 KERNEL_UNAME="$KVER" module
  [ -d "$BUILD/uvm" ] && make -C "$BUILD/uvm" IGNORE_PREEMPT_RT_PRESENCE=1 \
    KERNEL_UNAME="$KVER" KBUILD_EXTMOD="$BUILD/uvm" module || true
fi

n=0
for ko in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
  f="$(find "$BUILD" -name "$ko.ko" -print -quit 2>/dev/null || true)"
  if [ -n "$f" ]; then install -m0644 "$f" "$STAGE/$ko.ko"; n=$((n+1)); else echo "  (no $ko.ko)"; fi
done
[ "$n" -gt 0 ] || { echo "no .ko built"; exit 1; }
echo "$KVER" > debian/kver.stamp
echo "build-prebuilt-module.sh: staged $n module(s) for $KVER"
