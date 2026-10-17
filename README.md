# Fedora for POCO Pad X1 and Xiaomi Pad 7

Fedora AArch64 root filesystem and image recipes for POCO Pad X1 and Xiaomi Pad 7
(`uke` / SM7675). The checked-in recipes target Fedora 44 and use locally
built Uke packages with official Fedora dependencies. Tablet behavior under
Fedora 44 remains untested. Kernel sources are
in [`uke-mainline-linux`](https://github.com/linuxgamer/uke-mainline-linux).

[Workspace](https://github.com/linuxgamer/uke-fedora) · [Architecture](docs/ARCHITECTURE.md) · [Build guide](docs/BUILDING.md) · [Image guide](docs/IMAGES.md)

Published Core and KDE prebuild roots have separate host/filesystem checks. Current device
results come from a different development installation. See
[hardware table](https://github.com/linuxgamer/uke-fedora#hardware-support).

## Building

The image scripts live under `src/` in this repository. From `uke-fedora`
workspace, use `./build.sh core`, `./build.sh boot-pair` or `./build.sh boot`.
Append `--help` for required inputs or `--offline --dry-run` to inspect a plan.
See the [build guide](docs/BUILDING.md) before attempting to build.

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
by `root=PARTLABEL=userdata`.
Use `--root-partlabel linux` to build for an existing dedicated `linux` partition.
Both variants require one of those partitions with EXT4 and the `UKE_LINUX`
filesystem label. The 3 GiB
stock-pair filesystem grows to the target partition size on first boot through
systemd.

Image, initramfs, device tree and modules must come from a matching build.
Installing a kernel RPM through DNF does not update the embedded boot image or
write a boot partition.

`--check-device --pair DELIVERY_DIRECTORY` verifies delivery files and root
selection locally. `--offline` remains an
accepted alias, and `--report NEW_FILE` saves a private result. Device identity,
slot, unlock state and partition sizes require separate manual checks.

The recipe mounts `persist` read-only to preserve OEM calibration. The current debug profile can provide
ssh and USB shells; they are development features, not secure release defaults.

See the [image guide](docs/IMAGES.md) for profile details. The UEFI/ESP32-S3
host route is separate work; it does not inherit stock-bootloader test results.
