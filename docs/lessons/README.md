# Engineering lessons

## UKE-CROSS-001

- Date: 2026-10-21.
- Environment: Fedora 44 x86_64 host build design; source and shell checks only.
- Evidence: Linux Kbuild supports `ARCH=arm64 LLVM=1` on x86_64. The current Uke RPM also builds AArch64 dracut userspace and runs its checks in AArch64 containers.
- Finding: moving the whole RPM recipe to an x86_64 container would produce or execute host binaries in the tablet payload. The AArch64 initramfs and RPM stages must remain target-native while Kbuild runs on the x86_64 host.
- Consequence: `--cross-kernel` splits preparation, compilation and packaging into separate architecture stages. Prebuilt ARM64 helpers and source receipts are checked before packaging.
- Uncertainty: a complete cross build, package installation and Xiaomi Pad 7 boot have not been verified.
- Next validation: build with `--cross-kernel --rebuild-kernel`, inspect RPM ELF architectures and boot all intended images on the tablet.
