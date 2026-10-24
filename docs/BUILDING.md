# Build Fedora 44 images for Xiaomi Pad 7

Run these commands from the root of the `uke-fedora` workspace. Docker or
Podman, `avbtool`, `jq`, `g++`, `python3`, `sha256sum` and `zstd` must be available. The
stock boot template and required OS3.0.304.0 OEM files are bundled and
verified by the script.

For KDE and GNOME:

```sh
./uke-fedora-builder/build-fedora44-images.sh --cross-kernel \
  --profiles kde,gnome --output build/fedora44-images-desktop
```

Omit `--cross-kernel` on an ARM64 host. Without `--profiles`, the builder makes
separate TTY, KDE, GNOME, Phosh and Plasma Mobile pairs. Desktop builds also
produce a TTY pair as a shared prerequisite. The script creates files only;
it does not flash or select a slot.

The touch firmware defaults to TM, matching the tested tablet's stock panel
ID. If the stock touch driver identifies a CSOT panel, add `--touch-panel csot`
to the build command. The daemon checks the panel ID before loading firmware.

Check progress or stop a running build from another terminal:

```sh
./uke-fedora-builder/build-fedora44-images.sh --status --output build/fedora44-images-desktop
./uke-fedora-builder/build-fedora44-images.sh --stop --output build/fedora44-images-desktop
```

To continue an interrupted build, repeat the build command with `--resume`.
The detailed log is `build.log` in the output directory. Completed stages and
matching RPMs are reused after input and checksum checks. See
[Fedora 44 build cache](FEDORA44-BUILD-CACHE.md) for cache details.
Run `--audit-only` with the original `--profiles` and `--output` to check
completed image pairs again without rebuilding them.
If a mirror advertises the missing Fedora 44 `ca-certificates` update, the
builder obtains that exact RPM from Fedora Koji and checks its pinned SHA-256.
The Koji build is unsigned; this fallback uses the pinned hash instead of an
RPM signature and is reported in the build log.

Before using an image, check that `status.json` says `complete` and read
`audit-report.txt` beside the images. The builder checks image hashes,
critical rootfs files and errors reported by package install scripts. It
rebuilds the udev hardware database with native Fedora 44 tools before making
each `userdata.img`; an incomplete database fails the audit.

The TTY profile includes an experimental touchscreen keyboard. Its service
starts only when the framebuffer, touchscreen and uinput devices are present.
Touch-only account setup on the Xiaomi Pad 7 still needs a physical test.
