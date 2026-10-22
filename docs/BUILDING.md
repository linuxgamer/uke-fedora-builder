# Kernel and Fedora image construction

For the Xiaomi Pad 7 Fedora 44 image set, follow the
[Fedora 44 build guide](FEDORA44-BUILD-CACHE.md). On an x86_64 PC, its
`--cross-kernel` option compiles the ARM64 kernel with native Clang and avoids
the long emulated kernel compilation. Other packages still use AArch64
containers; the option is unavailable on an ARM64 host.

The kernel repository owns the standalone `senemos.sh` entry and its pinned
host environment. See its [build guide](https://github.com/MCC45TR/senemos-uke-kernel-mainline/blob/main/docs/BUILDING.md).

```sh
git clone https://github.com/MCC45TR/senemos-uke-kernel-mainline.git
cd senemos-uke-kernel-mainline
./senemos.sh --build 7.2.9 --distro=fedora --test
```

In the multi-repository Uke workspace, invoke
`./senemos-uke-kernel/senemos.sh`. The old root kernel entry is removed.
Verified archives and reusable build/artifact output belong to the kernel
checkout. Firmware, image inputs, boot handoff and target-image construction
remain independent from kernel package acceptance.

The workspace image entry is `ukelinux.sh`. It uses the Fedora builder
to produce local Core candidates; future accepted releases belong to `uke-linux-images`.
Current image prerequisites and failed/corrected trials are in the
[private engineering records](https://github.com/MCC45TR/uke-linux-docs).
Local filesystem acceptance is recorded separately from untested tablet boot.

Boot ABI receipts extract the core rows from the final Kbuild `Module.symvers`.
Both boot stages rebuild modules before comparing those rows. A legacy
`vmlinux.symvers` file can survive cache reuse and must not establish current
exports. `tests/kernel-export-contract.sh` covers stale receipts, changed core
symbols/CRCs and missing tables while allowing module-only export changes.

See [Core image construction](IMAGES.md) for the locked runtime closure,
ESP32 debug profile, local filesystem checks and unresolved device release gates.
