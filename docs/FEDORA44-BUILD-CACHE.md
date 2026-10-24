# Fedora 44 build cache and faster kernel compilation

For most x86_64 PCs, start the five-image build with `--cross-kernel`:

```sh
./uke-fedora-builder/build-fedora44-images.sh \
    --cross-kernel --output build/fedora44-images
```

All five profiles are selected by default. Use `--profiles` to select a
comma-separated subset, for example `--profiles tty` or `--profiles kde,gnome`.
A desktop selection also builds or reuses the TTY rootfs and boot pair as
shared inputs; these TTY artifacts remain in the output directory. The build
status counts only the selected profiles and their required TTY pair.

The flag compiles the ARM64 kernel with native x86_64 Clang instead of running
the long kernel compilation inside an emulated AArch64 container. The result
is still an ARM64 kernel. Other port RPMs and the Fedora rootfs still use
AArch64 containers, so the flag does not accelerate every stage. It is only
available on x86_64 hosts; omit it on an ARM64 machine. It changes the build
method, not the tablet installation steps or image layout.

The five-profile image command shares one kernel RPM build within each run. On
later runs it reuses that build when the staged kernel sources and spec have
the same SHA-256 fingerprint, all five RPMs pass recorded checksums, and the
prepared kernel boot inputs still exist. The cache is populated only after a
successful kernel RPM build. When a verified kernel is already cached,
`--cross-kernel` alone will not recompile it. To force a new cross build, use:

```sh
./uke-fedora-builder/build-fedora44-images.sh \
    --cross-kernel --rebuild-kernel --output build/fedora44-images-new
```

The other local RPMs also have an input-and-output checksum cache. A matching
RPM is reused; changed sources, dependent local RPMs, or a missing/corrupt
output trigger rebuilding that package and running its checks again.

The builder creates reusable Fedora 44 ARM64 and x86_64 tool images on first
use. Later containers start with their compilers and packaging tools already
installed. The containers also share `uke-fedora-builder/build/cache/`: DNF5
keeps downloaded RPMs in `dnf/` and `dnf-x86_64/`, while ccache keeps repeated
compilations in `ccache/` and `ccache-cross/`. Kernel source archives remain in
the kernel component's `source-cache/` cache. The exact tool image IDs are part
of each profile's input receipt. These paths are ignored by Git.

A native Fedora 44 tool image builds `hwdb.bin` after package installation,
then creates, labels, checks, converts and archives each ext4 rootfs. This
avoids AArch64 emulation for the filesystem work. The rootfs audit rejects
the 105-byte database that DNF's emulated systemd trigger could leave behind.
Changes to image recipes invalidate finished profile receipts; changes only
to audit scripts do not. Matching RPMs remain cached.

The TTY rootfs is built first. KDE, GNOME, Phosh and Plasma Mobile copy its
verified Fedora, kernel and hardware package tree, then install their own
desktop packages. The experimental console keyboard is installed only in the
TTY image; desktop composition removes its package and service from the copied
base. A changed local RPM or builder input invalidates the
finished profile cache; the copy also checks the TTY package and OEM receipts.
The four desktop pairs reuse the verified TTY boot image because the boot
kernel and initramfs do not depend on the desktop profile. Each pair still has
its own userdata image and manifest.

The first build still downloads packages, and a newer Fedora package may be
downloaded on a later run.

Fedora package downloads use `https://mirror.yandex.ru/fedora/linux` by
default. To use another Fedora mirror, set `UKE_FEDORA_MIRROR` to its HTTPS
`fedora/linux` root before running the build. The builder keeps Fedora's RPM
signature checks. Changing the mirror creates new tool images and invalidates
the profile receipts.
Package installation retries transient download errors up to three
times while retaining the RPM cache. Dependency or scriptlet errors still stop
the build immediately.
The Cisco openh264 repository is disabled in the tool images; desktop profiles
install Fedora's `noopenh264` package from the regular Fedora repositories.

The cross path prepares the AArch64 initramfs and runs RPM checks in AArch64
containers. The long kernel compilation runs on the x86_64 host; the single
`boot_a` kernel rebuild for the TTY pair follows that platform too.

The cross build still needs a complete image build and tablet boot check
before release use. Without `--cross-kernel`, a kernel cache miss compiles
inside the AArch64 container.

For an interrupted run, keep the same output directory and add `--resume`:

```sh
./uke-fedora-builder/build-fedora44-images.sh \
    --cross-kernel --resume --output build/fedora44-images
```

The script checks completed profile artifacts before reusing them. A new run
without `--resume` requires a new output directory. The builder never writes
to a tablet; a successful build does not establish that an image boots on one.

To rerun the current audit on a completed output without rebuilding anything,
use the original profile list:

```sh
./uke-fedora-builder/build-fedora44-images.sh \
    --audit-only --profiles kde --output build/fedora44-kde-tm-fix
```

An interrupted kernel build has no completed RPM cache entry. On the next run,
the builder moves its partial kernel output and initramfs base into a
`previous-native-kernel-out.*` directory under the kernel RPM build directory
before starting a clean build. These backups can be removed manually after
the new images have been checked.
