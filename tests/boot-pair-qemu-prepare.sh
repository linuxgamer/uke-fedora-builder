#!/usr/bin/env bash
# Host-only disposable GPT fixtures. Never accepts a device or existing output.
set -Eeuo pipefail
[[ $# == 2 && -s $1/system.raw.img && -s $1/manifest.json && ! -e $2 ]] || exit 2
candidate=$(realpath "$1") out=$2
mkdir -p "$out"
partlabel=$(jq -r '.profile.root_partlabel // "linux"' "$candidate/manifest.json")
[[ $partlabel == userdata || $partlabel == linux ]]
bytes=$(stat -c %s "$candidate/system.raw.img")
[[ $bytes == 3221225472 ]]
# Exercise first-boot growth without changing the GPT on a real device.
partition_bytes=$bytes
[[ $partlabel != userdata ]] || partition_bytes=$((bytes + 128*1024*1024))
for name in correct wrong-partname changed-uuid wrong-fstype duplicate-partname; do
    truncate -s "$((partition_bytes + 4*1024*1024))" "$out/$name.disk"
    partition_name=$partlabel
    if [[ $name == wrong-partname ]]; then
        partition_name=linux
        [[ $partlabel != linux ]] || partition_name=userdata
    fi
    printf 'label: gpt\nunit: sectors\n\nstart=2048,size=%s,type=L,name="%s"\n' "$((partition_bytes / 512))" "$partition_name" | sfdisk "$out/$name.disk"
    if [[ $name == changed-uuid ]]; then
        cp --reflink=auto "$candidate/system.raw.img" "$out/changed-uuid.ext4"
        tune2fs -U random "$out/changed-uuid.ext4"
        dd if="$out/changed-uuid.ext4" of="$out/$name.disk" bs=1M seek=1 conv=notrunc,sparse status=none
        rm "$out/changed-uuid.ext4"
    elif [[ $name == wrong-fstype ]]; then
        truncate -s 32M "$out/wrong-fstype.fat"
        mkfs.vfat "$out/wrong-fstype.fat"
        dd if="$out/wrong-fstype.fat" of="$out/$name.disk" bs=1M seek=1 conv=notrunc,sparse status=none
        rm "$out/wrong-fstype.fat"
    elif [[ $name == duplicate-partname ]]; then
        printf 'label: gpt\nunit: sectors\n\nstart=2048,size=65536,type=L,name="%s"\nstart=67584,size=65536,type=L,name="%s"\n' "$partlabel" "$partlabel" | sfdisk "$out/$name.disk"
    else
        dd if="$candidate/system.raw.img" of="$out/$name.disk" bs=1M seek=1 conv=notrunc,sparse status=none
    fi
done
cp "$candidate/Image" "$out/Image"
cp "$candidate/inputs/profile.json" "$out/profile.json"
printf '%s\n' 'Five generic VM GPT fixtures prepared; no Uke geometry or hardware emulated'
