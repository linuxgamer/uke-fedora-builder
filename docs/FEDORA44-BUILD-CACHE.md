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

The build command requires a new output directory each time. It never writes
to a tablet. Cached output has the same source and package validation as a
fresh build; physical boot and hardware behavior remain unverified.
