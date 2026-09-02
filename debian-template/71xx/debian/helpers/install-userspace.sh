#!/bin/sh
# install-userspace.sh <payload-dir> <destdir> <multiarch-triplet> <version>
# Lay out the prebuilt NVIDIA userspace from the extracted .run payload into
# debian/tmp, using paths the *.install files then split into binary packages.
set -eu
PAYLOAD="$1"; DEST="$2"; MA="$3"; VER="$4"
LIBDIR="$DEST/usr/lib/$MA"
NVDIR="$LIBDIR/nvidia/legacy-71xx"

install -d "$LIBDIR" "$NVDIR" "$DEST/usr/bin" "$DEST/usr/share/doc/nvidia-legacy-71xx-driver-libs" \
          "$DEST/usr/lib/xorg/modules/drivers" "$DEST/usr/lib/xorg/modules/extensions"

copy() { [ -e "$PAYLOAD/$1" ] && install -m "$3" "$PAYLOAD/$1" "$2" || echo "  (skip $1)"; }

# --- core runtime libraries (driver-libs) ---
for so in libnvidia-glcore libnvidia-tls libnvidia-eglcore libnvidia-glsi \
          libnvidia-ml libnvidia-cfg libnvidia-fatbinaryloader \
          libnvidia-encode libnvidia-opencl libvdpau_nvidia; do
  copy "${so}.so.$VER" "$LIBDIR/${so}.so.$VER" 0644
done

# --- GL / GLX (libgl1-...-glx) ---
copy "libGL.so.$VER"          "$LIBDIR/libGL.so.$VER" 0644
copy "libnvidia-glvkspirv.so.$VER" "$LIBDIR/libnvidia-glvkspirv.so.$VER" 0644
copy "libglx.so.$VER"         "$DEST/usr/lib/xorg/modules/extensions/libglx.so.$VER" 0644

# --- Xorg video driver ---
copy "nvidia_drv.so"          "$DEST/usr/lib/xorg/modules/drivers/nvidia_drv.so" 0644

# --- utilities (driver-bin) ---
for b in nvidia-smi nvidia-debugdump nvidia-cuda-mps-control nvidia-cuda-mps-server \
         nvidia-persistenced nvidia-modprobe nvidia-xconfig nvidia-settings; do
  copy "$b" "$DEST/usr/bin/$b" 0755
done

# --- license / docs ---
copy "LICENSE" "$DEST/usr/share/doc/nvidia-legacy-71xx-driver-libs/LICENSE" 0644

# ldconfig-style dev symlinks are created by the *.links files, not here.
echo "install-userspace.sh: done ($MA)"
