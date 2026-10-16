# Fedora for POCO Pad X1 and Xiaomi Pad 7

Fedora AArch64 root filesystem and image recipes for POCO Pad X1 and Xiaomi Pad 7
(`uke` / SM7675). The checked-in recipes target Fedora 44 and use locally
built Uke packages with official Fedora dependencies. Tablet behavior under
Fedora 44 remains untested. Kernel sources are
in [`uke-mainline-linux`](https://github.com/linuxgamer/uke-mainline-linux).

[Workspace](https://github.com/linuxgamer/uke-fedora) · [Architecture](docs/ARCHITECTURE.md) · [Build guide](docs/BUILDING.md) · [Image guide](docs/IMAGES.md)

On 16 October 2026, the Fedora 44 Core build passed offline package replay,
root/initramfs checks, all-inode SELinux verification and EXT4/FAT/UKI readback.
Local results are in `build/images/core-fedora-44-a7f9bb256b8a19b4/candidate/`.
The stock-ABL boot pair in `build/boot-pair/pair-d92003ac3b71e7b3/` also passed
five generic ARM64 QEMU scenarios: real EXT4 root, enforcing SELinux, local
USB-keyboard TTY input, UUID changes, invalid-root rejection and
userdata filesystem growth.
No Fedora 44 image has been tested on the tablet.

## Upstream Rawhide test — 14 October 2026

Matched RAM boots reach the tablet console, the existing 64 GiB Fedora root,
software KDE and Wi-Fi SSH. The revised initramfs starts ADSP charger services
and exposes battery readings in a fresh RAM boot. Repeated cold boots, normal
slot-B startup and automatic charging still need testing.
Finger input and ten simultaneous touch contacts also worked in the
14 October tablet test; stylus and touch lifecycle checks remain open. Power
and volume buttons and manual backlight control also worked. Backlight
adjustment is linear and difficult to use comfortably; a logarithmic curve is
planned.

Published Core and KDE prebuild roots have separate host/filesystem checks;
those exact root images have not been booted on the tablet. Current device
results come from a different development installation. See the
[hardware table](https://github.com/linuxgamer/uke-fedora#hardware-support).

The image recipes allow Python from signed packages. Package identity,
signatures and target privacy checks still apply. Combining updated hardware
packages with these recipes needs a new build and validation. KDE applications
are not cloned, forked or rebuilt as Uke variants.

## Building

The image scripts live under `src/` in this repository. From the `uke-fedora`
workspace, use `./build.sh core`, `./build.sh boot-pair` or `./build.sh boot`.
Append `--help` for required inputs or `--offline --dry-run` to inspect a plan.
See the [build guide](docs/BUILDING.md) before attempting a build.

| Recipe | Output / purpose |
|---|---|
| `core` | Console filesystem and separate UEFI/ESP development outputs |
| `boot-pair` | Root-capable `fedora_boot.img` and `system.img` for the stock Android bootloader |
| `boot` | Older initramfs-only debug image; does not switch to the Linux root |

For kernel build instructions, see the
[`uke-mainline-linux` build guide](https://github.com/linuxgamer/uke-mainline-linux/blob/main/docs/BUILDING.md).

Build scripts support dry-run, offline and self-test modes. They do not create
partitions, flash images or select slots. Other compiler jobs retain priority;
source and completed build caches are reused.

## Stock bootloader recipe

The default pair targets `boot_a` and the entire `userdata` partition, selected
by `root=PARTLABEL=userdata`. Installation replaces Android user data. Keep data
backups, original boot images and the matching OEM firmware before installing.
Slot B boot images are preserved, but Android also needs its userdata restored;
switching slots alone cannot restore Android data.

Use `--root-partlabel linux` to build for an existing dedicated `linux` partition.
Both variants require one physical partition with EXT4 and the `UKE_LINUX`
filesystem label; Android's existing filesystem is not accepted. The 3 GiB
stock-pair filesystem grows to the target partition size on first boot through
systemd. The builder writes host image files only: it never flashes, changes
GPT or selects a slot. The stock recipe does not use an ESP.

Runtime device-tree changes preserve the bootloader's RAM map and reserved
regions. Physical target capacity, ABL handoff and Android recovery still need
device verification. `init_boot`, `vendor_boot` and `dtbo` are preserved.

Image, initramfs, device tree and modules must come from a matching build.
Installing a kernel RPM through DNF does not update the embedded boot image or
write a boot partition. Older package revisions sharing the same kernel release can
replace its modules, so updates need a reviewed boot/module set and rollback.

`--check-device --pair DELIVERY_DIRECTORY` verifies delivery files and root
selection locally. It never contacts ADB or fastboot; `--offline` remains an
accepted alias, and `--report NEW_FILE` saves a private result. Device identity,
slot, unlock state and partition sizes require separate manual checks. Passing
the local check does not establish a backup or successful boot.

The recipe mounts `persist` read-only to preserve OEM calibration. Sensor tests
must not turn it into a writable registry. The current debug profile can provide
local and USB shells; they are development features, not secure release defaults.

See the [image guide](docs/IMAGES.md) for profile details. The UEFI/ESP32-S3
host route is separate work; it does not inherit stock-bootloader test results.

## Validation scope

Dated reports retain their original test scope. The October 9 pair used a UUID
contract; later recipes use the partition name. A VM boot or package installation
does not establish tablet UFS, screen, USB or sleep behavior.

Detailed trial records belong in the workspace's ignored `/private` directory.

Firmware redistribution and licenses are reviewed separately from kernel source
packages. Public releases include checksums and installation limits; physical
results are reported separately for each tested build and device variant.
