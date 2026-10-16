# Kernel and Fedora image construction

Run the workspace entry from the `uke-fedora` checkout:

```sh
./build.sh kernel --build 7.2.9 --offline --dry-run
./build.sh core --offline --dry-run
./build.sh boot-pair --help
```

The entries require Bash and display help when run without arguments. In a
standalone kernel checkout, use `./build.sh` followed by the kernel options;
the workspace entry requires the `kernel` target first. The kernel repository
owns the build implementation and its pinned host environment. See the
[`uke-mainline-linux` build guide](https://github.com/linuxgamer/uke-mainline-linux/blob/main/docs/BUILDING.md).
Normal builds can install host prerequisites; dry-run and offline modes do not.
Verified archives and reusable build/artifact output belong to the kernel
checkout. Firmware, image inputs, boot handoff and target-image construction
remain independent from kernel package acceptance.

Image recipes are in this repository. The workspace entry loads them directly.
Use `./build.sh core --help`, `./build.sh boot --help` or
`./build.sh boot-pair --help` for the corresponding options. Read-only device
preflight is available through `./build.sh check-device --help`.
Local filesystem acceptance is recorded separately from untested tablet boot.

Boot ABI receipts extract the core rows from the final Kbuild `Module.symvers`.
Both boot stages rebuild modules before comparing those rows. A legacy
`vmlinux.symvers` file can survive cache reuse and must not establish current
exports. `tests/kernel-export-contract.sh` covers stale receipts, changed core
symbols/CRCs and missing tables while allowing module-only export changes.

See [Core image construction](IMAGES.md) for the locked runtime closure,
ESP32 debug profile, local filesystem checks and unresolved device release gates.
