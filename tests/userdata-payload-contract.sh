#!/usr/bin/env bash
# Disposable regular files only. The production verifier has no write mode.
set -Eeuo pipefail
[[ $# == 2 && -x $1 && -x $2 ]]
check=$(realpath "$1") codec=$(realpath "$2")
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cd "$work"
truncate -s 512M root.img
mkfs.f2fs -f -l UKE_LINUX -O extra_attr,inode_checksum,sb_checksum root.img > mkfs.log
zstd -q -T1 -3 root.img -o root.img.zst
root_hash=$(sha256sum root.img | cut -d ' ' -f1)
truncate -s 64 Image
printf '\100\000\000\000\000\000\000\000' | dd of=Image bs=1 seek=16 conv=notrunc status=none
printf '\101\122\115\144' | dd of=Image bs=1 seek=56 conv=notrunc status=none
"$codec" create Image userdata.img userdata
boot_hash=$(sha256sum userdata.img | cut -d ' ' -f1)
"$check" root.img.zst 536870912 "$root_hash" userdata.img "$boot_hash"
"$codec" create Image userdata-vrr.img userdata-vrr
"$check" root.img.zst 536870912 "$root_hash" userdata-vrr.img "$(sha256sum userdata-vrr.img | cut -d ' ' -f1)"
reject() { if "$check" "$@" > refused.log 2>&1; then echo 'Invalid payload admitted' >&2; exit 1; fi; }
reject root.img.zst 536870912 "$(printf '%064d' 0)" userdata.img "$boot_hash"
reject root.img.zst 536875008 "$root_hash" userdata.img "$boot_hash"
reject root.img.zst -1 "$root_hash" userdata.img "$boot_hash"
reject root.img.zst 536870912 "$root_hash" userdata.img invalid
ln -s root.img.zst symlink
reject symlink 536870912 "$root_hash" userdata.img "$boot_hash"
mkfifo pipe
reject pipe 536870912 "$root_hash" userdata.img "$boot_hash"
reject /dev/null 536870912 "$root_hash" userdata.img "$boot_hash"
head -c -1 root.img.zst > truncated
reject truncated 536870912 "$root_hash" userdata.img "$boot_hash"
cat root.img.zst root.img.zst > second-frame
reject second-frame 536870912 "$root_hash" userdata.img "$boot_hash"
cp root.img.zst trailing
printf X >> trailing
reject trailing 536870912 "$root_hash" userdata.img "$boot_hash"
truncate -s 512M invalid.img
zstd -q -T1 -3 invalid.img -o invalid.zst
reject invalid.zst 536870912 "$(sha256sum invalid.img | cut -d ' ' -f1)" userdata.img "$boot_hash"
"$codec" create Image linux.img
reject root.img.zst 536870912 "$root_hash" linux.img "$(sha256sum linux.img | cut -d ' ' -f1)"
echo 'Real F2FS/Zstandard and boot-v4 validation, size/hash/frame/truncation and special-file refusals passed; no device opened'
