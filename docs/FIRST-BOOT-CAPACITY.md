# First-boot capacity check

2 November 2026 · Fedora Rawhide · util-linux 2.42.4 · host and ARM64 user-mode
emulation. Physical tablet validation remains pending.

R2 used `findmnt -n -o MAJ:MIN /` in `uke-root-capacity.service`. Removing the
heading does not remove column alignment: a valid device number `8:32` is
printed as `  8:32 `. The following anchored device-number check rejects it.
Because account setup and the display manager require this service, this error
can prevent graphical startup even after the root filesystem has grown.

The correction requests raw output with `findmnt -rn` for both root observations.
It retains physical-root admission, block-device identity, measured EXT4 capacity,
the original systemd growfs service, half-RAM disk swap ordering and healthy-slot
acceptance. It does not disable any of these checks.

The real Fedora formatter reproduces the original rejection. The exact ARM64
`findmnt` extracted from the released R2 KDE image also reproduces it under QEMU
user-mode emulation with a synthetic mountinfo record. The actual serialized
systemd command, parsed with systemd 262, fails before the change and passes after
it with otherwise identical full-capacity observations. An undersized filesystem
still fails. These fixtures do not establish the tablet's actual capacity or
exclude an additional device-side startup failure.

The regression test uses the real `findmnt` formatter rather than substituting
an already stripped device number. Future image builds must retain this test.
For an R2-derived repair, change only the existing capacity unit in a separate
copy of the verified KDE filesystem and preserve its inode metadata, filesystem
identity and matching R2 boot/kernel cohort. Record the exact payload difference
and resulting image checksum before publication; never overwrite R2 assets.
