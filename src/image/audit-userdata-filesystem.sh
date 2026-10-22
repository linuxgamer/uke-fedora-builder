#!/usr/bin/env bash
# Read-only host VM audit of a composed regular image; no physical disk is attached.
set -Eeuo pipefail
[[ $# == 2 && $2 =~ ^localhost/[a-zA-Z0-9._:/-]+$ ]]
job=$(realpath "$1") vm_image=$2
repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/src/image/filesystem-policy.sh"
filesystem=$(userdata_profile_filesystem "$repo/configs/images/userdata-rawhide.json")
image=$job/image/userdata.$filesystem.img
[[ -f $job/$filesystem-image.complete && -f $job/image/xattrs.expected.tsv ]]
[[ -f $image && ! -L $image && -f $job/vm/vmlinuz && -f $job/vm/initramfs.cpio.gz ]]
[[ $(blkid -p -s TYPE -o value "$image") == "$filesystem" ]]
before=$(sha256sum "$image" | cut -d ' ' -f1)
podman run --rm --pull=never --network=none --security-opt label=disable --cpus=2 --memory=3g --device /dev/kvm \
    -v "$job/vm:/vm:ro" -v "$job/image:/job:ro" "$vm_image" \
    /usr/bin/timeout 1200 qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -smp 2 -m 2048 -nodefaults -display none -monitor none -serial stdio \
    -no-reboot -nic none -kernel /vm/vmlinuz -initrd /vm/initramfs.cpio.gz \
    -append "console=ttyS0 rdinit=/uke-compose-init selinux=0 panic=1 uke.userdata-compose=1 uke.userdata-filesystem=$filesystem uke.userdata-xattr-audit=1" \
    -drive "if=none,id=target,format=raw,file=/job/userdata.$filesystem.img,readonly=on,cache=none" \
    -device virtio-blk-pci,drive=target,logical_block_size=4096,physical_block_size=4096 \
    -virtfs local,path=/job,mount_tag=compose,security_model=none,readonly=on \
    > "$job/logs/$filesystem-readonly-audit.log" 2>&1
for result in XATTR_AUDIT READONLY_CHECK; do
    grep -Eq "^UKE_USERDATA_${result}_PASSED:$filesystem"$'\r?$' "$job/logs/$filesystem-readonly-audit.log"
done
if grep -Eq 'UKE_USERDATA_COMPOSE_FAILED|Kernel panic' "$job/logs/$filesystem-readonly-audit.log"; then exit 1; fi
[[ $(sha256sum "$image" | cut -d ' ' -f1) == "$before" ]]
touch "$job/$filesystem-readonly-audit.complete" "$job/$filesystem-fsck-readonly.complete"
printf '%s read-only metadata and filesystem checks passed with unchanged image hash.\n' "$filesystem"
