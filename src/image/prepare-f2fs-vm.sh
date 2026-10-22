#!/usr/bin/env bash
# Native x86_64 container stage; only creates a host composition initramfs.
set -Eeuo pipefail
[[ $# == 1 && $1 =~ ^[a-zA-Z0-9.+_-]+$ ]]
release=$1
[[ $(uname -m) == x86_64 && -f /host/boot/vmlinuz-$release ]]
[[ -d /host/usr/lib/modules/$release && -d /job/vm ]]
tools=(bash mount modprobe mkdir grep sha256sum mkfs.f2fs fsck.f2fs resize.f2fs
    mkfs.ext4 e2fsck mkfs.xfs xfs_repair mkfs.btrfs btrfs /usr/lib/systemd/systemd-growfs
    tar setfiles sync umount logger getfattr awk sort cmp realpath cat stty rsync rm blkid fstrim zstd)
paths=()
for tool in "${tools[@]}"; do
    path=$(command -v "$tool") || { echo "Missing host VM tool: $tool" >&2; exit 2; }
    paths+=("$path")
done
mkdir -p /job/vm/empty-conf
install -m755 /builder/src/image/f2fs-vm-init.sh /job/vm/init
install -m755 /builder/src/image/metadata-manifest.sh /job/vm/metadata-manifest
install -m644 /builder/src/image/filesystem-policy.sh /job/vm/filesystem-policy
dracut --force --no-hostonly --no-hostonly-cmdline --no-early-microcode \
    --conf /dev/null --confdir /job/vm/empty-conf \
    --kmoddir /host/usr/lib/modules/"$release" --kver "$release" --gzip \
    --add-drivers 'f2fs ext4 xfs btrfs 9p 9pnet_virtio virtio_blk virtio_pci' \
    --install "${tools[*]}" \
    --include /job/vm/init /uke-compose-init \
    --include /job/vm/metadata-manifest /uke-metadata-manifest \
    --include /job/vm/filesystem-policy /uke-filesystem-policy \
    --omit 'network network-manager network-legacy plymouth crypt systemd-cryptsetup syslog lvm mdraid btrfs i18n' \
    /job/vm/initramfs.cpio.gz
install -m644 /host/boot/vmlinuz-"$release" /job/vm/vmlinuz
# Dracut can report an install failure while returning success; inspect the actual archive.
readback=$(mktemp -d /job/vm/readback.XXXXXX)
trap 'rm -r -- "$readback"' EXIT
gzip -t /job/vm/initramfs.cpio.gz
gzip -cd /job/vm/initramfs.cpio.gz | (cd "$readback"; cpio -idm --quiet --no-absolute-filenames)
# The extracted guest Bash expands its own arguments.
# shellcheck disable=SC2016
chroot "$readback" /usr/bin/bash -c 'for tool in "$@"; do [[ -x $tool ]] || { echo "VM payload missing: $tool" >&2; exit 2; }; done' -- "${paths[@]}"
cmp /job/vm/init "$readback/uke-compose-init"
cmp /job/vm/metadata-manifest "$readback/uke-metadata-manifest"
cmp /job/vm/filesystem-policy "$readback/uke-filesystem-policy"
(cd /job/vm; sha256sum vmlinuz initramfs.cpio.gz > inputs.sha256)
