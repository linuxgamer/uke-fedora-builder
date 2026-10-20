# Fedora for POCO Pad X1 and Xiaomi Pad 7

Fedora Rawhide upstream recipes and local Fedora 44 AArch64 build recipes for
`uke` / SM7675.
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

On an x86_64 host with Docker and AArch64 emulation, enter the Fedora 44 build
environment from the workspace root:

```bash
docker run --rm -it --platform linux/arm64 \
  --security-opt label=disable -v "$PWD:/work" -w /work \
  registry.fedoraproject.org/fedora:44 bash
```

Run the next block **inside the container**. It stages six source RPMs, installs
their declared Fedora 44 build dependencies with DNF5's
[builddep command](https://dnf5.readthedocs.io/en/latest/dnf5_plugins/builddep.8.html),
then builds the AArch64 binary RPMs. The kernel build is long; keep its
`native-kernel-out` and prepared source tree.

```bash
set -Eeuo pipefail
dnf5 -y install rpm-build dnf5-plugins make git-core jq curl gnupg2 xz tar \
  gzip coreutils findutils diffutils
git config --global --add safe.directory /work/senemos-uke-kernel
make -C senemos-uke-kernel srpm
make -C uke-linux-hardware-support/uke-core-meta srpm
make -C uke-linux-hardware-support/uke-sensors touchscreen-srpm
make -C uke-linux-hardware-support/uke-platform-runtime srpm
make -C uke-linux-hardware-support/uke-boot srpm
make -C uke-linux-hardware-support/uke-desktop-integration bluetooth-srpm

tops=(
  senemos-uke-kernel/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-core-meta/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-sensors/build/rpmbuild
  uke-linux-hardware-support/uke-platform-runtime/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-desktop-integration/build/bluetooth-srpm/rpmbuild
)
for top in "${tops[@]}"; do
  specs=("$top"/SPECS/*.spec)
  (( ${#specs[@]} == 1 )) || { echo "Expected one spec in $top" >&2; exit 1; }
  dnf5 -y builddep "${specs[0]}"
  rpmbuild -ba --target aarch64 --define "_topdir /work/$top" "${specs[0]}"
done
exit
```

Docker requires working AArch64 emulation on an x86_64 host. The commands do
not publish or flash anything. Only four hardware subpackages enter the rootfs;
the `uke-boot-integration` and kernel boot/update RPMs target the upstream slot
layout and are excluded.

The local archive `private/uke-oem-blobs-OS3.0.303.0.WOZMIXM.tar.zst` contains
the verified OEM touch files and a baseline captured from the owner's tablet.
Extract it into the ignored `private/oem-blobs/` directory and check it with
`xiaomi-uke-firmware/src/verify-local-blobs.sh` in the hardware component.
The default panel is CSOT; pass `--touch-panel tm` only for a TM panel. The
reference baseline was measured on one unit; it is not a secret credential,
but its behavior on other panels has not been qualified. The archive also holds SSC and optional
Bluetooth files, which this minimal image recipe does not install. It does not
contain the separately pinned WPSS, ADSP or GPU firmware set; Wi-Fi, DSP and
accelerated graphics are not qualified by this image recipe.

After the RPMs exist, run the next block in **Bash on the host** from the
workspace root. It creates five separate rootfs and boot pairs. Choose new
output paths if an earlier attempt left
an incomplete directory. The script requires the reviewed OS3.0.303.0 OEM
`boot.img` and the locally extracted blob directory shown above.

```bash
set -Eeuo pipefail
workspace=$PWD
kernel_top=$workspace/senemos-uke-kernel/build/srpm/rpmbuild
kernel_rpms=$kernel_top/RPMS/aarch64
kernel_out=$kernel_top/native-kernel-out
guard=$(find "$kernel_top/BUILD" -type f \
  -path '*/linux-7.2.11/boot-recipe/src/boot/dracut/root-guard.sh' -print -quit)
[[ -n $guard ]] || { echo 'Prepared kernel source not found' >&2; exit 1; }
kernel_source=${guard%/boot-recipe/src/boot/dracut/root-guard.sh}
core_rpm=$workspace/uke-linux-hardware-support/uke-core-meta/build/srpm/rpmbuild/RPMS/aarch64/uke-core-meta-1.0.0-5.fc44.aarch64.rpm
hardware_rpms=$workspace/private/fedora44-selected-rpms
mkdir -p "$hardware_rpms"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/rpmbuild/RPMS/aarch64/uke-touchscreen-0.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-platform-runtime/build/srpm/rpmbuild/RPMS/aarch64/uke-battery-observer-0.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild/RPMS/aarch64/uke-wifi-factory-0.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-desktop-integration/build/bluetooth-srpm/rpmbuild/RPMS/aarch64/uke-bluetooth-0.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
blobs=$workspace/private/oem-blobs
stock_boot=$workspace/private/uke_global_images_OS3.0.303.0.WOZMIXM_16.0/images/boot.img

for profile in tty kde gnome phosh plasma-mobile; do
  rootfs=$workspace/private/fedora44-$profile-rootfs
  pair=$workspace/private/fedora44-$profile-pair
  root_mib=4096
  if [[ $profile != tty ]]; then
    root_mib=8192
  fi
  ./uke-fedora-builder/build-fedora44-rootfs.sh \
    --profile "$profile" --kernel-rpms "$kernel_rpms" --core-rpm "$core_rpm" \
    --hardware-rpms "$hardware_rpms" --local-blobs "$blobs" \
    --root-mib "$root_mib" --output "$rootfs"
  ./uke-fedora-builder/build-fedora44-boot-a.sh \
    --rootfs "$rootfs" --kernel-source "$kernel_source" \
    --kernel-out "$kernel_out" --stock-boot "$stock_boot" --output "$pair"
  (cd "$pair" && sha256sum -c SHA256SUMS)
done
```

The prepared source path must contain `boot-recipe/` and `scripts/config`.
To build a different panel variant, pass `--touch-panel tm` to each rootfs
invocation after confirming the tablet uses a TM panel. Graphical profiles use
8192 MiB root images in this example; increase `--root-mib` if needed.
At first boot, tty1 prompts for a new administrator account and password; then
the normal login or display manager starts. A keyboard connected to the tablet
is needed for this text prompt; the root account stays locked. First-boot
interaction has not yet been tested on Xiaomi Pad 7.

Each pair contains `fedora_boot.img`, sparse `userdata.img`, checksums and a
manifest. The boot builder verifies the fixed stock template, repacks the
matched Image for `PARTLABEL=userdata`, and adds an unsigned AVB hash footer
with reviewed stock boot metadata. It never flashes or selects a device slot.
**These outputs are local build candidates, not public release assets.** The
rootfs includes proprietary OEM files without recorded redistribution
permission and a touch baseline measured on one tablet. The baseline itself is
not an account secret; its portability and touch behavior on other units need
qualification. No account or password hash is embedded, and there is no root
debug shell. Keep the images private until the OEM-data distribution path and
Xiaomi Pad 7 device checks are resolved. Replacing `userdata` destroys shared
Android data. Preserve the Android slot B boot images and a complete data
restore path before any device trial.

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

## Upstream Rawhide build commands (reference)

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

## Upstream stock bootloader route (reference)

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
