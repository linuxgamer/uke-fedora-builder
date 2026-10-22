# How the Fedora 44 images are assembled

`build-fedora44-images.sh` checks the bundled Xiaomi OS3.0.304.0 inputs,
builds the Linux 7.2.11 and hardware RPMs, then creates a shared TTY base.
Each selected desktop gets its own userdata image and matched `boot_a` image.
The output profiles are separate releases; they are not combined in one rootfs.

The kernel source, patches and RPM spec live in `senemos-uke-kernel/`. Device
RPMs and OEM payloads live in `uke-linux-hardware-support/`. The Fedora image
recipes and stock boot template live in this builder. Downloaded source files
and build products are kept outside Git.

The older Rawhide `core`, `boot` and `boot-pair` paths are development tools.
For the Xiaomi Pad 7 release, use the Fedora 44 command in [BUILDING.md](BUILDING.md).
