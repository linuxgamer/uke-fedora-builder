# Historical Rawhide userdata test output

This file is copied into artifacts made by the older Rawhide exporter. That
path uses different boot slots and package versions from the Xiaomi Pad 7
Fedora 44 release builder. Do not use its artifacts as Fedora 44 installation
images.

For current releases, build a matched Fedora 44 `boot_a`/`userdata` pair with
`build-fedora44-images.sh` and use the installation instructions in the root
`uke-fedora` repository. Verify the selected profile's manifest and
`SHA256SUMS` before any device write. Writing `userdata` erases the data in
that partition. The builder itself never flashes a device.
