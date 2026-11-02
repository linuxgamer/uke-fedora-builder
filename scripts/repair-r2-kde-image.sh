#!/usr/bin/env bash
# One-release offline repair. No package installation, host block device or boot write.
set -Eeuo pipefail
[[ $# == 2 && -f $1 && ! -L $1 ]] || { echo 'Usage: repair-r2-kde-image.sh R2_KDE.img.zst NEW_DIRECTORY' >&2; exit 2; }
input=$(realpath -- "$1")
output=$(realpath -m -- "$2")
[[ ! -e $output && ! -L $output && $output != / ]] || exit 2
input_hash=$(sha256sum "$input" | cut -d' ' -f1)
[[ $input_hash == e771ec34e53f30fd66e5878095c969e930e5e20c24aa8e88e0a9fa543f3e8e10 ]] || { echo 'Only the verified R2 KDE input is accepted' >&2; exit 1; }
for tool in sha256sum zstd simg2img debugfs e2fsck fallocate dd od stat sed; do command -v "$tool" >/dev/null; done
mkdir -- "$output"
mkdir -- "$output/work" "$output/assets" "$output/receipts"
work=$output/work
receipts=$output/receipts
sparse=$work/system.sparse
raw=$work/root.raw
unit=/etc/systemd/system/uke-root-capacity.service
zstd -dc "$input" > "$sparse"
[[ $(sha256sum "$sparse" | cut -d' ' -f1) == 5b21574fc8a7bb7098103fb2948fd28daf0258ef120c6f4d8094149e0c00a39b ]] || exit 1
simg2img "$sparse" "$raw"
[[ $(sha256sum "$raw" | cut -d' ' -f1) == 4a67de8af2813a129f5f590687f01c4b262f936de1c8381e678b7a10b15a9363 ]] || exit 1
fallocate -d "$raw"
e2fsck -fn "$raw" > "$receipts/input-fsck.log" 2>&1
debugfs -R "dump $unit $work/original.service" "$raw" > "$receipts/dump.log" 2>&1
[[ $(stat -c %s "$work/original.service") == 2094 ]]
[[ $(grep -o 'findmnt -n -o' "$work/original.service" | wc -l) == 2 ]]
sed 's/findmnt -n -o/findmnt -rn -o/g' "$work/original.service" > "$work/corrected.service"
[[ $(stat -c %s "$work/corrected.service") == 2096 ]]
debugfs -R "stat $unit" "$raw" > "$receipts/original-inode.txt" 2>&1
debugfs -R "ea_get $unit security.selinux" "$raw" > "$receipts/original-selinux.txt" 2>&1
grep -Fq '(0):12186' "$receipts/original-inode.txt"
dd if="$work/corrected.service" of="$raw" bs=4096 seek=12186 conv=notrunc status=none
debugfs -w -R "set_inode_field $unit size 2096" "$raw" > "$receipts/patch.log" 2>&1
debugfs -R "ea_get $unit security.selinux" "$raw" > "$receipts/result-selinux.txt" 2>&1
cmp "$receipts/original-selinux.txt" "$receipts/result-selinux.txt"
[[ $(sha256sum "$raw" | cut -d' ' -f1) == 50d3dc050b3655db14e009f6f40a62f88c3cd1dfd6e23eb39002b6939887f71a ]] || exit 1
e2fsck -fn "$raw" > "$receipts/result-fsck.log" 2>&1

# Preserve the original RAW/FILL layout. Copy only the two prevalidated changed
# logical blocks from the repaired filesystem into their existing RAW chunks.
read -r magic version headers block total chunks checksum < <(od -An -tu4 -w28 -N28 "$sparse")
[[ $magic == 3978755898 && $version == 1 && $headers == 786460 &&
   $block == 4096 && $total == 2097152 && $checksum == 0 ]]
position=28 logical=0 changed=0
for ((index=0; index<chunks; index++)); do
    read -r type blocks stored < <(od -An -tu4 -j "$position" -N12 "$sparse")
    ((blocks > 0 && logical + blocks <= total))
    case $type in
        51905) ((stored == 12 + blocks * block));;
        51906) ((stored == 16));;
        *) echo 'Unsupported sparse chunk, including DONT_CARE' >&2; exit 1;;
    esac
    for target in 1140 12186; do
        if ((target >= logical && target < logical + blocks)); then
            [[ $type == 51905 ]] || exit 1
            offset=$((position + 12 + (target - logical) * block))
            dd if="$raw" of="$sparse" bs=4096 skip="$target" count=1 oflag=seek_bytes seek="$offset" conv=notrunc status=none
            changed=$((changed + 1))
        fi
    done
    position=$((position + stored))
    logical=$((logical + blocks))
done
[[ $changed == 2 && $logical == "$total" && $position == "$(stat -c %s "$sparse")" ]]
[[ $(sha256sum "$sparse" | cut -d' ' -f1) == 33e2d7965667d564e5151bfa50f20c223588a51a3b9d1e868a9607f8c2849a10 ]] || exit 1
rm -- "$raw"
simg2img "$sparse" "$raw"
sha256sum "$raw" > "$receipts/aosp-decoded.sha256"
[[ $(cut -d' ' -f1 "$receipts/aosp-decoded.sha256") == 50d3dc050b3655db14e009f6f40a62f88c3cd1dfd6e23eb39002b6939887f71a ]] || exit 1
e2fsck -fn "$raw" > "$receipts/aosp-fsck.log" 2>&1
debugfs -R "dump $unit $work/serialized.service" "$raw" >> "$receipts/dump.log" 2>&1
cmp "$work/corrected.service" "$work/serialized.service"
rm -- "$raw"
asset=$output/assets/fedora-rawhide-kde-plasma-uke-senemos-system-021126-r3.img.zst
zstd -T2 -8 --check "$sparse" -o "$asset"
zstd --test "$asset"
[[ $(zstd -dc "$asset" | sha256sum | cut -d' ' -f1) == 33e2d7965667d564e5151bfa50f20c223588a51a3b9d1e868a9607f8c2849a10 ]]
sha256sum "$asset" > "$receipts/asset.sha256"
echo 'R2-derived KDE repair and independent serialized-image checks passed.'
