# Fedora 44 stock boot template

`uke-os3.0.303.0-boot.zst` is the zstd-compressed `images/boot.img` from
`uke_global_images_OS3.0.303.0.WOZMIXM_16.0` for Xiaomi Pad 7 (`uke`). The
compressed SHA-256 is
`47851c5899e9343a544f3efa6e12f5408fdc87f54da7078070025e7745160263`;
the uncompressed `boot.img` SHA-256 is
`efdee1d4e1acd7f6e77615330dbcb045caeeccad8568d89fa6abd627f606e77f`.

`build-fedora44-images.sh` checks both hashes, unpacks the image into a
temporary directory and removes that copy on exit. The boot builder uses the
reviewed template's metadata and replaces the kernel payload. It does not
flash a device.

The maintainer reports a redistribution grant covering the OEM inputs. Record
and check its terms for this exact file before pushing the archive or uploading
images. Tablet boot with the current Fedora 44 source revision remains untested.
