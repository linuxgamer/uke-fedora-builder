#!/usr/bin/env bash
# Reuse the verified, profile-independent boot_a image for a desktop rootfs.
set -Eeuo pipefail

[[ $# == 3 ]] || { echo 'Usage: assemble-pair-from-tty.sh TTY_PAIR DESKTOP_ROOTFS NEW_OUTPUT' >&2; exit 2; }
tty_pair=$(realpath -- "$1")
rootfs=$(realpath -- "$2")
output=$(realpath -m -- "$3")
[[ ! -e $output && ! -L $output ]] || { echo 'Output already exists' >&2; exit 1; }
[[ -d $tty_pair && -d $rootfs && ! -L $tty_pair && ! -L $rootfs ]] || exit 1
[[ $(cat "$tty_pair/PROFILE-ID") == tty ]] || exit 1
profile=$(cat "$rootfs/PROFILE-ID")
case $profile in kde|gnome|phosh|plasma-mobile) ;; *) exit 1;; esac
[[ $(cat "$tty_pair/BUILD-INPUTS.sha256") == "$(cat "$rootfs/BUILD-INPUTS.sha256")" ]] || exit 1
(cd "$tty_pair" && sha256sum -c --status SHA256SUMS)
(cd "$rootfs" && sha256sum -c --status SHA256SUMS)
[[ $(jq -er .profile "$tty_pair/manifest.json") == tty ]] || exit 1
[[ $(jq -er .sha256.boot "$tty_pair/manifest.json") == "$(sha256sum "$tty_pair/fedora_boot.img" | cut -d' ' -f1)" ]] || exit 1
mkdir -p "$output"
for name in fedora_boot.img Image boot.config Module.symvers boot-initramfs.cpio.gz \
            stock-header.json boot-header.json BUILD-PLATFORM; do
    cp --reflink=auto "$tty_pair/$name" "$output/$name"
done
cp --reflink=auto "$rootfs/userdata.img" "$output/userdata.img"
cp "$rootfs/PROFILE-ID" "$rootfs/TOUCH-PANEL" "$rootfs/LOCAL-BLOBS.sha256" "$output/"
jq --arg profile "$profile" --arg panel "$(cat "$rootfs/TOUCH-PANEL")" \
   --arg userdata "$(sha256sum "$output/userdata.img" | cut -d' ' -f1)" \
   --argjson root_bytes "$(stat -c %s "$rootfs/userdata.raw.img")" \
   '.profile=$profile | .experimental_desktop=($profile=="phosh" or $profile=="plasma-mobile") |
    .touch_panel=$panel | .root_image_logical_bytes=$root_bytes | .sha256.userdata=$userdata' \
   "$tty_pair/manifest.json" > "$output/manifest.json"
(cd "$output" && sha256sum fedora_boot.img userdata.img Image boot.config Module.symvers \
    boot-initramfs.cpio.gz stock-header.json boot-header.json manifest.json PROFILE-ID \
    TOUCH-PANEL LOCAL-BLOBS.sha256 BUILD-PLATFORM > SHA256SUMS)
printf 'Image pair: %s/fedora_boot.img and %s/userdata.img\n' "$output" "$output"
