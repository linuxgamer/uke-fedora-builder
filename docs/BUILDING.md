# Build Fedora 44 images for Xiaomi Pad 7

Run these commands from the root of the `uke-fedora` workspace. Docker or
Podman, `avbtool`, `jq`, `g++`, `sha256sum` and `zstd` must be available. The
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

Check progress or stop a running build from another terminal:

```sh
./uke-fedora-builder/build-fedora44-images.sh --status --output build/fedora44-images-desktop
./uke-fedora-builder/build-fedora44-images.sh --stop --output build/fedora44-images-desktop
```

To continue an interrupted build, repeat the build command with `--resume`.
The detailed log is `build.log` in the output directory. Completed stages and
matching RPMs are reused after input and checksum checks. See
[Fedora 44 build cache](FEDORA44-BUILD-CACHE.md) for cache details.
