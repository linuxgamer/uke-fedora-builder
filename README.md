# Fedora for POCO Pad X1 and Xiaomi Pad 7

Fedora Rawhide AArch64 image recipes and validation tools for `uke` / SM7675.
Kernel sources and RPM rules are maintained in the [Senemos repository](https://github.com/MCC45TR/senemos-uke-kernel-mainline).

## Xiaomi Pad 7 Fedora 44 rootfs variants

**Source status, 20 October 2026:** the local Fedora 44 path is prepared for
owner builds. No new Fedora 44 RPM, rootfs, boot image or complete tablet boot
has been verified from this revision. This path targets `boot_a` and the whole
physical `userdata` partition. Phosh and Plasma Mobile are experimental.

Build Linux 7.2.11 and the Fedora 44 AArch64 RPMs with the package specs in the
kernel and hardware components. The rootfs input set is exactly one matching
`senemos-uke-linux-kernel-mainline-{core,modules,dtbs}` release, one
`uke-core-meta-1.0.0-5.fc44.aarch64.rpm`, and one each of
`uke-touchscreen`, `uke-battery-observer`, `uke-wifi-factory` and
`uke-bluetooth` for Fedora 44. Keep the four hardware RPMs in one input
directory. The kernel RPM spec writes its matched source tree under its
`rpmbuild/BUILD/` directory and native output under
`rpmbuild/native-kernel-out/`. Preserve both for the boot step. Build these
RPMs in a Fedora 44 AArch64 environment; the upstream COPR Rawhide packages
are not inputs to this recipe.

The source-RPM entry points, run from the workspace root inside that Fedora 44
AArch64 build environment, are:

```sh
make -C senemos-uke-kernel srpm
make -C uke-linux-hardware-support/uke-core-meta srpm
make -C uke-linux-hardware-support/uke-sensors touchscreen-srpm
make -C uke-linux-hardware-support/uke-platform-runtime srpm
make -C uke-linux-hardware-support/uke-boot srpm
make -C uke-linux-hardware-support/uke-desktop-integration bluetooth-srpm
```

For each component, set `top` to its generated `rpmbuild/` directory and
`spec` to the staged spec filename, then run:

```sh
rpmbuild -ba --target aarch64 --define "_topdir $top" "$top/SPECS/$spec"
```

Install the Fedora 44 build dependencies declared in each spec first. Copy
only the four selected hardware RPMs into the `hardware_rpms` directory used
below; the `uke-boot-integration` and kernel boot/update RPMs target the
upstream slot layout and are excluded.

The local archive `private/uke-oem-blobs-OS3.0.303.0.WOZMIXM.tar.zst` contains
the verified OEM touch files and a baseline captured from the owner's tablet.
Extract it into the ignored `private/oem-blobs/` directory and check it with
`xiaomi-uke-firmware/src/verify-local-blobs.sh` in the hardware component.
The default panel is CSOT; pass `--touch-panel tm` only for a TM panel. The
reference baseline is unit-specific. The archive also holds SSC and optional
Bluetooth files, which this minimal image recipe does not install. It does not
contain the separately pinned WPSS, ADSP or GPU firmware set; Wi-Fi, DSP and
accelerated graphics are not qualified by this image recipe.

From the workspace root, after the RPMs exist:

```sh
blobs="$PWD/private/oem-blobs"
kernel_rpms=/path/to/kernel/rpmbuild/RPMS/aarch64
core_rpm=/path/to/uke-core-meta-1.0.0-5.fc44.aarch64.rpm
hardware_rpms=/path/to/selected-hardware-rpms
kernel_source=/path/to/kernel/rpmbuild/BUILD/NAME/linux-7.2.11
kernel_out=/path/to/kernel/rpmbuild/native-kernel-out
stock_boot="$PWD/private/uke_global_images_OS3.0.303.0.WOZMIXM_16.0/images/boot.img"

./uke-fedora-builder/build-fedora44-rootfs.sh \
  --profile tty --kernel-rpms "$kernel_rpms" --core-rpm "$core_rpm" \
  --hardware-rpms "$hardware_rpms" --local-blobs "$blobs" \
  --output "$PWD/private/fedora44-tty-rootfs"
./uke-fedora-builder/build-fedora44-boot-a.sh \
  --rootfs "$PWD/private/fedora44-tty-rootfs" \
  --kernel-source "$kernel_source" --kernel-out "$kernel_out" \
  --stock-boot "$stock_boot" --output "$PWD/private/fedora44-tty-pair"
```

The prepared source path must contain `boot-recipe/` and `scripts/config`.
For the other independent images, repeat both commands with a new output
directory and `--profile kde`, `gnome`, `phosh` or `plasma-mobile`. Graphical
profiles also require `--user NAME --password-hash-file FILE`; the private
file must contain a SHA-512 crypt hash and have mode 0600. Use `--root-mib 8192`
or more if the desktop package set does not fit the 4096 MiB default.
The TTY profile starts a local root shell on tty1 for development.

Each pair contains `fedora_boot.img`, sparse `userdata.img`, checksums and a
manifest. The boot builder verifies the fixed stock template, repacks the
matched Image for `PARTLABEL=userdata`, and adds an unsigned AVB hash footer
with reviewed stock boot metadata. It never flashes or selects a device slot.
The outputs include proprietary OEM files and device-specific touch data;
keep them private. Replacing `userdata` destroys shared Android data. Preserve
the Android slot B boot images and a complete data restore path before any
device trial.

[Project status](https://github.com/MCC45TR/uke-linux) · [Architecture](docs/ARCHITECTURE.md) · [Development COPR](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-test/) · [Image releases](https://github.com/MCC45TR/uke-linux-images/releases)

The [Plasma first-run recipe](docs/PLASMA-FIRST-RUN.md) prepares the full original
Fedora desktop selection, user-created accounts and the enabled development
COPR. Offline checks are separate from first-run GUI and tablet acceptance;
the currently published Alpha image is not replaced by this source change.

## Status — 14 October 2026

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
[hardware table](https://github.com/MCC45TR/uke-linux#hardware-support).

Core and early-initramfs payloads reject Python. The Fedora root may retain
Python supplied by unmodified original Fedora desktop dependencies, under the
14 October exception. Those files must match separately verified signed RPMs.
Project device helpers remain native code or shell. KDE applications are not
cloned, forked or rebuilt as Uke variants.

## Build commands

Run image commands from the [Uke workspace](https://github.com/MCC45TR/uke-linux):

```sh
./ukelinux.sh --build core --distro=fedora --test
./ukelinux.sh --build boot-pair --distro=fedora --help
./ukelinux.sh --build boot --distro=fedora --help
```

| Target | Output / purpose |
|---|---|
| `core` | Console filesystem and separate UEFI/ESP development outputs |
| `boot-pair` | Root-capable `fedora_boot.img` and `system.img` for the stock Android bootloader |
| `boot` | Older initramfs-only debug image; does not switch to the Linux root |

For a kernel build, use the kernel repository's entry point:

```sh
./senemos-uke-kernel/senemos.sh --build 7.2.9 --distro=fedora --test
```

Build scripts support dry-run, offline and self-test modes. They do not create
partitions, flash images or select slots. Other compiler jobs retain priority;
source and completed build caches are reused.

## Stock bootloader route

The current pair recipe selects exactly one physical ext4 GPT partition named
`linux` through `root=PARTLABEL=linux`. A fixed filesystem UUID is not required.
The boot image targets `boot_b`; no ESP is needed. Runtime device-tree changes
preserve the bootloader's RAM map and reserved regions. Android userdata,
`init_boot`, `vendor_boot` and `dtbo` are not changed by the builder.

Image, initramfs, device tree and modules must come from a matching build.
Installing a kernel RPM through DNF does not update the embedded boot image or
write `boot_b`. Older package revisions sharing the same kernel release can
replace its modules, so updates need a reviewed boot/module set and rollback.

Before a device trial:

```sh
./ukelinux.sh --check-device --pair DELIVERY_DIRECTORY
```

This read-only check verifies delivery files, root selection, Uke identity,
slot/unlock state and target capacities. `--offline` checks local files only;
`--report NEW_FILE` saves a private result. Exit 2 means device prerequisites
are unavailable. Passing the check does not establish a backup or successful boot.

The recipe mounts `persist` read-only to preserve OEM calibration. Sensor tests
must not turn it into a writable registry. The current debug profile can provide
local and USB shells; they are development features, not secure release defaults.

See the [image guide](docs/IMAGES.md), [private boot-pair instructions](https://github.com/MCC45TR/uke-linux-docs/blob/main/docs/testing/FEDORA-BOOT-PAIR.md)
and [boot-B instructions](https://github.com/MCC45TR/uke-linux-docs/blob/main/docs/testing/FEDORA-BOOT-B.md)
for exact profiles and rollback requirements. The UEFI/ESP32-S3 host route is
separate work; it does not inherit stock-bootloader test results.

## Validation records

Dated reports retain their original test scope. The October 9 pair used a UUID
contract; later recipes use the partition name. A VM boot or package installation
does not establish tablet UFS, screen, USB or sleep behavior.

- [Image construction](reports/CORE-FILESYSTEM-2026-10-05.json)
- [Stock-bootloader pair](reports/FEDORA-BOOT-PAIR-2026-10-09.json)
- [Kernel lifecycle](reports/KERNEL-7.2.9-RAWHIDE-2026-10-04.json)
- [Host bootstrap](reports/HOST-BOOTSTRAP-2026-10-04.json)
- [COPR automation](reports/COPR-AUTOMATION-2026-10-04.json)
- [Recovery packages](reports/RECOVERY-RAWHIDE-2026-10-04.json)
- [Private engineering records](https://github.com/MCC45TR/uke-linux-docs)

Firmware redistribution and licenses are reviewed separately from kernel source
packages. Public releases include checksums and installation limits; physical
results are reported separately for each tested build and device variant.

### Root mount policy — 19 October 2026

New Core and boot-pair roots use noatime and errors=remount-ro on ext4. This
matches the boot integration template while preserving the existing filesystem
identity, normal ordered journaling, write barriers and commit interval. The
first option avoids access-time writes; the second protects an errored root
from further writes. Periodic trimming remains separate from continuous
mount-time discard. Source checks do not qualify a newly exported image.
