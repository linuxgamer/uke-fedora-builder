# Ubuntu minimal test root

2 November 2026. The Ubuntu backend is under qualification and remains gated at
the public distribution selector. The initial profile contains Ubuntu Tenacious
27.04 ARM64 systemd/udev, AppArmor, a noninteractive console diagnostic, the
matching private 7.3.1-1006u2 kernel packages and the individually attributed
speaker preset from the unstable PPA. It contains no desktop, OEM firmware
bundle, private calibration, credentials, remote login or automatic boot writer.
Ubuntu libstdc++ includes optional GDB Python printers. Explicit dpkg path
exclusions omit only that debugger support directory and its libstdc++ GDB
auto-load script; the native library, metadata and notices remain unchanged.
The final audit still rejects Python runtimes or any other Python source/bytecode.

The stock Ubuntu AppArmor service loads distribution policy plus one bounded
read-only diagnostic profile. A required unit checks the exact kernel release,
active AppArmor and its own enforce context. It must read an allowed fixture
and receive EACCES for a DAC-readable public denial fixture. Missing support or
failed loading/enforcement prevents the normal multi-user target and requests
the distribution emergency target. No complain-mode fallback is provided.
This checks enforcement for the probe; it does not assert that every process
is confined. Original distribution profiles remain unchanged.

The same policy may be tested separately in a generic-kernel ARM64 VM. Only
the disposable VM copy adds `--vm-policy-test`; this identifies that narrower
scope in its output and never enters the delivered root's unit. A generic VM
result cannot validate the Uke kernel, runtime OEM DT, UFS/framebuffer, root
selector, firmware, rollback or physical tablet.

Singleboot output pairs a filesystem named `userdata.ext4` with the cohort's
`userdata.img` wrapper renamed `boot-userdata.img`. The filesystem label is
`UKE_LINUX`; the existing root guard requires the real physical Uke UFS
partition named `userdata`. No partition offsets or capacity are inferred from
the file size. The compile-stage DT is retained for provenance and is not
applied over runtime OEM firmware evidence. Checksums bind the complete pair.
Image construction is authorized privately; public release and tablet writes
remain separate actions. Firmware rights and source-offer review remain gates
before a distributable image or hardware-readiness claim.

References: [Ubuntu AppArmor](https://ubuntu.com/server/docs/how-to/security/apparmor/)
and [kernel policy-loading requirements](https://docs.kernel.org/admin-guide/LSM/apparmor.html).
