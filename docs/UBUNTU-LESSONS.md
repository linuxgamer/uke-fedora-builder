# UKE-UBUNTU-ROOT-20261102: require actual policy enforcement

Date: 2 November 2026. Environment: server-side Ubuntu image preparation;
no tablet operations. The public distro selector remains gated until an Ubuntu
backend is qualified. Fedora code and security settings are unchanged.

The previously verified Uke1006u2 cohort supplies a complete Image/DT/modules/
embedded-initramfs input and does not establish root policy loading. Stock
Ubuntu AppArmor must load its policy before a required boot diagnostic runs.
The diagnostic verifies its exact enforce context and an actual denied read,
beside an allowed read. Missing kernel support, parser/load failure or a
mismatched kernel prevents the normal target. A generic VM test can qualify
only userspace policy plumbing, not the Uke kernel or hardware.

The Tenacious libstdc++6 ARM64 archive 16.2.0-3ubuntu1, authenticated against
the retained Ubuntu Packages SHA512, contains optional Python GDB printers.
Their exact debugger locations have explicit dpkg path exclusions. This
preserves the native library, package metadata, notices and licenses; the full
Python runtime/script audit still runs. No Python exception is extended from
Fedora. The initial profile is a noninteractive, credential-free console core,
with no desktop, remote shell, OEM bundle or private calibration.

A standalone compiler check passed with warnings treated as errors; running
the host test outside the required kernel/profile correctly refused. Source
contract checks pass. Native root construction, generic VM enforcement and
Uke boot remain separate pending results, recorded in private build evidence.
