# Fedora 44 build cache and faster kernel compilation

For most x86_64 PCs, start the five-image build with `--cross-kernel`:

```sh
./uke-fedora-builder/build-fedora44-images.sh \
    --cross-kernel --output build/fedora44-images
```

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

The containers share `uke-fedora-builder/build/cache/`. DNF5 keeps repository
metadata and downloaded RPMs in `dnf/` and `dnf-x86_64/`; ccache keeps repeated
compilations in `ccache/` and `ccache-cross/`. Kernel source archives remain in the
kernel component's `referances/` cache. All these paths are ignored by Git.
The first build still downloads packages and compiles the kernel. Subsequent
builds can reuse matching inputs, but package metadata may be refreshed and
newer Fedora packages may still be downloaded.

The cross path prepares the AArch64 initramfs and runs RPM checks in AArch64
containers. The long kernel compilation runs on the x86_64 host; each
profile's `boot_a` kernel rebuild follows that platform too.

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

An interrupted kernel build has no completed RPM cache entry. On the next run,
the builder moves its partial kernel output and initramfs base into a
`previous-native-kernel-out.*` directory under the kernel RPM build directory
before starting a clean build. These backups can be removed manually after
the new images have been checked.
