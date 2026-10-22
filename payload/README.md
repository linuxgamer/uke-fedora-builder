# Fedora 44 stock boot template

`uke-os3.0.304.0-boot.zst` is the zstd-compressed `images/boot.img` from
`uke_global_images_OS3.0.304.0.WOZMIXM_16.0` for Xiaomi Pad 7 (`uke`). The
compressed SHA-256 is
`d001b8d7a15d088ae24fcb90d85023bd7af2360f8fdb72cf70f4e1b8c6085f1b`;
the uncompressed `boot.img` SHA-256 is
`1eaf4858a7c70bee9b663b485f3192b164738bbdae3edbb986a5419621c8ef30`.

`build-fedora44-images.sh` checks both hashes, unpacks the image into a
temporary directory and removes that copy on exit. The boot builder uses the
reviewed template's metadata and replaces the kernel payload. It does not
flash a device.

The maintainer reports a redistribution grant covering the OEM inputs. Record
and check its terms for this exact file before pushing the archive or uploading
images. Tablet boot with the current Fedora 44 source revision remains untested.
