# Image release layout

1 November 2026: the image publisher stages an image-only release and retains
manifests, package inventories, source receipts and diagnostic logs in Actions
artifacts. No device action is part of composition or publication.

Names follow `distro-version[-desktop]-uke-senemos-partition-DDMMYY-rN.img`
with `.zst` added for compressed images. Current production composition remains
Fedora Rawhide AArch64, EXT4 and singleboot. Ubuntu image creation remains outside
this workflow until package migration is ready.

For 1 November 2026, revision 0:

| Image | Name |
| --- | --- |
| Shared boot | `fedora-rawhide-uke-senemos-boot-011126-r0.img` |
| KDE Plasma root | `fedora-rawhide-kde-plasma-uke-senemos-system-011126-r0.img.zst` |
| GNOME root | `fedora-rawhide-gnome-uke-senemos-system-011126-r0.img.zst` |

The date is frozen at build start in Europe/Istanbul. `IMAGE_BUILD_DATE` can
select a reviewed `DDMMYY` date for repackaging; `IMAGE_REVISION` is a numeric
revision, starting at `0`. Invalid calendar dates, leading-zero revisions and
unsafe values fail. Increment the revision for changed image contents under an
existing filename. Publication never overwrites an existing asset.

Boot filenames omit the desktop. Sharing requires identical boot bytes and a
matching architecture, Fedora release, kernel family/profile/version/release,
source revision, signing key, module/config/DT payload identity and root profile,
including filesystem and capacity. A mismatch fails before upload. Separate
desktop runs may extend the same dated revision only when this contract agrees;
the publisher downloads the existing boot and compares its actual bytes.

The delivery directory has `assets/` containing only `.img` and `.img.zst` files,
and `receipts/` containing all manifests, inventories, source records, checksums
and generated English release notes. The workflow retains a short-lived full
delivery artifact for publication and a separate lightweight receipt artifact
for 90 days. Release-body build links retain earlier desktop runs when another
desktop is added. Diagnostics remain separate Actions artifacts.

The English release body contains a SHA256 table for every image, the shared
cohort and required root capacity, exact decompression/fastboot examples, data
loss and rollback instructions, hardware qualification limits and the current
automatic activation policy. A root image named `system` targets `userdata` in
this singleboot profile. Images remain experimental pre-releases.

The publisher verifies local image hashes and the GitHub asset digests. Existing
drafts are recovered from the authenticated release list and verified by numeric
ID because GitHub's by-tag endpoint omits unpublished drafts. Installation examples
require product/capacity checks, backups and compatible slot-B firmware first.
Extraction, userdata and boot_b writes, active-slot B selection and reboot form
a conditional success chain; a failed command stops the sequence. The generator
never executes tablet commands.
Existing
releases without the new cohort/build-record markers or containing legacy
metadata assets are preserved and rejected as append targets. Migration of a
previously downloaded release requires a separate reviewed plan; these scripts
never delete or rename its assets.

Validation uses tiny byte fixtures and a fake GitHub CLI. Tests cover names,
date/revision errors, actual boot-byte collisions, compatible and incompatible
cohorts, cross-desktop sharing, published root collisions, unsafe layouts,
image-only uploads, checksum tables and preservation of legacy releases. These
tests do not build an OS image or establish tablet acceptance.
