#!/usr/bin/env bash
# Original filesystem tools on disposable regular files, without mounts or device writes.
set -Eeuo pipefail
[[ $# == 2 && -x $1 && -x $2 ]]
check=$(realpath "$1") codec=$(realpath "$2")
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/src/image/filesystem-policy.sh"
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cd "$work"
for invalid in '' fat32 F2FS 'ext4;false' '../xfs'; do
    if userdata_filesystem "$invalid" >/dev/null 2>&1; then exit 1; fi
done
truncate -s 262144 Image
printf '\000\000\004\000\000\000\000\000' | dd of=Image bs=1 seek=16 conv=notrunc status=none
printf '\101\122\115\144' | dd of=Image bs=1 seek=56 conv=notrunc status=none
"$codec" create Image absent.img userdata
{
    printf '\004\000\000\000\104\000\000\000\001\105\113\125UKE\000'
    printf 'root-selector-v2;userdata=f2fs,ext4,xfs,btrfs;slot=a,b;vrr-min=0,30\000'
} > note
[[ $(stat -c %s note) == 84 ]]
# The retained note crosses the verifier's 128 KiB read boundary.
dd if=note of=Image bs=1 seek=126936 conv=notrunc status=none
"$codec" create Image capable.img userdata
boot_hash=$(sha256sum capable.img | cut -d ' ' -f1)
reject() { if "$check" "$@" > refused.log 2>&1; then echo 'Invalid filesystem payload admitted' >&2; exit 1; fi; }
for filesystem in ext4 xfs btrfs; do
    truncate -s 512M root.img
    case $filesystem in
        ext4) mkfs.ext4 -F -b 4096 -L UKE_LINUX root.img > mkfs.log 2>&1;;
        xfs) mkfs.xfs -f -b size=4096 -L UKE_LINUX root.img > mkfs.log 2>&1;;
        btrfs) mkfs.btrfs -f -s 4096 -L UKE_LINUX root.img > mkfs.log 2>&1;;
    esac
    zstd -q -T1 -3 root.img -o root.zst
    root_hash=$(sha256sum root.img | cut -d ' ' -f1)
    "$check" root.zst 536870912 "$root_hash" capable.img "$boot_hash" "$filesystem"
    reject root.zst 536870912 "$root_hash" absent.img "$(sha256sum absent.img | cut -d ' ' -f1)" "$filesystem"
    reject root.zst 536870912 "$root_hash" capable.img "$boot_hash"
    reject root.zst 536870912 "$root_hash" capable.img "$boot_hash" invalid
    for other in f2fs ext4 xfs btrfs; do
        [[ $other == "$filesystem" ]] || reject root.zst 536870912 "$root_hash" capable.img "$boot_hash" "$other"
    done
    cp --reflink=auto --sparse=always root.img bad.img
    case $filesystem in
        ext4) offset=1028 count=4;;
        xfs) offset=8 count=8;;
        btrfs) offset=65648 count=8;;
    esac
    dd if=/dev/zero of=bad.img bs=1 seek="$offset" count="$count" conv=notrunc status=none
    zstd -q -T1 -3 bad.img -o bad.zst
    reject bad.zst 536870912 "$(sha256sum bad.img | cut -d ' ' -f1)" capable.img "$boot_hash" "$filesystem"
    rm root.img root.zst bad.img bad.zst
done
cp Image duplicate.Image
dd if=note of=duplicate.Image bs=1 seek=131072 conv=notrunc status=none
"$codec" create duplicate.Image duplicate.img userdata
truncate -s 512M root.img
mkfs.ext4 -F -b 4096 -L UKE_LINUX root.img > mkfs.log 2>&1
zstd -q -T1 -3 root.img -o root.zst
root_hash=$(sha256sum root.img | cut -d ' ' -f1)
reject root.zst 536870912 "$root_hash" duplicate.img "$(sha256sum duplicate.img | cut -d ' ' -f1)" ext4
cp Image unaligned.Image
dd if=/dev/zero of=unaligned.Image bs=1 seek=126936 count=84 conv=notrunc status=none
dd if=note of=unaligned.Image bs=1 seek=126937 conv=notrunc status=none
"$codec" create unaligned.Image unaligned.img userdata
reject root.zst 536870912 "$root_hash" unaligned.img "$(sha256sum unaligned.img | cut -d ' ' -f1)" ext4
cp absent.img padding.img
dd if=note of=padding.img bs=1 seek=266240 conv=notrunc status=none
reject root.zst 536870912 "$root_hash" padding.img "$(sha256sum padding.img | cut -d ' ' -f1)" ext4
printf 'X' | dd of=root.img bs=1 seek=1144 conv=notrunc status=none
zstd -q -f -T1 -3 root.img -o root.zst
reject root.zst 536870912 "$(sha256sum root.img | cut -d ' ' -f1)" capable.img "$boot_hash" ext4
echo 'Three real filesystems, explicit format admission, default-F2FS compatibility, labels and streamed unique capability checks passed; regular files only.'
