#!/usr/bin/env bash
# Host-only export of verified regular files; never invokes fastboot or a device.
set -Eeuo pipefail
[[ $# == 1 ]]
job=$(realpath "$1")
repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/src/image/filesystem-policy.sh"
filesystem=$(userdata_profile_filesystem "$repo/configs/images/userdata-rawhide.json")
destination=$job/fastboot
manifest=$job/delivery/payload.json
raw=$job/image/userdata.$filesystem.img
boot=$job/delivery/boot-userdata.img
for flag in root-audit.complete "$filesystem-image.complete" "$filesystem-xattr-audit.complete"; do
    [[ -f $job/$flag ]]
done
[[ ! -e $destination && ! -L $destination ]]
for input in "$manifest" "$raw" "$boot"; do
    [[ -f $input && ! -L $input ]]
done
jq -e --arg filesystem "$filesystem" '.artifact_kind == "prepared-data-payload" and .device == "uke" and
    .root_partition == "userdata" and .root_filesystem == $filesystem and
    .boot.selector == "senemos.root=userdata"' "$manifest" >/dev/null
raw_bytes=$(jq -er '.root.raw_bytes' "$manifest")
raw_sha=$(jq -er '.root.raw_sha256' "$manifest")
boot_bytes=$(jq -er '.boot.bytes' "$manifest")
boot_sha=$(jq -er '.boot.sha256' "$manifest")
[[ $raw_bytes =~ ^[1-9][0-9]*$ && $boot_bytes =~ ^[1-9][0-9]*$ &&
    $raw_sha =~ ^[0-9a-f]{64}$ && $boot_sha =~ ^[0-9a-f]{64}$ ]]
[[ $(stat -c %s "$raw") == "$raw_bytes" && $(stat -c %s "$boot") == "$boot_bytes" ]]
[[ $(sha256sum "$raw" | cut -d ' ' -f1) == "$raw_sha" &&
    $(sha256sum "$boot" | cut -d ' ' -f1) == "$boot_sha" ]]
command -v simg2img >/dev/null
mkdir -m755 "$destination" "$destination/checks"
work=$(mktemp -d "${TMPDIR:-$job}/fastboot-verify.XXXXXX")
trap 'find "$work" -depth -delete' EXIT
g++ -std=c++17 -O2 -Wall -Wextra -Werror "$repo/src/boot-pair/android-sparse.cpp" -o "$work/android-sparse"
"$work/android-sparse" encode "$raw" "$destination/userdata.img" > "$destination/checks/sparse-encode.txt"
# Independent AOSP decoder: compare every expanded byte, including zero FILL.
simg2img "$destination/userdata.img" "$work/userdata.raw"
[[ $(stat -c %s "$work/userdata.raw") == "$raw_bytes" &&
    $(sha256sum "$work/userdata.raw" | cut -d ' ' -f1) == "$raw_sha" ]]
blkid -p -o export "$work/userdata.raw" | sed -n '/^\(TYPE\|LABEL\|BLOCK_SIZE\)=/p' |
    LC_ALL=C sort > "$destination/checks/filesystem.txt"
grep -qx "TYPE=$filesystem" "$destination/checks/filesystem.txt"
grep -qx LABEL=UKE_LINUX "$destination/checks/filesystem.txt"
cp --reflink=auto "$boot" "$destination/boot.img"
ln "$destination/userdata.img" "$destination/system.img"
[[ $(sha256sum "$destination/boot.img" | cut -d ' ' -f1) == "$boot_sha" ]]
[[ -f $job/rollback/boot_b-before-refresh.img && ! -L $job/rollback/boot_b-before-refresh.img ]]
(cd "$job/rollback"; sha256sum -c SHA256SUMS)
mkdir "$destination/rollback"
cp --reflink=auto "$job/rollback/boot_b-before-refresh.img" "$job/rollback/SHA256SUMS" "$destination/rollback/"
cp "$job/delivery/checks/boot-header.json" "$destination/checks/boot-header.json"
cp "$repo/docs/USERDATA-FASTBOOT.md" "$destination/README.md"
jq -n --slurpfile prepared "$manifest" \
    --arg created "$(date -u +%F)" --arg exporter "$(git -C "$repo" rev-parse HEAD)" \
    --arg codec "$(sha256sum "$repo/src/boot-pair/android-sparse.cpp" | cut -d ' ' -f1)" \
    --arg decoder "$(sha256sum "$(command -v simg2img)" | cut -d ' ' -f1)" \
    --arg sparse_sha "$(sha256sum "$destination/userdata.img" | cut -d ' ' -f1)" \
    --argjson sparse_bytes "$(stat -c %s "$destination/userdata.img")" \
    '{schema_version:1,created:$created,artifact_kind:"unqualified-fastboot-images",device:"uke",
      prepared_payload:$prepared[0],exporter_commit:$exporter,
      userdata:{file:"system.img",alias:"userdata.img",target_partition:"userdata",format:"android-sparse-v1",block_bytes:4096,
        bytes:$sparse_bytes,sha256:$sparse_sha,raw_bytes:$prepared[0].root.raw_bytes,
        raw_sha256:$prepared[0].root.raw_sha256,dont_care_chunks:0,
        automatic_filesystem_growth:($prepared[0].root_growth.enabled==true),root_growth:$prepared[0].root_growth},
      boot:($prepared[0].boot + {file:"boot.img"}),
      validation:{independent_decoder:"AOSP simg2img",decoder_binary_sha256:$decoder,
        codec_source_sha256:$codec,expanded_size_and_sha256_match:true,filesystem_identity_readback:true,
        boot_identical_to_prepared_payload:true,device_flash_tested:false,physical_boot_tested:false},
      operation_scope:"Manual userdata and boot_b flashing only; preserve boot_a; no device operation performed by export."}' \
    > "$destination/manifest.json"
(cd "$destination"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$work/SHA256SUMS")
mv "$work/SHA256SUMS" "$destination/SHA256SUMS"
(cd "$destination"; sha256sum -c SHA256SUMS)
echo 'Fastboot-format files exported and independently decoded; firmware provisioning and tablet acceptance remain open.'
