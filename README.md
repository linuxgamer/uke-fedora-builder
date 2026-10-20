# Uke Fedora Builder

Tools and recipes for building **Fedora Rawhide AArch64** images for POCO Pad X1 and Xiaomi Pad 7 (`uke`, Qualcomm SM7675).

The builder creates filesystem and boot-image artifacts. It does not, by itself, prove that an image boots successfully on a tablet. Current test results come from POCO Pad X1 and not Xiaomi Pad 7

## Build targets

| Target | What it produces | Intended use |
| --- | --- | --- |
| `core` | Fedora console root filesystem and separate UEFI development outputs | Base system and testing |
| `boot-pair` | Matched `fedora_boot.img` and `system.img` | Stock Android bootloader development route |
| `boot` | Older initramfs-only debug image | Early boot diagnostics; does not switch to the Fedora root |

The image recipes use original Fedora packages, including the standard KDE Plasma desktop where selected. Kernel sources and kernel RPM packaging live in the [kernel repository](https://github.com/linuxgamer/senemos-uke-kernel-mainline).

## Building

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
