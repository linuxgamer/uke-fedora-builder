# Fedora 44 Core filesystem candidates

The checked-in image recipes target Fedora 44. From the `uke-fedora` workspace, use
`./build.sh core --offline --dry-run` to inspect the Core plan, or
`./build.sh core --help` for options. The Core recipe accepts `--offline`,
`--test`, `--linux-size`, `--esp-size` and `--fat-sector` options.

The 16 October 2026 Fedora 44 Core build passed offline package preparation,
root/initramfs audits, SELinux labeling and EXT4/FAT/UKI readback on an x86_64
host with AArch64 emulation. Tablet boot remains untested.

The target is Fedora 44 AArch64 Core. Other distributions and
desktop targets fail explicitly. Console roots reject installed Wayland and X11
session entries from any desktop environment. The host entry prepares official
prerequisites on Fedora, Debian/Ubuntu, openSUSE, Arch and Alpine/postmarketOS, selects working
Podman/Docker and limits jobs to two CPUs and 3 GiB per container. Native
AArch64 and x86_64 with official QEMU binfmt are supported code paths. Earlier
end-to-end host validation used Fedora Rawhide x86_64. Builds wait for other
compilers and pause their own active container when another build starts.

## Locked inputs and audit boundaries

The runtime starts from an immutable official Fedora AArch64 OCI digest, then
replays 55 console runtime inputs and 15 system/identity inputs, then installs
three local boot/CDC RPMs. `manifests/images/core-*.json` record SHA-256,
architecture, source RPM identity and signed Koji URLs or local artifact paths.
The Fedora 44 signing-key fingerprint is checked before use. Official RPMs
require Fedora signatures; unsigned local development RPMs require their pinned
hashes and RPM payload digests. Package workers have networking disabled.
The base image supplies Fedora's original `libstdc++`.

Initial assembly uses dracut on the emulated host, then removes its assembly
packages and optional format/graphics/keyring payloads through DNF dependency
checks. RPM-owned files are never redacted to bypass an audit. Private build
paths, SSH keys, machine ID and random seed are rejected in the target root and
initramfs. Python payloads are allowed. Exact public SELinux
namespace rules have a six-file hash-pinned exception; modified files and host
identities are rejected. Target SELinux remains enforcing.

The image-host container uses GNU objcopy instead of target `systemd-ukify`,
plus native C/C++ e2fs/SELinux helpers. Fedora package-management tools can have
upstream host dependencies inside that disposable container; none of those
host tools are copied into tablet payloads. The OCI ID and recipe identify the
host environment.

## Development shell and ESP32-S3

Core explicitly enables the original systemd development shell on VT2 and masks
`getty@tty2`. **This is an unauthenticated local root development shell**, selected
only by `senemos.debug=esp32-cdc` in this Core profile. It is not a general-purpose
or desktop security default. Root password login and SSH root access are disabled.

The tablet acts as USB host; the ESP32-S3 supplies CDC and HID interfaces. The
single C++ journal writer configures the explicitly selected `/dev/ttyACM0` at
115200 raw, asserts DTR/RTS and streams the current boot journal. HID types into
VT2; shell stdout/stderr go to journald. The gated `uke-bringup` dracut module
adds a VT2 shell and the same native CDC writer before root mount, selected by
both `rd.senemos.tty=1` and `senemos.debug=esp32-cdc`. It copies native binaries,
their libraries and host/HID/ACM modules. The initramfs writer stops before
switch-root; the real-root unit excludes initramfs, preserving one writer per
stage. A missing UFS root therefore need not prevent an early shell, provided
firmware RAM/framebuffer handoff and USB host operation work.
RPM installation alone enables neither this service nor the optional tablet
USB-gadget service. The old ESP32 firmware remains untouched and its exact
HID/control protocol is still unverified. PTY fixtures do not establish USB
hardware compatibility.

## Outputs and release gates

The compositor writes regular files only: EXT4 Linux and FAT32 ESP candidates,
compressed copies, a UKI, package list and checksums. Defaults are 4096 MiB Linux,
256 MiB ESP and 512-byte FAT sectors. `--linux-size` and `--esp-size` choose MiB
sizes; `--fat-sector` accepts 512 or 4096. A 4096-byte sector FAT32 ESP requires
at least 512 MiB. Each effective profile changes the recipe/cache identity.

Core installation targets are fastboot names `esp` and `userdata` by default;
`--root-partlabel linux` selects an existing dedicated Linux partition. Writing
the root image to `userdata` destroys Android user data and requires data
backups and matching OEM firmware for restoration. Filesystem labels
`UKE_ESP`/`UKE_LINUX` and `root=LABEL=UKE_LINUX` remain stable when partition
sizes change. No GPT offset is embedded. Flashing still requires the target
partition to exist, fit the chosen image and be visible to UEFI with compatible
sector geometry. This builder never flashes or creates tablet partitions.

Every composition verifies complete root/initramfs payloads, kernel/config
identity, all-inode SELinux/owner/mode/capability preservation, EXT4 integrity,
complete readback, exact six-section UKI inputs, FAT integrity and ESP UKI
readback. No default loader, EFI variable update, Android binary or Nabu offset
is introduced. On-device kernel RPM updates do not yet regenerate/activate the UKI.

Current kernel DT lacks enabled Uke USB/UFS nodes. Static RAM is not guessed:
the Linux EFI stub consumes the real firmware memory map, with firmware-owned
carveouts needing exact-profile validation. A Uke UEFI handoff, target capacity
and sector/firmware visibility, bridge enumeration, actual kernel boot and
rollback are unresolved release gates. Passing filesystem/package checks is a
local candidate result and cannot establish a bootable tablet image.
