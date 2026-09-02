#!/bin/sh
# install-userspace.sh <payload-dir> <destdir> <multiarch-triplet> <version>
#
# Lay out the prebuilt NVIDIA userspace from the extracted .run into <destdir>,
# using paths the *.install / *.links files then split into binary packages.
#
# Strategy: copy EVERY versioned shared object the payload ships into
# usr/lib/<MA>/, then synthesise the SONAME (.so.N) and dev (.so) symlinks from
# each object's DT_SONAME. The *.install globs (libfoo.so.*) pick them up; what
# a series does not ship simply is not there.
set -eu
PAYLOAD="$1"; DEST="$2"; MA="$3"; VER="$4"
LIBDIR="$DEST/usr/lib/$MA"
S="$(basename "$(dirname "$0")")"      # unused; kept for parity

install -d "$LIBDIR" "$DEST/usr/bin" \
          "$DEST/usr/lib/xorg/modules/drivers" \
          "$DEST/usr/lib/xorg/modules/extensions" \
          "$DEST/usr/share/doc/nvidia-legacy-driver-libs" \
          "$DEST/usr/share/vulkan/icd.d" \
          "$DEST/etc/vulkan/icd.d"

soname() {   # echo the DT_SONAME of $1, or empty
  ${OBJDUMP:-objdump} -p "$1" 2>/dev/null | awk '/SONAME/{print $2; exit}'
}

# --- shared objects: everything the payload ships at top level ---------------
for so in "$PAYLOAD"/*.so."$VER" "$PAYLOAD"/*.so.1 "$PAYLOAD"/*.so; do
  [ -e "$so" ] || continue
  b="$(basename "$so")"
  case "$b" in
    nvidia_drv.so)        install -m0644 "$so" "$DEST/usr/lib/xorg/modules/drivers/$b"; continue ;;
    libglxserver_nvidia.*|libglx.so.*) install -m0644 "$so" "$DEST/usr/lib/xorg/modules/extensions/$b"; continue ;;
  esac
  install -m0644 "$so" "$LIBDIR/$b"
  # SONAME link
  sn="$(soname "$so" || true)"
  if [ -n "$sn" ] && [ "$sn" != "$b" ]; then
    ln -sf "$b" "$LIBDIR/$sn"
  fi
  # bare dev link libFoo.so -> libFoo.so.SONAME (only for libs that carry one)
  stem="${b%%.so.*}"
  [ -n "$sn" ] && ln -sf "$sn" "$LIBDIR/${stem}.so" 2>/dev/null || true
done

# --- Xorg driver + GLX extension (also matched above, be explicit) -----------
[ -e "$PAYLOAD/nvidia_drv.so" ] && install -m0644 "$PAYLOAD/nvidia_drv.so" \
  "$DEST/usr/lib/xorg/modules/drivers/nvidia_drv.so" || true
for g in "$PAYLOAD"/libglx.so."$VER" "$PAYLOAD"/libglxserver_nvidia.so."$VER"; do
  [ -e "$g" ] && install -m0644 "$g" "$DEST/usr/lib/xorg/modules/extensions/$(basename "$g")" || true
done

# --- utilities --------------------------------------------------------------
for b in nvidia-smi nvidia-debugdump nvidia-cuda-mps-control nvidia-cuda-mps-server \
         nvidia-persistenced nvidia-modprobe nvidia-xconfig nvidia-settings \
         nvidia-sleep.sh nvidia-bug-report.sh; do
  [ -e "$PAYLOAD/$b" ] && install -m0755 "$PAYLOAD/$b" "$DEST/usr/bin/$b" || true
done

# --- ICD / json manifests --------------------------------------------------
for j in "$PAYLOAD"/nvidia_icd.json* "$PAYLOAD"/nvidia_layers.json "$PAYLOAD"/10_nvidia.json; do
  [ -e "$j" ] && install -m0644 "$j" "$DEST/usr/share/vulkan/icd.d/$(basename "$j" .template)" || true
done

# --- licence / docs ------------------------------------------------------
for L in LICENSE NVIDIA_Changelog README.txt; do
  [ -e "$PAYLOAD/$L" ] && install -m0644 "$PAYLOAD/$L" \
    "$DEST/usr/share/doc/nvidia-legacy-driver-libs/$L" || true
done

echo "install-userspace.sh: staged $(find "$LIBDIR" -name '*.so*' | wc -l) lib entries for $MA"
