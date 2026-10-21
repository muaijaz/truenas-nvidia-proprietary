# Proprietary NVIDIA driver for TrueNAS SCALE 25.10 (Pascal / Maxwell / Volta)

TrueNAS SCALE 25.10 "Goldeye" ships NVIDIA's **open** kernel modules (driver
branch 580). The open modules only drive GPUs with a GSP, which means Turing
and newer. Older cards fail at probe time:

```
NVRM: The NVIDIA GPU 0000:01:00.0 (PCI ID: 10de:1b80)
NVRM: installed in this system is not supported by open
NVRM: nvidia.ko because it does not include the required GPU
NVRM: System Processor (GSP).
```

This repo builds the **proprietary** modules for the exact TrueNAS kernel and
drops them into TrueNAS's own NVIDIA system-extension image, so everything
else (userspace libraries, `nvidia-smi`, the container toolkit, the Apps GPU
toggle) keeps working unchanged. The root filesystem is never modified.

Tested on 25.10.7, kernel `6.12.105-production+truenas`, driver 580.173.02,
GeForce GTX 1080: `nvidia-smi` works, Jellyfin hardware transcoding (NVENC and
NVDEC) works inside the app container, survives reboots.

## How it works

* TrueNAS delivers NVIDIA support as a `systemd-sysext` image,
  `/usr/share/truenas/sysext-extensions/nvidia.raw`, merged onto `/usr` when
  Apps > Settings > "Install NVIDIA drivers" is on. That image contains the
  userspace **and** the (open) kernel modules.
* The kernel headers are present on the NAS under
  `/usr/src/linux-headers-truenas-production-amd64`, complete enough to build
  out-of-tree modules. The kernel allows unsigned modules
  (`CONFIG_MODULE_SIG` without `_FORCE`, lockdown off).
* `build.sh` compiles the proprietary modules from the same NVIDIA `.run`
  installer TrueNAS used (its `kernel/` tree instead of `kernel-open/`) in a
  Debian 12 container with the kernel's own GCC, then rebuilds the sysext with
  those `.ko` files swapped in. Module dependency names are identical, so the
  stock `modules.dep` is kept as is.
* `nvidia-proprietary.sh` runs at **Pre Init**: it repoints the
  `/run/extensions/nvidia.raw` symlink to the custom image, refreshes sysext,
  loads the driver and checks `nvidia-smi` (with a PCI bus reset and retry if
  the first init fails). Running at Pre Init matters: at Post Init it races the
  middleware's own `modprobe` and Docker's container start, and the GPU can
  drop off the bus (Xid 79).
* If TrueNAS updates the kernel, the script detects that the image does not
  match and leaves the stock driver in place. Rebuild with `build.sh` and
  reinstall.

## Requirements

* A build machine with Docker, `ssh`, `rsync`, `curl` (the NAS itself cannot
  compile; its `/usr` is read-only).
* SSH access to the NAS as a user with passwordless sudo.
* Apps > Settings > "Install NVIDIA drivers" enabled on the NAS (this is what
  creates the stock sysext the build reuses).

## Use

```
./build.sh   my-nas       # ~2 minutes; output in out/nvidia.raw
./install.sh my-nas       # copies image + script, applies it live
```

Then register the script once in the UI: System > Advanced > Init/Shutdown
Scripts > Add, Type *Script*, Script
`/var/lib/truenas-custom/nvidia-proprietary.sh`, When *Pre Init*, Timeout 120.

Finally enable the GPU on your apps (Apps > app > Edit > Resources > GPU
Configuration). For NVIDIA cards this is the per-GPU checkbox, not "use all
GPUs"; the latter only covers Intel and AMD devices.

## Gotchas learned the hard way

* **Never edit or redeploy a GPU app while the GPU is down.** TrueNAS silently
  unticks the GPU on that app if the card is not visible at update time. You
  then have to re-tick it.
* **Xid 79 "GPU has fallen off the bus" under load is power, not software.**
  Give the card its own PCIe power cables from the PSU; a single lead
  pigtailed into 8+6 pins did exactly this.
* **A PCI remove/rescan followed by a warm reboot can leave the link at x1.**
  A cold power cycle retrains it to full width.
* The script logs to `/var/log/nvidia-proprietary.log`.

## Rolling back

Delete the init script in the UI, then on the NAS:

```
sudo rm -f /run/extensions/nvidia.raw
sudo ln -s /usr/share/truenas/sysext-extensions/nvidia.raw /run/extensions/nvidia.raw
sudo systemd-sysext refresh
```

or simply reboot without the init script. `/var/lib/truenas-custom` can be
deleted at any time.

## Credit

The sysext approach was pioneered by
[zzzhouuu/truenas-nvidia-drivers](https://github.com/zzzhouuu/truenas-nvidia-drivers),
which rebuilds the image inside the full TrueNAS build system. That project's
R580 builds ended up with open modules because the installer now defaults to
open when `--kernel-module-type` is omitted; the fix there is to pass
`--kernel-module-type=proprietary`. This repo takes a lighter route that needs
only the headers already on the NAS.
