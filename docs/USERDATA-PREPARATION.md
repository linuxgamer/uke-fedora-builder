# Fedora userdata F2FS preparation

21 October 2026 refresh: the retained private image selects the completed signed
`7.2.12-1` ordinary/singleboot cohort, COPR 11183190/11183373. Both Fedora Rawhide
and test COPR metadata are refreshed before synchronization. Kernel provenance
comes from the image profile rather than stale payload literals. The standard
three-kernel retention includes release 14 and the measured release-17 boot-B
cohort; release 16 is retired through DNF.
The current input/output images are regular files; no tablet operation is part
of composition. Earlier composition details below retain their dated scope.

The current correction retains the previously delivered filesystem. Use
`install-userdata-device-packages.sh` to update the existing root through the
normal signed test COPR, then `patch-userdata-f2fs.sh` to update its verified
regular-file baseline without formatting. OpenSSH is installed but disabled;
only the test COPR is configured. Original Fedora repository definitions remain
in their RPM-owned vendor directory. The instructions below retain the initial
composition record; a fresh composition is not the current update mechanism.

Date: 20 October 2026. Environment: Fedora Rawhide AArch64 RPM composition and
offline host/VM validation for Xiaomi Pad 7 / POCO Pad X1 (`uke`). No tablet
installation or new hardware acceptance is established by this recipe.

## Image profile

The new profile is `configs/images/userdata-rawhide.json`. Compose a fresh root
with original Fedora Plasma applications; do not reuse a pruned Alpha root.
It selects Plasma Login Manager, Plasma Setup, Discover's PackageKit offline
updates, all packaged translations, multilingual fonts/input methods and basic
console tools including `clear`. Documentation and weak dependencies are omitted.
Root is locked and there is no ordinary pre-created user. The original Setup
service creates the first account before the display manager starts.

The test repository `mcc45tr/uke-linux-test` is enabled, with the stable repository
as a fallback. Their package allowlists keep ordinary KDE applications on their
original Fedora packages. The singleboot profile 7.2.11-14 and matching common
kernel tuple are selected from COPR11178622 and the isolated kernel build11178536.
Installation-profile 0.1.0-30 supplies the first-boot classifier. Source packages,
signing keys and archive hashes must be retained with the build record.

One kernel Image supports both root profiles. The userdata boot-v4 container
adds `senemos.root=userdata`; the Linux container uses the existing default.
`senemos-uke-linux-kernel-mainline-singleboot` selects userdata while sharing the
exact signed core, modules, DTBs and boot bundle with the ordinary mainline
profile. F2FS, security labels, xattrs and ACLs are
built into the kernel. The first system boot classifies the actual mounted
physical root, writes the root-owned installation marker and masks its own
oneshot. Login-account changes do not re-run it.

Secure Boot is off. Debug packages and development shell startup are excluded or
disabled; required kernel development diagnostics remain in the candidate.
Existing board handoff settings remain necessary and
are not newly qualified power-management behavior.

## Host stages

The scripts are host automation, not recovery entrypoints. `/job` is a dedicated
container mount of the build directory; `/builder` is this source tree read-only.
Use an AArch64 Fedora DNF SDK for package transactions. On an x86_64 host, run
the SDK through the explicitly selected `qemu-aarch64-static` interpreter.

1. Supply reviewed Fedora 46/COPR public keys, `compose.repo` and the package
   list under `/job/inputs`. Run `compose-userdata-root.sh solve`, then `install`.
   The container RPM macro must request all languages before the transaction.
2. Stage the exact reviewed public device RPMs and kernel tuple in
   `/job/inputs/public-rpms`, with a SHA256SUMS inventory. Preserve their source
   archives; the boot-status22 correction is COPR11178594. Stage the seven
   private firmware/data RPMs separately, with archive hashes, exact RPM file
   metadata and installed-file comparison against the current tablet. Run
   `install-userdata-device-packages.sh`; it verifies local signatures, pins the
   matching kernel tuple and checks dependencies. Do not install SRPMs or debug
   integration subpackages into the target.
   Public signatures remain mandatory. Historical unsigned local archives require
   digest verification and the exact device comparison. Install touch driver/data
   in one dependency-checked transaction; no dummy provider or dependency bypass
   is permitted. This device-matched image is private and must not be redistributed.
3. Run `finalize-userdata-root.sh`. Regenerate hwdb with a recorded native host
   `systemd-hwdb --root=/job/root --strict update`; verify the same database query
   with the target tool. The emulated RPM trigger can fail with `ENOSYS` while
   leaving a stale nonempty database. Run `audit-userdata-policy-sources.sh` to prove that generated
   contexts contain only the original Fedora text plus the signed Uke power
   backend's exact file context. Rebuild caches from that proven text with the
   target `sefcontext_compile`. Remove unmounted bootstrap runtime-tree contents;
   the final root does not carry the install transaction's `/dev/null` stub.
4. Run `audit-userdata-root.sh`, `audit-languages`, and
   `audit-userdata-kernel.sh ROOT CODEC JOB/audit/kernel`. The latter compares both boot containers with the
   installed Image, verifies every module digest, extracts the embedded initramfs
   using its System.map and audits the actual extracted payload. Its
   `growth-policy.json` binds the enabled growth mechanism to the filesystem,
   selected release and Image digest; packaging requires that exact receipt.
5. Record every installed payload package's origin with `query-userdata-origins.sh`
   in the native host container. RPM public-key records are separate from the
   package count; query-time exclusions must not hide the installed kernel tuple.
   Independently verify original Fedora RPM signatures and extract their payloads
   using `audit-original-fedora.sh`. Byte-check permitted original Fedora Python
   helpers with `src/audit/check-target-payload.sh --original-kde-payload`.
   Project helpers and early userspace remain Python-free. Run privacy checks
   with an exact, proven namespace policy from `review-userdata-namespaces.sh`:
   `ROOT ORIGINAL_FEDORA SELINUX_PROOF OUTPUT_JSON VERIFIED_PRIVATE_RPM_TREE`.
   The final argument is a separate extraction of those device-matched archives;
   only byte-identical firmware can retain an OEM build namespace. Actual private
   host paths remain rejected, including inside an otherwise matching firmware.
   No unverified path is admitted merely because it looks like a distro example.
6. Only after those checks pass, record `root-audit.complete`. Build the native
   composition initramfs with `prepare-f2fs-vm.sh` and invoke
   `create-userdata-f2fs.sh JOB NATIVE_VM_CONTAINER`. It creates a 14 GiB regular
   image of the profile's explicit filesystem, labelled `UKE_LINUX`, preserves numeric ownership, ACLs and file
   capabilities, applies the target SELinux policy, compares all archived files
   and metadata, explicitly compares capabilities/ACLs with `getfattr`, checks
   labels again and runs fsck. GNU tar's compare mode alone does not detect a
   missing capability; the separate manifest is required. The VM has no network and
   attaches only that newly created regular image, never a host disk.
   The historical script filenames remain compatible with the F2FS workflow.
   `audit-userdata-filesystem.sh` performs the separate read-only VM audit;
   `patch-userdata-f2fs.sh` explicitly remains F2FS-only.
7. Verify the compressed root and userdata boot payload with the native C++
   checker. Record expanded/compressed sizes, SHA-256, source commits, RPM list,
   key identities and validation limits in the delivery manifest. The Zstandard
   decoder bounds its window to 32 MiB and refuses extra frames and special files.

The GNU/Linux AArch64 checker is not an Android/Bionic executable. A direct
OrangeFox invocation requires a separately reviewed runtime or native recovery
build. Host checks do not establish recovery runtime compatibility.

## Recovery continuation

Delivery at this stage is a data payload, not a flashable installer. It has no
legacy `update-binary` and must not bypass `recovery-uke-ofox` write controls.
The current recovery source has zero accepted live firmware profiles and rejects
legacy ZIP/sideload dispatch. Finish its reviewed native route when that project
is ready, then test both sideload and local-file installation.

Public firmware admission currently contains no OEM firmware. Device-local
WPSS/ADSP/GPU inputs and the three private touchscreen inputs must be provisioned
from a validated source on the same device before activation. They are not
included in the distributable root. Preserve dedicated recovery and stock early
firmware. An installer must reject a source bundle stored on userdata when it
would overwrite that same storage, validate capacity and F2FS compatibility,
resize the new filesystem, verify write readback and record recovery progress.
The payload does not define or authorize a new partition layout.

DNF retains all selected and declared rollback kernel tuples with
`installonly_limit=0`. Automatic kernel activation stays disabled until both
slot directions, success acknowledgement and failed-boot fallback are qualified.
The packaged userdata updater checks installed bundles and physical slot
identity; its presence does not establish automatic recovery or rollback of the
shared root filesystem.

The same frozen payload can be exported as separate sparse userdata and boot
images with the [host-only fastboot exporter](USERDATA-FASTBOOT.md). This changes
the distribution format; firmware provisioning and physical acceptance remain
required. The exporter does not operate a device. The delivered manifest records
the audited first-boot growth mechanism independently of kernel activation.

## Filesystem selection and growth

22 October 2026. The default source profile selects F2FS and signed kernel
`7.2.12-9`. EXT4, XFS and Btrfs use the same explicit `root_filesystem` field.
Changing that field prepares a new filesystem; it never converts an installed
root. Non-F2FS profiles require the new `uke-kernel-update(root-filesystem-v2)`
capability, an embedded v2 root-selector note and built-in support in every
selected or retained kernel. Existing v1 kernels are refused for those profiles.
Signed kernel and hardware candidates provide those interfaces. Physical
EXT4, XFS and Btrfs image boots remain unqualified.

The selected kernel must also provide native platform profiles. Composition
uses the original Fedora Power Profiles daemon, removes the retired Uke overlay
from a retained build root and requires the selected core RPM's capability.
Another installed kernel's capability is insufficient. The policy audit checks
the original daemon, absence of overlay artifacts and exact original Fedora
SELinux context text. These host checks do not establish a new image boot.

| Filesystem | Growth in the prepared installation | Completion |
|---|---|---|
| F2FS | Original fsck/resize tools in initramfs, before root is mounted | Read-only capacity check on later boots; no fsck or resize when full |
| EXT4 / XFS | Original systemd-growfs on the proven mounted root, before login | Atomic completion record skips the service on later boots |
| Btrfs | Same systemd-growfs path; single physical device, top-level root only | Same completion record; multidevice and subvolume roots refused |

Growth uses the existing userdata partition's capacity without changing GPT.
A failed operation does not create a completion record. Fresh image composition
clears the generated installation's completion record; ordinary DNF updates do
not. This is separate from first-run account creation and boot-slot acceptance.

Host VM tests created each of the four filesystems at 1 GiB and grew it to
2 GiB, preserving files, ACLs, capabilities, SELinux labels and UUIDs. Read-only
checks left each whole-image hash unchanged. Native checker tests include
ASan/UBSan and reject wrong filesystem geometry and missing v2 notes. These
tests used an original Fedora x86_64 kernel and synthetic ARM64 boot metadata;
they do not establish Uke boot or repeated-boot acceptance for the new formats.

After the recovery continuation, validate firmware provisioning, userdata boot,
Plasma Setup account creation, login, application offline updates and recovery
under interruption. Android restoration requires its original boot stack and
Android-compatible userdata initialization; retaining F2FS alone does not retain
Android encryption metadata or guarantee that a subsequent ROM will start.
