#!/usr/bin/env bash
# Install the built image and the boot script on a TrueNAS SCALE 25.10 host.
# Needs an SSH user with passwordless sudo (TrueNAS: user > "Allow all sudo
# commands with no password").
#
# Usage: ./install.sh <ssh-host>
set -euo pipefail
NAS=${1:?usage: $0 <ssh-host>}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -s "$HERE/out/nvidia.raw" ] || { echo "run ./build.sh first" >&2; exit 1; }

echo "==> Copying image and boot script to $NAS:/var/lib/truenas-custom/"
scp -q "$HERE/out/nvidia.raw" "$HERE/nvidia-proprietary.sh" "$NAS:/tmp/"
ssh "$NAS" 'sudo mkdir -p /var/lib/truenas-custom &&
  sudo mv /tmp/nvidia.raw /var/lib/truenas-custom/nvidia.raw &&
  sudo mv /tmp/nvidia-proprietary.sh /var/lib/truenas-custom/nvidia-proprietary.sh &&
  sudo chown root:root /var/lib/truenas-custom/* && sudo chmod 755 /var/lib/truenas-custom/nvidia-proprietary.sh'

echo "==> Applying now (no reboot needed)"
ssh "$NAS" 'sudo /var/lib/truenas-custom/nvidia-proprietary.sh; sudo tail -6 /var/log/nvidia-proprietary.log'

cat <<EOF

==> One manual step, in the TrueNAS UI:
    System > Advanced > Init/Shutdown Scripts > Add
      Type:     Script
      Script:   /var/lib/truenas-custom/nvidia-proprietary.sh
      When:     Pre Init
      Timeout:  120
      Enabled:  yes
    Then enable the GPU on your apps (Apps > app > Edit > Resources > GPU)
    *after* nvidia-smi works, never while the GPU is down.
EOF
