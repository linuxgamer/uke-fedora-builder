# Fedora Rawhide KDE Plasma · R3 system repair

2 November 2026 · Uke / SM7675 · AArch64 · unstable COPR · EXT4 · Bash · singleboot.
Experimental pre-release for device testing. This release contains **one KDE system
image**, edited offline from the existing R2 KDE image. No core, desktop packages,
GNOME image or boot image was rebuilt. R1 and R2 releases remain unchanged.

## Startup correction

R2's root-capacity unit used the aligned output of `findmnt -n -o MAJ:MIN /`.
The actual R2 ARM64 binary prints a valid `8:32` device number as `  8:32 `;
the following strict identity check rejects those spaces and prevents the
dependent account setup and display manager from starting. R3 requests raw
output with `findmnt -rn` for the device number and filesystem type.

Only `/etc/systemd/system/uke-root-capacity.service` changes. The physical-root,
block identity and full-capacity checks remain enforced. Native systemd growfs,
half-RAM disk swap, complete RPM translations including translated help and Qt
catalogs, first-account Plasma Setup, SELinux and healthy-slot acceptance remain
unchanged. No preset human account or password is included; SSH remains disabled.

## SHA256

| File | SHA256 |
| --- | --- |
| `fedora-rawhide-kde-plasma-uke-senemos-system-021126-r3.img.zst` | `@IMAGE_SHA256@` |

## Required existing boot

Reuse the exact [R2 shared boot image](https://github.com/MCC45TR/uke-linux/releases/download/fedora-rawhide-uke-senemos-011126-r2/fedora-rawhide-uke-senemos-boot-011126-r2.img).
Its SHA256 is `74edd331899945932e78aa9916e5ed3ed581751fb7f7f6fb3422d8cbd3165b50`.
R3 does not change boot or require a new kernel. Kernel RPMs remain
`7.3.1-1010.1.fc46.aarch64`; the embedded kernel/module ABI remains `7.3.1-1010`.
If the installed boot does not match R2, verify the device-specific boot/slot
procedure before installing this root; do not mix an older boot with R3.

## Installation

**Flashing userdata erases all existing Android or Fedora data in that partition.**
Back up needed data first. The `system` image targets **userdata**, not an Android
`system` partition. Verify the SHA256 above, the Uke product, current slot and
userdata capacity before any write. Userdata must be at least 8,589,934,592 bytes.

```sh
sha256sum fedora-rawhide-kde-plasma-uke-senemos-system-021126-r3.img.zst
zstd -d --keep fedora-rawhide-kde-plasma-uke-senemos-system-021126-r3.img.zst
fastboot getvar product
fastboot getvar current-slot
fastboot getvar partition-size:userdata
fastboot flash userdata fedora-rawhide-kde-plasma-uke-senemos-system-021126-r3.img
```

These commands assume the matching R2 boot is already installed in the intended
Linux boot slot. They do not change boot images, the active slot or GPT. Follow
the verified device-specific reboot procedure. Do not run `fastboot -w` or format
userdata afterwards. Standard fastboot writes an initially 8 GiB EXT4 filesystem;
the original systemd growfs service expands it to the measured userdata capacity
before account setup. Fastboot itself does not resize EXT4.

## Provenance and validation

Input: [R2 KDE](https://github.com/MCC45TR/uke-linux/releases/tag/fedora-rawhide-uke-senemos-011126-r2),
compressed SHA256 `e771ec34e53f30fd66e5878095c969e930e5e20c24aa8e88e0a9fa543f3e8e10`,
original build [41342631296](https://github.com/MCC45TR/uke-linux/actions/runs/41342631296),
root revision `4518884da249413d3bae5d58daa6d99cd6e3df77` and builder
`68645d6174766f4d3c6bccf3c8eb3155ae77e739`.
The repair is recorded in [builder f3ecf98](https://github.com/MCC45TR/uke-fedora-builder/commit/f3ecf98d90cc3c611610d607dc0e0048956f571a).
The release source pin records the repair; it does not imply a fresh package build.

The real Fedora formatter and the extracted R2 ARM64 formatter reproduce the
original failure. The actual serialized systemd command passes with raw output
and full-capacity observations, while an undersized filesystem still fails.
Full raw-image comparison restricts changes to this unit's data block and its
existing inode size/checksum. Its owner, mode, timestamps and SELinux context,
filesystem UUID/label, all other file data and metadata, and the kernel/boot
cohort remain unchanged. Read-only EXT4 checks and independent AOSP sparse
decoding validate the resulting filesystem. The Android sparse image contains
only RAW/FILL chunks, with complete logical coverage and no DONT_CARE chunks.

This repairs a reproduced startup defect. A physical R3 tablet boot, full-size
userdata growth, swap activation, input and graphical setup remain to be tested;
the available tablet photos do not exclude an additional device-side failure.
Slot switching alone does not restore overwritten userdata. Keep the R2 download
and an independent data backup for recovery.
