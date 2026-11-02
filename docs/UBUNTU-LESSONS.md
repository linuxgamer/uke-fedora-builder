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

The signed Tenacious AppArmor package also carries the optional Python Apport
hook /usr/share/apport/package-hooks/source_apparmor.py. A package-index-bound
archive inspection confirmed it. The image excludes only that optional hook
family and reapplies bootstrap hook-owning packages; native policy/loading and
all notices remain. Audits report any remaining Python file rather than hiding
it. systemd-resolved also converts the build resolver during package setup;
source downloads need a temporary server resolver restored before finalization.

A locked login prompt is not an adequate keyboard-free test interface. The
minimal profile now reserves tty1 for a noninteractive status service, displays
probe/policy/rootfs/kernel states and stores the same short report under
/var/lib/uke-ubuntu-test/. A one-time 60-second refresh restores it after early
boot messages. The probe also checks the real root filesystem type. No shell,
autologin, password, network listener or credential is added. A photograph is
the initial retrieval method; failed framebuffer/DT handoff leaves no remote
retrieval route in this profile. A separate read-only recovery procedure would
need authorization. The generic VM must exercise the reporter and retain its
written result before shutdown; this still does not qualify the Uke display.
