#!/bin/bash
# TrueNAS SCALE 25.10: swap the stock NVIDIA sysext (open kernel module, Turing+
# only) for a locally built proprietary image so Maxwell/Pascal/Volta GPUs work.
# Install: copy to /var/lib/truenas-custom/nvidia-proprietary.sh, chmod 755,
# register in TrueNAS as System > Advanced > Init/Shutdown Scripts, type Script,
# when PRE INIT (so the driver is swapped before the middleware's own modprobe and
# before Docker starts any GPU container), timeout 120. Safe to re-run by hand.
set -u
CUSTOM=/var/lib/truenas-custom/nvidia.raw
LINK=/run/extensions/nvidia.raw
LOG=/var/log/nvidia-proprietary.log
exec >>"$LOG" 2>&1
echo "=== $(date -Is) start kernel=$(uname -r)"
[ -f "$CUSTOM" ] || { echo "custom image missing, leaving stock"; exit 0; }
# Refuse an image built for a different kernel (after a TrueNAS update, rebuild first)
if ! unsquashfs -l "$CUSTOM" "usr/lib/modules/$(uname -r)/kernel/drivers/video/nvidia.ko" >/dev/null 2>&1; then
  echo "custom image has no modules for $(uname -r); leaving stock (rebuild needed)"; exit 0
fi
echo performance > /sys/module/pcie_aspm/parameters/policy 2>/dev/null && echo "aspm policy=performance"
if [ "$(readlink -f "$LINK")" != "$CUSTOM" ]; then
  for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do rmmod "$m" 2>/dev/null; done
  mkdir -p /run/extensions; ln -sfn "$CUSTOM" "$LINK"
  systemd-sysext refresh && ldconfig && echo "sysext swapped to custom image"
fi
# First NVIDIA VGA/3D controller on the bus (vendor 10de), e.g. 0000:01:00.0
GPU=$(lspci -Dn 2>/dev/null | awk '$2 ~ /^03/ && $3 ~ /^10de:/ {print $1; exit}')
echo "gpu pci address: ${GPU:-not found}"
load_and_check() {
  modprobe -a nvidia nvidia_drm nvidia_modeset nvidia_uvm || return 1
  nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
}
# First init after POST sometimes drops the card off the bus (Xid 79); a PCI
# remove/rescan before the driver touches it again clears that. Retry twice.
attempt=0
until load_and_check; do
  attempt=$((attempt+1)); echo "init attempt $attempt failed (license=$(modinfo -F license nvidia))"
  [ "$attempt" -ge 3 ] && { echo "giving up; GPU needs a reboot/power cycle"; break; }
  for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do rmmod "$m" 2>/dev/null; done
  [ -n "$GPU" ] && [ -e "/sys/bus/pci/devices/$GPU/remove" ] && echo 1 > "/sys/bus/pci/devices/$GPU/remove"; sleep 3
  echo 1 > /sys/bus/pci/rescan; sleep 5
done
echo "modules loaded: license=$(modinfo -F license nvidia)"
# Persistence mode keeps the GPU initialized after the last client exits, so
# the card is brought up once per boot instead of on every open (each init is
# a chance for a marginal card to drop off the bus with Xid 79).
nvidia-smi -pm 1 >/dev/null 2>&1 && echo "persistence mode on" || echo "persistence mode not set"
# Redeploy RUNNING apps that have an NVIDIA GPU selected so their containers get
# the device (at PRE INIT nothing is running yet, so this only matters on re-runs)
for app in $(for n in $(midclt call app.query 2>/dev/null | python3 -c 'import sys,json; print(" ".join(a["name"] for a in json.load(sys.stdin) if a.get("state")=="RUNNING"))'); do
    midclt call app.config "$n" 2>/dev/null | python3 -c '
import sys,json
sel=(json.load(sys.stdin).get("resources") or {}).get("gpus",{}).get("nvidia_gpu_selection") or {}
if any(g.get("use_gpu") for g in sel.values()): print(sys.argv[1])' "$n"
  done); do
  echo "redeploying $app"; midclt call -j app.redeploy "$app" >/dev/null 2>&1 || echo "redeploy $app failed"
done
echo "=== done"
