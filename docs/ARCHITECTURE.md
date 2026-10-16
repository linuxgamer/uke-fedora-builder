# Fedora build architecture

The checked-in recipes use the Linux 7.2.9 Uke adaptation to produce
`senemos-uke-linux-kernel-mainline` meta/core/modules/dtbs RPMs and an SRPM.
Kernel builds belong to `uke-mainline-linux`; Fedora image recipes belong here.
These recipes target Fedora 44 using pinned official container bases and
Fedora RPMs. Uke packages come from local Fedora 44 builds; their exact hashes
are recorded alongside official package signatures. The upstream Rawhide COPR
is not enabled. Downstream publication is separate. See [the build guide](BUILDING.md).

Resolve package dependencies before selecting a desktop. Preserve repository
metadata, complete package versions, RPM checksums and licenses. Inspect the
dependencies of package groups before including them. Signed package and
target privacy checks apply to Python packages as they do to other payloads.
Image composition needs a fresh build before combining updated components.

The kernel manifest includes source/config/patch/toolchain identities, kernel
release, DT identity and module ABI inventories, with full artifact SHA-256.
`--test` additionally records the AArch64 installed package closure. Firmware,
boot header and partition geometry belong to subsequent boot-profile manifests;
none is inferred by the compile-stage kernel package. Unpack candidates and
verify these fields independently. Kernel and modules come from one build.
Current local candidates are unsigned; modules are stripped and compressed.
When signing is introduced, it must occur after strip and before compression.

RPM scripts must not flash Android partitions or change the selected boot
profile. QEMU checks, dependency checks, COPR build results and physical boots
need separate records. A rootfs archive is not assumed to fit `init_boot`.
Signing keys and raw device logs remain private.
