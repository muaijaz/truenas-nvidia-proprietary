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
  the first init fails), then turns on persistence mode so the card is
  initialized once per boot rather than on every client open.
  Running at Pre Init matters: at Post Init it races the
  middleware's own `modprobe` and Docker's container start, and the GPU can
  drop off the bus (Xid 79).
* If TrueNAS updates the kernel, the script detects that the image does not
  match and leaves the stock driver in place. Rebuild with `build.sh` and
  reinstall.

## Setup, step by step

You need two machines: the NAS, and any Linux or macOS box with Docker to do
the compiling (the NAS cannot compile; its root filesystem is read-only).
About 15 minutes the first time.

### 1. On the NAS: enable SSH with passwordless sudo

1. **Credentials > Users**, edit your admin user (usually `truenas_admin`).
   Tick **SSH Access**, paste your build machine's public key into
   **Authorized Keys**, and tick **Allow all sudo commands with no password**.
   Leave *SSH password login* off.
2. **System > Services**, turn **SSH** on and tick *Start Automatically*.
3. From the build machine, confirm both work:

   ```
   ssh truenas_admin@<nas-ip> 'sudo -n true && echo sudo ok'
   ```

   Optional: add an entry to `~/.ssh/config` so you can refer to the NAS by a
   short name. The scripts take anything `ssh` accepts (`my-nas`,
   `truenas_admin@10.0.0.12`, ...).

### 2. On the NAS: turn on TrueNAS's NVIDIA support

**Apps > Settings**, tick **Install NVIDIA Drivers**. This needs an Apps
pool to be configured. It will *not* make your GPU work yet (the stock
module refuses pre-Turing cards and logs the GSP error), but it installs the
stock system-extension image that this project builds on. Confirm it exists:

```
ssh my-nas ls -la /usr/share/truenas/sysext-extensions/nvidia.raw
```

### 3. On the build machine: install the tools

Docker, `git`, `ssh`, `rsync`, `curl`. On Debian/Ubuntu:

```
sudo apt install docker.io git rsync curl
```

The build runs inside a `debian:12` container so the compiler matches the
one TrueNAS built its kernel with (GCC 12). Nothing else is installed on
your machine.

### 4. Build

```
git clone https://github.com/muaijaz/truenas-nvidia-proprietary.git
cd truenas-nvidia-proprietary
./build.sh my-nas
```

The script reads the kernel and driver versions from the NAS, copies the
headers and the stock image, downloads the matching NVIDIA installer
(about 330 MB, checksum-verified), compiles, and writes `out/nvidia.raw`.
It stops if anything does not line up: missing headers, no proprietary tree
in the installer, a dependency mismatch, or a module that is not proprietary.

### 5. Install

```
./install.sh my-nas
```

This copies the image and the boot script to `/var/lib/truenas-custom/` on
the NAS (that directory is on the boot pool, survives reboots, and is outside
the read-only root) and applies the swap immediately. Expect
`modules loaded: license=NVIDIA` and your GPU's name in the output, and
`ssh my-nas nvidia-smi` should now list the card.

### 6. Register the boot script (one time, in the UI)

**System > Advanced > Init/Shutdown Scripts > Add**

| Field | Value |
|---|---|
| Description | NVIDIA proprietary driver |
| Type | Script |
| Script | `/var/lib/truenas-custom/nvidia-proprietary.sh` |
| When | **Pre Init** |
| Enabled | yes |
| Timeout | 120 |

*Pre Init* is required. At *Post Init* the script races the middleware's own
driver load and Docker's container start, and the GPU can drop off the bus.

Reboot once and check that `ssh my-nas nvidia-smi` comes back on its own.

### 7. Give the GPU to your apps

For each app that should use it (Jellyfin, Plex, Immich, Frigate, ...):
**Apps > the app > Edit > Resources Configuration > GPU Configuration**, tick
the checkbox for your NVIDIA card. Do **not** rely on "Use all GPUs"; that
switch only covers Intel and AMD devices. Save; the app redeploys with the
device.

Do this only while `nvidia-smi` works. TrueNAS silently unticks the GPU on
an app if the card is not visible at save time.

Then turn hardware acceleration on inside the app. Jellyfin: Dashboard >
Playback > Transcoding > Hardware acceleration *NVIDIA NVENC*, tick the
decode formats your card supports, tick *Enable hardware encoding*.

### 8. Verify end to end

```
ssh my-nas 'C=$(sudo docker ps -q -f name=ix-jellyfin-jellyfin); sudo docker exec $C sh -c \
  "/usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 3 -c:v h264_nvenc -f null - && echo NVENC_OK"'
```

`NVENC_OK` means the whole chain works: driver, sysext, container toolkit,
app GPU passthrough.

## After a TrueNAS update

If the update changes the kernel, the boot script notices the image no
longer matches and leaves the stock driver alone (your GPU stops working,
nothing breaks). Re-run steps 4 and 5; the init script registration and the
app settings are kept.

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
