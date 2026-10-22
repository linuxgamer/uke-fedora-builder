#!/usr/bin/env bash
# Host-only: update a verified existing F2FS regular file without formatting it.
set -Eeuo pipefail
[[ $# == 2 && $2 =~ ^localhost/[a-zA-Z0-9._:/-]+$ ]]
job=$(realpath "$1") vm_image=$2
# shellcheck source=src/image/filesystem-policy.sh
source "$(dirname "$0")/filesystem-policy.sh"
[[ $(userdata_profile_filesystem "$(dirname "$0")/../../configs/images/userdata-rawhide.json") == f2fs ]]
[[ -f $job/device-packages.complete && -f $job/root-audit.complete && ! -e $job/rootfs-frozen ]]
[[ -f $job/vm/vmlinuz && -f $job/vm/initramfs.cpio.gz && -d $job/root ]]
baseline=$job/baseline/userdata.f2fs.img
[[ -f $baseline && ! -L $baseline && -f $baseline.sha256 ]]
[[ $(stat -c %s "$baseline") == 15032385536 ]]
(cd "$job/baseline"; sha256sum -c --strict userdata.f2fs.img.sha256)
[[ $(blkid -p -s TYPE -o value "$baseline") == f2fs ]]
[[ $(blkid -p -s LABEL -o value "$baseline") == UKE_LINUX ]]
[[ ! -e $job/root/.uke-staged-root && ! -L $job/root/.uke-staged-root ]]
mkdir -p "$job/image"
[[ ! -L $job/image && ! -e $job/image/userdata.f2fs.img ]]
blkid -p -s UUID -o value "$baseline" > "$job/image/fsuuid.expected"
[[ -s $job/image/fsuuid.expected ]]
podman unshare bash "$(dirname "$0")/metadata-manifest.sh" "$job/root" "$job/image/xattrs.expected.tsv"
podman unshare tar --create --numeric-owner --one-file-system --sort=name \
    --acls --xattrs --xattrs-include=security.capability \
    -f - -C "$job/root" . | zstd -T2 -3 -o "$job/image/rootfs.tar.zst"
(cd "$job/image"; sha256sum rootfs.tar.zst > rootfs.tar.zst.sha256)
cp --reflink=auto --sparse=always -- "$baseline" "$job/image/userdata.f2fs.img"
touch "$job/rootfs-frozen"
podman run --rm --pull=never --network=none --security-opt label=disable --cpus=2 --memory=3g --device /dev/kvm \
    -v "$job/vm:/vm:ro" -v "$job/image:/job" "$vm_image" \
    /usr/bin/timeout 1200 qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -smp 2 -m 2048 -nodefaults -display none -monitor none -serial stdio \
    -no-reboot -nic none -kernel /vm/vmlinuz -initrd /vm/initramfs.cpio.gz \
    -append 'console=ttyS0 rdinit=/uke-compose-init selinux=0 panic=1 uke.f2fs-compose=1 uke.f2fs-patch=1' \
    -drive if=none,id=target,format=raw,file=/job/userdata.f2fs.img,cache=none,discard=unmap,detect-zeroes=unmap \
    -device virtio-blk-pci,drive=target,logical_block_size=4096,physical_block_size=4096 \
    -virtfs local,path=/job,mount_tag=compose,security_model=none,readonly=on \
    > "$job/logs/f2fs-existing-patch.log" 2>&1
grep -Eq $'^UKE_F2FS_COMPOSE_PASSED\r?$' "$job/logs/f2fs-existing-patch.log"
if grep -Eq 'UKE_F2FS_COMPOSE_FAILED|Kernel panic|formatting|format successful' "$job/logs/f2fs-existing-patch.log"; then exit 1; fi
[[ $(stat -c %s "$job/image/userdata.f2fs.img") == $(stat -c %s "$baseline") ]]
[[ $(blkid -p -s UUID -o value "$job/image/userdata.f2fs.img") == "$(cat "$job/image/fsuuid.expected")" ]]
(cd "$job/image"; sha256sum userdata.f2fs.img > userdata.f2fs.img.sha256)
touch "$job/f2fs-image.complete" "$job/f2fs-xattr-audit.complete"
echo 'Existing F2FS patched and checked; filesystem UUID and capacity preserved.'
