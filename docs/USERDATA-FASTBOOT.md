# Uke userdata test images

22 October 2026 · Uke / SM7675 · Fedora Rawhide AArch64 · original Fedora Plasma.
This private test image includes the firmware and touch data matched to the
current tablet. Do not upload or redistribute the system image. No existing
account, password, SSH key or Wi-Fi connection is copied into the fresh root.

The source profile selects `senemos-uke-linux-kernel-mainline-singleboot`
7.2.12-9. Read the delivered manifest for the actual artifacts. Its exact signed core, modules, DTBs and boot bundle are shared with
the ordinary mainline profile; the singleboot selection targets `userdata`,
while the ordinary profile targets `linux`. The only configured COPR is
`mcc45tr/uke-linux-test`; original Fedora repositories remain available.
Native audio remains disabled in this candidate.

The 22 October source recipe requires the factory WLAN and Bluetooth
capabilities from boot integration `1.5.0` or later. Offline checks reject the
retired standalone bridge packages and power-profile overlay, including its
SELinux module. These source checks do not establish a newly delivered image
or physical first boot of an alternative filesystem.

| File | Target and contents |
|---|---|
| `system.img` / `userdata.img` | Identical Android sparse root image; filesystem from the manifest; target **userdata** |
| `boot.img` | Android boot v4, matched selected kernel, explicit userdata root selector |
| `SHA256SUMS` | Image and record checksums |
| `manifest.json` | Exact artifacts, source and validation limits |
| `rollback/boot_b-before-refresh.img` | Read-only 21 October checkpoint of the running release-17 Linux boot B |

Flashing userdata replaces the entire existing filesystem and erases all Fedora
or Android data stored in that partition. Back up needed files first. The root
filesystem starts at 14 GiB. The manifest's `root_growth` records the audited
growth mechanism: F2FS grows offline before mounting; EXT4/XFS/Btrfs use original
systemd-growfs once before login and retain a completion record. Completed
F2FS growth leaves only a read-only capacity check on later boots. Fastboot
itself does not resize the filesystem. Userdata must be at least
15,032,385,536 bytes and boot B at least 100,663,296 bytes. GPT is not changed.
The existing separate `linux` partition is not an installation target.
Release-14 and release-17 matched module sets are retained alongside the selected
selected kernel in the default F2FS profile. Future EXT4/XFS/Btrfs profiles must
retain kernels with the v2 root-selector ABI and matching filesystem support;
old F2FS-only kernels are not accepted as their rollback set. The rollback
checkpoint is a boot image, not a backup of userdata
or proof of automatic failed-boot recovery.

Use current Android platform-tools and verify the files before manual writes:

```sh
sha256sum -c SHA256SUMS
fastboot getvar product
fastboot getvar current-slot
fastboot getvar partition-size:userdata
fastboot getvar partition-size:boot_b
```

Only after confirming the Uke device, capacities and intended slot B:

```sh
fastboot flash userdata system.img
fastboot flash boot_b boot.img
fastboot set_active b
fastboot reboot
```

Do not run `fastboot -w` or format userdata after flashing: it would erase Fedora.
Boot A is not written. All existing Fedora or Android data in userdata is still
erased. This is a manual test image, not a recovery-flashable installer.

First boot starts original Plasma Setup. Create the account and connect Wi-Fi.
Root password login is locked and no human account is preset. Plasma Setup
creates an administrator in `wheel`; Plasma Login Manager provides subsequent
logins. All packaged translations, glibc locale data and the selected multilingual
fonts/input methods are retained. Some upstream translations may be incomplete.
SSH starts disabled; enable it locally if remote testing is required:

```sh
sudo systemctl enable --now sshd.service
```

SELinux is enforcing, original firewalld is enabled and nftables tools are
installed. Standalone nftables startup is disabled because firewalld manages the
rules. Signed COPR packages provide sensor startup, packaged VRR/brightness
defaults, original Fedora Fastfetch without project configuration and half-RAM swap
initialization. Actual sensor response, VRR continuity and tablet swap activation
still need physical acceptance of this image.

The selected Control channel is `test`. Future software updates use DNF and
COPR; userdata does not need to be flashed again for ordinary package updates.
`uke-control brunch` supplies explicit channel management. Switching channels
does not bypass signature, matched-kernel or boot-update admission checks.

CDC remains manual through `sudo uke-control set cdc on`. The packaged userdata
updater validates, stages and acknowledges boot trials, but refuses an unqualified
alternate early-firmware cohort. Physical A/B recovery remains unaccepted, and
boot A/B does not roll back the shared root filesystem.
The saved boot-B checkpoint can be restored only after verifying its own root
selector and filesystem compatibility. Retaining an old Image does not prove
that it can mount a new filesystem type. This does not restore the userdata that
flashing replaced:

```sh
fastboot flash boot_b rollback/boot_b-before-refresh.img
fastboot set_active b
fastboot reboot
```

Host package, filesystem/metadata, sparse decode and boot/Image checks do not
establish physical boot, ABL root-selector forwarding or hardware acceptance.
Recovery installation and native Uke acceptance of newly composed filesystem
variants remain separate stages. No in-place filesystem conversion is performed.
