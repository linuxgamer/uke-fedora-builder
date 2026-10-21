# Fedora 44 build cache

The five-profile image command shares one kernel RPM build within each run. On
later runs it also reuses that build when the staged kernel sources and spec
have the same SHA-256 fingerprint, all five RPMs pass recorded checksums, and
the prepared kernel boot inputs still exist. The cache is populated only after
the kernel RPM build succeeds. To force a new kernel build, use:

```sh
./uke-fedora-builder/build-fedora44-images.sh \
    --output build/fedora44-images-new --rebuild-kernel
```

The AArch64 containers share `uke-fedora-builder/build/cache/`. DNF5 keeps
repository metadata and downloaded RPMs in `dnf/`; ccache keeps repeated Clang
and host-tool compilations in `ccache/`. Kernel source archives remain in the
kernel component's `referances/` cache. All these paths are ignored by Git.
The first build still downloads packages and compiles the kernel. Subsequent
builds can reuse matching inputs, but package metadata may be refreshed and
newer Fedora packages may still be downloaded.

On an x86_64 host, `--cross-kernel` prepares the AArch64 initramfs in an
AArch64 Fedora container, compiles the Linux kernel with native x86_64 Clang,
then runs the RPM checks and packaging in an AArch64 Fedora container. This
avoids QEMU for the long Kbuild step. Rootfs composition still uses AArch64
containers; the per-profile `boot_a` kernel rebuild follows the original
kernel's build platform. To exercise this path when a kernel RPM
cache entry already exists, combine it with `--rebuild-kernel`:

```sh
./uke-fedora-builder/build-fedora44-images.sh \
    --cross-kernel --rebuild-kernel --output build/fedora44-images-cross
```

The cross build is a new path and needs a complete image build and tablet boot
check before release use. The default command continues to build the kernel
inside the AArch64 container.

The build command requires a new output directory each time. It never writes
to a tablet. Cached output has the same source and package validation as a
fresh build; physical boot and hardware behavior remain unverified.

An interrupted kernel build has no completed RPM cache entry. On the next run,
the builder moves its partial kernel output and initramfs base into a
`previous-native-kernel-out.*` directory under the kernel RPM build directory
before starting a clean build. These backups can be removed manually after
the new images have been checked.
