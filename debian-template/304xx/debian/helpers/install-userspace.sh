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

# i386 build: the 32-bit libraries live in the amd64 .run's 32/ subdir. Binaries
# and Xorg modules are 64-bit only — an i386 build ships libraries only.
LIBS_ONLY=0
case "$MA" in
  i386-linux-gnu)
    [ -d "$PAYLOAD/32" ] && PAYLOAD_LIBS="$PAYLOAD/32" || PAYLOAD_LIBS="$PAYLOAD"
    LIBS_ONLY=1 ;;
  *) PAYLOAD_LIBS="$PAYLOAD" ;;
esac

install -d "$LIBDIR" "$DEST/usr/bin" \
          "$DEST/usr/lib/xorg/modules/drivers" \
          "$DEST/usr/lib/xorg/modules/extensions" \
          "$DEST/usr/share/doc/nvidia-legacy-driver-libs" \
          "$DEST/usr/share/vulkan/icd.d" \
          "$DEST/etc/vulkan/icd.d"

soname() {   # echo the DT_SONAME of $1, or empty
  ${OBJDUMP:-objdump} -p "$1" 2>/dev/null | awk '/SONAME/{print $2; exit}'
}

# GLVND driver? It ships libGLX_nvidia.so.* (the vendor implementation). On such
# a driver the bundled libGL/libGLX/libEGL/libGLESv* and libGLdispatch/libOpenGL
# are just NVIDIA's private copy of libglvnd — Debian and Ubuntu always provide
# the system libglvnd, so shipping them file-conflicts with libgl1/libglx0/
# libegl1. Pre-GLVND series (304/340/17x) ship their own libGL.so.N: keep it.
GLVND=0
for f in "$PAYLOAD_LIBS"/libGLX_nvidia.so.*; do
  [ -e "$f" ] && { GLVND=1; break; }
done

# --- shared objects: every versioned .so the payload ships ------------------
# NB: a runtime driver package ships libfoo.so.VER and the SONAME link
# libfoo.so.N — but NOT the bare libfoo.so (that is a -dev symlink).
for so in "$PAYLOAD_LIBS"/*.so."$VER" "$PAYLOAD_LIBS"/*.so.[0-9]*; do
  [ -e "$so" ] || continue
  b="$(basename "$so")"
  case "$b" in
    tls_test_dso.so|*_test_*.so|libvdpau.so.*|libvdpau_trace.so.*|libnvidia-pkcs11.so.*|libGLdispatch.so.*|libOpenGL.so.*|libOpenCL.so.*) continue ;;
    libGL.so.*|libGLX.so.*|libEGL.so.*|libGLESv1_CM.so.*|libGLESv2.so.*)
      # GLVND dispatch libs — ship only when the driver has no libGLX_nvidia
      if [ "$GLVND" = 1 ]; then continue; fi ;;
    nvidia_drv.so)
      [ "$LIBS_ONLY" = 1 ] && continue
      install -m0644 "$so" "$DEST/usr/lib/xorg/modules/drivers/$b"; continue ;;
    libglxserver_nvidia.so.*|libglx.so.*)
      [ "$LIBS_ONLY" = 1 ] && continue
      install -m0644 "$so" "$DEST/usr/lib/xorg/modules/extensions/$b"; continue ;;
  esac
  install -m0644 "$so" "$LIBDIR/$b"
  sn="$(soname "$so" || true)"
  [ -n "$sn" ] && [ "$sn" != "$b" ] && ln -sf "$b" "$LIBDIR/$sn" || true
done

# --- ICD / vendor json + docs (arch-independent; installed for BOTH arches so
#     Multi-Arch: same driver-libs has identical files) ---------------------
[ -e "$PAYLOAD/10_nvidia.json" ] && install -D -m0644 "$PAYLOAD/10_nvidia.json" \
  "$DEST/usr/share/glvnd/egl_vendor.d/10_nvidia.json" || true
for j in nvidia_icd.json nvidia_icd.json.template nvidia_layers.json; do
  [ -e "$PAYLOAD/$j" ] && install -D -m0644 "$PAYLOAD/$j" \
    "$DEST/usr/share/vulkan/icd.d/${j%.template}" || true
done
for L in LICENSE NVIDIA_Changelog README.txt; do
  [ -e "$PAYLOAD/$L" ] && install -D -m0644 "$PAYLOAD/$L" \
    "$DEST/usr/share/doc/nvidia-legacy-driver-libs/$L" || true
done
# guarantee the doc dir is non-empty even if the payload lacks LICENSE
[ -e "$DEST/usr/share/doc/nvidia-legacy-driver-libs/LICENSE" ] || \
  printf 'NVIDIA %s userspace — see debian/copyright\n' "$VER" \
    > "$DEST/usr/share/doc/nvidia-legacy-driver-libs/README.nvidia-legacy"

[ "$LIBS_ONLY" = 1 ] && { echo "install-userspace.sh: i386 libs-only"; exit 0; }

# --- Xorg driver + GLX extension (64-bit only) ------------------------------
[ -e "$PAYLOAD/nvidia_drv.so" ] && install -D -m0644 "$PAYLOAD/nvidia_drv.so" \
  "$DEST/usr/lib/xorg/modules/drivers/nvidia_drv.so" || true
for g in "$PAYLOAD"/libglx.so."$VER" "$PAYLOAD"/libglxserver_nvidia.so."$VER"; do
  [ -e "$g" ] && install -m0644 "$g" "$DEST/usr/lib/xorg/modules/extensions/$(basename "$g")" || true
done

# --- utilities (64-bit only) ----------------------------------------------
for b in nvidia-smi nvidia-debugdump nvidia-cuda-mps-control nvidia-cuda-mps-server \
         nvidia-persistenced nvidia-modprobe nvidia-xconfig nvidia-settings \
         nvidia-sleep.sh nvidia-bug-report.sh; do
  [ -e "$PAYLOAD/$b" ] && install -m0755 "$PAYLOAD/$b" "$DEST/usr/bin/$b" || true
done

echo "install-userspace.sh: staged $(find "$LIBDIR" -name '*.so*' | wc -l) lib entries for $MA"
