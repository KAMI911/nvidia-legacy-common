#!/usr/bin/env bash
# _compile-one.sh <series> <kernel X.Y> <patched 0|1>
# Extract the module source from the verified .run, optionally apply the gated
# patch series, and `make modules` against mainline X.Y headers in a container.
# Prints build output then a final line: OK | FAIL | SKIP
set -uo pipefail
. "$(dirname "$0")/lib.sh"
series="$1"; kv="$2"; patched="$3"
ver="$(yq_get ".series.\"$series\".version")"
run="$(yq_get ".series.\"$series\".runs.amd64.run")"
blob="$CACHE_DIR/$run"
[ -s "$blob" ] || { "$COMMON_ROOT/scripts/verify-run.sh" "$series" >/dev/null 2>&1 || true; }
[ -s "$blob" ] || { echo SKIP; exit 0; }

command -v podman >/dev/null && OCI=podman || OCI=docker
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
( cd "$work" && sh "$blob" -x >/dev/null 2>&1 )
top="$(find "$work" -maxdepth 1 -type d -name 'NVIDIA-*' | head -1)"
# modern layout: kernel/ ; legacy 173/96/71: usr/src/nv/
if   [ -d "$top/kernel" ];      then src="$top/kernel"
elif [ -d "$top/usr/src/nv" ];  then src="$top/usr/src/nv"
else echo "FAIL (no kernel source dir in payload)"; exit 0; fi

if [ "$patched" = 1 ]; then
  "$COMMON_ROOT/scripts/apply-patches.sh" "$series" debian13 "$src" --apply || true
fi

# mainline headers: kernel.org "linux-headers" aren't packaged; use a Debian
# 'linux-source' + oldconfig, or a prebuilt image. Here: debian:sid + the
# closest linux-headers, falling back to building headers from linux-source.
cat > "$work/build.sh" <<EOF
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev kmod wget xz-utils cpio >/dev/null
KV=$kv
# try the distro's own headers first
if apt-get install -y -qq "linux-headers-\${KV}"* 2>/dev/null && ls -d /lib/modules/\${KV}* >/dev/null 2>&1; then
  KSRC=\$(ls -d /lib/modules/\${KV}*/build | head -1)
else
  # fetch mainline source, prepare headers only
  MAJ=\${KV%%.*}
  wget -q "https://cdn.kernel.org/pub/linux/kernel/v\${MAJ}.x/linux-\${KV}.tar.xz" -O /tmp/l.tar.xz \
    || wget -q "https://git.kernel.org/torvalds/t/linux-\${KV}.tar.gz" -O /tmp/l.tar.xz
  mkdir -p /usr/src/l && tar xf /tmp/l.tar.xz -C /usr/src/l --strip-components=1
  cd /usr/src/l && make -s defconfig && make -s modules_prepare
  KSRC=/usr/src/l
fi
cd /src
KU=\$(basename \$(dirname \$KSRC) 2>/dev/null || echo \$KV)
# modern NVIDIA: 'modules' target in kernel/Makefile.
# legacy 173/96/71: 'module' target via Makefile.kbuild.
if [ -f Makefile ] && grep -q '^modules:' Makefile 2>/dev/null; then
  make -j\$(nproc) SYSSRC="\$KSRC" KERNEL_UNAME=\$KU modules 2>&1
elif [ -f Makefile.kbuild ]; then
  make -j\$(nproc) -f Makefile.kbuild SYSSRC="\$KSRC" KERNELDIR="\$KSRC" module 2>&1
else
  make -j\$(nproc) SYSSRC="\$KSRC" KERNEL_UNAME=\$KU module 2>&1
fi
EOF

log_output="$($OCI run --rm -v "$src":/src:ro -v "$work/build.sh":/build.sh:ro \
  debian:sid bash /build.sh 2>&1)"
echo "$log_output"
if printf '%s' "$log_output" | grep -qE '\.ko$|Building modules, stage 2|LD \[M\]'; then
  echo OK
elif printf '%s' "$log_output" | grep -q 'linux-headers.* Unable to locate\|Could not resolve'; then
  echo SKIP
else
  echo FAIL
fi
