#!/bin/sh
# build-prebuilt-module.sh <payload-dir> <dkms-name> <version>
# Used by the `modules` flavour: compile the .ko set against the kernel headers
# present in the build chroot, then stage them for the per-ABI binary package.
#
# The OBS/sbuild chroot for the `modules` flavour installs exactly one
# linux-headers-<ABI> package; KVER is derived from it. render-debian.py emits
# one source package per ABI, so this runs once per ABI.
set -eu
PAYLOAD="$1"; NAME="$2"; VER="$3"

KVER="$(ls -1 /lib/modules/ | sort -V | tail -1)"
KSRC="/lib/modules/$KVER/build"
[ -d "$KSRC" ] || { echo "no kernel headers in chroot"; exit 1; }

STAGE="debian/tmp/lib/modules/$KVER/updates/dkms"
install -d "$STAGE"

BUILD="$(mktemp -d)"
cp -a "$PAYLOAD/kernel/." "$BUILD/"
for p in $(ls debian/patches/kernel/*.patch debian/patches/build/*.patch 2>/dev/null | sort); do
  echo "  module-patch $p"
  patch -d "$BUILD" -p1 --no-backup-if-mismatch < "$p"
done

make -C "$BUILD" -j"$(nproc)" KERNEL_UNAME="$KVER" SYSSRC="$KSRC" modules
for ko in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
  [ -f "$BUILD/$ko.ko" ] && install -m 0644 "$BUILD/$ko.ko" "$STAGE/$ko.ko" || echo "  (no $ko.ko)"
done
# record the ABI so the .install file / dh_gencontrol substvar can pick it up
echo "$KVER" > debian/kver.stamp
echo "build-prebuilt-module.sh: staged modules for $KVER"
