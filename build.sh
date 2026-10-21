#!/usr/bin/env bash
# Build a TrueNAS SCALE 25.10 NVIDIA sysext image that carries the *proprietary*
# kernel modules, so pre-Turing GPUs (Maxwell, Pascal, Volta) work again.
#
# What it does:
#   1. copies the kernel headers and the stock nvidia.raw sysext from the NAS
#   2. downloads the matching NVIDIA .run installer and verifies its checksum
#   3. builds the proprietary modules (installer's kernel/ tree) against those
#      headers inside a Debian 12 container with the kernel's own GCC
#   4. repackages the stock sysext with the proprietary .ko files swapped in
#
# Usage:  ./build.sh <ssh-host>            e.g. ./build.sh truenas.local
# Output: out/nvidia.raw  (install with install.sh)
set -euo pipefail

NAS=${1:?usage: $0 <ssh-host>}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/work}
OUT=$HERE/out
IMAGE=nvbuild-truenas:deb12
NV_URL_BASE=https://us.download.nvidia.com/XFree86/Linux-x86_64

say() { printf '\n==> %s\n' "$*"; }

say "Reading kernel and driver versions from $NAS"
KVER=$(ssh "$NAS" uname -r)
NVVER=$(ssh "$NAS" 'modinfo -F version nvidia 2>/dev/null || ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.* | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1')
[ -n "$KVER" ] && [ -n "$NVVER" ] || { echo "could not read versions from $NAS" >&2; exit 1; }
echo "kernel $KVER, NVIDIA userspace $NVVER"

mkdir -p "$WORK" "$OUT"

say "Copying kernel headers"
rsync -a --delete "$NAS:/usr/src/linux-headers-truenas-production-amd64/" "$WORK/headers/"
for f in Module.symvers include/config/auto.conf include/generated/autoconf.h scripts/mod/modpost; do
  [ -e "$WORK/headers/$f" ] || { echo "headers incomplete: missing $f" >&2; exit 1; }
done

say "Copying stock sysext image"
scp -q "$NAS:/usr/share/truenas/sysext-extensions/nvidia.raw" "$WORK/stock-nvidia.raw"

say "Downloading NVIDIA-Linux-x86_64-$NVVER-no-compat32.run"
RUN="$WORK/NVIDIA-Linux-x86_64-$NVVER-no-compat32.run"
[ -s "$RUN" ] || curl -fL --retry 3 -o "$RUN" "$NV_URL_BASE/$NVVER/NVIDIA-Linux-x86_64-$NVVER-no-compat32.run"
sh "$RUN" --check >/dev/null
rm -rf "$WORK/src"; sh "$RUN" --extract-only --target "$WORK/src" >/dev/null
[ -d "$WORK/src/kernel" ] || { echo "installer has no proprietary kernel/ tree" >&2; exit 1; }

say "Building container image ($IMAGE)"
docker build -q -t "$IMAGE" "$HERE/docker" >/dev/null

say "Compiling proprietary modules for $KVER"
docker run --rm -v "$WORK:/w" -w /w/src/kernel "$IMAGE" \
  make -j"$(nproc)" SYSSRC=/w/headers SYSOUT=/w/headers modules >"$WORK/build.log" 2>&1 \
  || { tail -30 "$WORK/build.log" >&2; exit 1; }
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
  [ -s "$WORK/src/kernel/$m.ko" ] || { echo "missing $m.ko" >&2; exit 1; }
done

say "Repackaging sysext"
docker run --rm -v "$WORK:/w" "$IMAGE" bash -euo pipefail -c "
  rm -rf /w/sx && mkdir -p /w/sx && cd /w/sx
  unsquashfs -q -d root /w/stock-nvidia.raw >/dev/null
  D=root/usr/lib/modules/$KVER/kernel/drivers/video
  [ -d \"\$D\" ] || { echo 'stock image has no modules for $KVER' >&2; exit 1; }
  for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
    s=\$(modinfo -F depends \$D/\$m.ko); n=\$(modinfo -F depends /w/src/kernel/\$m.ko)
    [ \"\$s\" = \"\$n\" ] || { echo \"dependency mismatch for \$m: stock [\$s] vs built [\$n]\" >&2; exit 1; }
    cp /w/src/kernel/\$m.ko \$D/\$m.ko
  done
  [ \"\$(modinfo -F license \$D/nvidia.ko)\" = NVIDIA ] || { echo 'built module is not proprietary?' >&2; exit 1; }
  mksquashfs root /w/nvidia.raw -comp xz -noappend -quiet -no-progress
"
mv "$WORK/nvidia.raw" "$OUT/nvidia.raw"
sha256sum "$OUT/nvidia.raw" | tee "$OUT/nvidia.raw.sha256"

say "Done: $OUT/nvidia.raw (kernel $KVER, driver $NVVER, proprietary modules)"
echo "Next: ./install.sh $NAS"
