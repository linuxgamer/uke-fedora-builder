# Uke Fedora Builder

Tools and recipes for **Fedora 44 AArch64** release images for Xiaomi Pad 7
(`uke`, Qualcomm SM7675). Older Rawhide development targets for POCO Pad X1
and Xiaomi Pad 7 remain available.

The builder creates filesystem and boot-image artifacts. A completed build
alone does not establish that an image boots on the tablet.

## Build targets

| Target | What it produces | Intended use |
| --- | --- | --- |
| `core` | Fedora console root filesystem and separate UEFI development outputs | Base system and testing |
| `boot-pair` | Matched `fedora_boot.img` and `system.img` | Stock Android bootloader development route |
| `boot` | Older initramfs-only debug image | Early boot diagnostics; does not switch to the Fedora root |

The image recipes use original Fedora packages, including the standard KDE Plasma desktop where selected. Kernel sources and kernel RPM packaging live in the [kernel repository](https://github.com/linuxgamer/senemos-uke-kernel-mainline).

## Building

For the Xiaomi Pad 7 Fedora 44 release image set, run from the workspace root:

```sh
./uke-fedora-builder/build-fedora44-images.sh --cross-kernel --output build/fedora44-images
```

On an x86_64 PC, `--cross-kernel` makes Clang compile the ARM64 kernel directly
on the host CPU instead of compiling it under AArch64 emulation. This usually
saves time during the first kernel build. It does not change how the other RPMs
or Fedora rootfs are built. Omit the flag on an ARM64 host. If a verified
kernel build is already cached, the script reuses it either way; add
`--rebuild-kernel` only when you intentionally need to compile the kernel again.
See [Fedora 44 build cache](docs/FEDORA44-BUILD-CACHE.md) for details.

The command creates separate TTY, KDE, GNOME, Phosh, and Plasma Mobile image
pairs by default. To build only selected profiles, pass a comma-separated list:

```sh
./uke-fedora-builder/build-fedora44-images.sh --cross-kernel \
    --profiles kde,gnome --output build/fedora44-images-desktop
```

The stock panel selector now enables native display by default. O82-36 offers
the seven fixed OEM modes: 30, 48, 50, 60, 90, 120 and 144 Hz. The owner has
observed 60 and 120 Hz switching with touch on one O82-36/TM tablet. Test the
other rates and sleep/wake before treating this mode set as release ready.
Keep the earlier working 60/120 boot image for recovery. Adaptive VRR remains
separate from these fixed modes.

Desktop selections also prepare the TTY rootfs and boot pair they share. The
output contains those TTY prerequisites as well as the requested profile pairs.
With `--resume`, you can add more profiles to the same output directory later.
In another terminal, inspect concise progress or stop the build:

```sh
./uke-fedora-builder/build-fedora44-images.sh --status --output build/fedora44-images
./uke-fedora-builder/build-fedora44-images.sh --stop --output build/fedora44-images
```

After interruption, restart with the same options and `--resume`:

```sh
./uke-fedora-builder/build-fedora44-images.sh --cross-kernel --resume --output build/fedora44-images
```

Completed RPMs and profile artifacts are reused only after their inputs and checksums
pass validation. The full output is also saved to `build.log`; stage transitions
are in `progress.log` and `status.json`. Rootfs phase timings are in each
profile's `timing.tsv`. The builder caches its tool containers, copies the
verified TTY rootfs as the base for desktop profiles, and reuses the TTY boot
image for their separate image pairs. Fedora downloads use a tested mirror by
default; see the build cache guide for the override.

The older upstream development targets remain available below.

Run these from the [Uke workspace](https://github.com/linuxgamer/uke-fedora), which provides `ukelinux.sh`:

```sh
./ukelinux.sh --build core --distro=fedora --test
./ukelinux.sh --build boot-pair --distro=fedora --help
./ukelinux.sh --build boot --distro=fedora --help
```

These examples are testing/help entry points, **not installation instructions**. See the workspace and `docs/` for complete image-production and device procedures.

## Before using an image

- Use a matched kernel, modules, device tree, initramfs and root filesystem.
- Preserve Android partitions, factory data, backups and a working recovery path.
- Host checks, virtual-machine results and successful builds are **not** proof of tablet compatibility.

For a prepared delivery directory, the workspace provides a read-only prerequisite check:

```sh
./ukelinux.sh --check-device --pair DELIVERY_DIRECTORY
```

Related: [Uke Fedora](https://github.com/linuxgamer/uke-fedora) · [Kernel](https://github.com/linuxgamer/senemos-uke-kernel-mainline) · [Hardware integration](https://github.com/linuxgamer/uke-linux-hardware-support)

See [LICENSE](LICENSE) for project tooling licensing.
