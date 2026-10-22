#!/usr/bin/env bash
# Host-only readback of installed signed RPM bytes; no target program is run.
set -Eeuo pipefail
[[ $# == 3 && -d $1 && -x $2 && ! -e $3 ]]
root=$(realpath "$1") codec=$(realpath "$2") output=$3
# shellcheck source=src/image/filesystem-policy.sh
source "$(dirname "$0")/filesystem-policy.sh"
filesystem=$(userdata_profile_filesystem "$root/usr/share/uke/image-profile.json")
release=$(jq -er .kernel_release "$root/usr/share/uke/image-profile.json")
modules=$root/usr/lib/modules/$release
bundle=$root/usr/lib/senemos/kernel-updates/$release
[[ -f $modules/vmlinuz && -f $modules/System.map && -f $bundle/userdata.img ]]
mkdir -p "$output"
"$codec" inspect "$bundle/linux.img" > "$output/linux-header.json"
"$codec" inspect "$bundle/userdata.img" > "$output/userdata-header.json"
"$codec" extract "$bundle/linux.img" "$output/linux.Image"
"$codec" extract "$bundle/userdata.img" "$output/userdata.Image"
cmp "$output/linux.Image" "$modules/vmlinuz"
cmp "$output/userdata.Image" "$modules/vmlinuz"
(cd "$modules"; sha256sum -c "$bundle/modules.sha256") > "$output/modules-readback.log"
symbol() {
    local value
    value=$(awk -v wanted="$1" '$3==wanted {print $1}' "$modules/System.map")
    [[ $value =~ ^[0-9a-f]{16}$ ]]
    printf '%s' "$value"
}
text=$(symbol _text) start=$(symbol __initramfs_start) size=$(symbol __initramfs_size)
offset=$((16#$start-16#$text)) size_offset=$((16#$size-16#$text))
length=$(od -An -tu8 -j "$size_offset" -N8 "$modules/vmlinuz" | tr -d ' ')
[[ $offset -gt 0 && $length -gt 1048576 && $length -lt 67108864 ]]
dd if="$modules/vmlinuz" of="$output/initramfs.cpio.gz" bs=1M iflag=skip_bytes,count_bytes \
    skip="$offset" count="$length" status=none
gzip -t "$output/initramfs.cpio.gz"
gzip -dc "$output/initramfs.cpio.gz" > "$output/initramfs.cpio"
mkdir "$output/initramfs"
(cd "$output/initramfs"; cpio -idm --quiet --no-absolute-filenames < ../initramfs.cpio)
here=$(cd "$(dirname "$0")/.." && pwd)
bash "$here/audit/check-target-payload.sh" "$output/initramfs"
bash "$here/audit/check-target-privacy.sh" "$output/initramfs"
[[ ! -e $output/initramfs/usr/libexec/senemos-local-shell ]]
find "$output/initramfs" -type l -path '*wants*' -printf '%P\n' > "$output/startup-links.txt"
if grep -Ei 'uke-cdc|g_serial|usb-network' "$output/startup-links.txt"; then exit 1; fi
grep -Fq 'f2fs' "$output/initramfs/usr/libexec/uke-root-guard"
grep -Fxq CONFIG_F2FS_FS=y "$modules/config"
grep -Fxq CONFIG_F2FS_FS_SECURITY=y "$modules/config"
grep -Fxq "CONFIG_${filesystem^^}_FS=y" "$modules/config"
if [[ $filesystem == f2fs ]]; then
    unit=$output/initramfs/usr/lib/systemd/system/uke-userdata-grow.service
    grep -Fxq 'ExecStart=/usr/libexec/uke-userdata-grow /dev/disk/by-partlabel/userdata' "$unit"
    grep -Fxq RemainAfterExit=yes "$unit"
    if grep -q '^ExecCondition=' "$unit"; then exit 1; fi
    [[ $(readlink "$output/initramfs/usr/lib/systemd/system/sysroot.mount.requires/uke-userdata-grow.service") == ../uke-userdata-grow.service ]]
    for program in usr/libexec/uke-userdata-grow usr/sbin/fsck.f2fs usr/sbin/resize.f2fs; do
        [[ -x $output/initramfs/$program ]]
        readelf -h "$output/initramfs/$program" | grep -Eq 'Machine:.*AArch64'
    done
    phase=before-root-mount
    repeat=readonly-capacity-check-after-completion
else
    for retained in "$root/usr/lib/modules/"*; do
        candidate=$root/usr/lib/senemos/kernel-updates/${retained##*/}/manifest
        grep -Fxq root_selector_capability=uke-elfnote-v2 "$candidate"
        grep -Fxq "CONFIG_${filesystem^^}_FS=y" "$retained/config"
    done
    [[ -x $root/usr/libexec/senemos-uke/uke-install-profile ]]
    [[ -f $root/usr/lib/systemd/system/uke-root-grow.service ]]
    grep -Fxq 'ConditionPathExists=!/var/lib/senemos/installation/online-grow-complete' \
        "$root/usr/lib/systemd/system/uke-root-grow.service"
    grep -Fxq 'ExecStart=/usr/libexec/senemos-uke/uke-install-profile grow' \
        "$root/usr/lib/systemd/system/uke-root-grow.service"
    [[ ! -e $root/var/lib/senemos/installation/online-grow-complete ]]
    [[ $(systemctl --root="$root" is-enabled uke-root-grow.service) == enabled ]]
    phase=mounted-root-before-login
    repeat=completion-file-skips-service
fi
for flag in DEBUG_INFO KASAN UBSAN; do
    if grep -Eq "^CONFIG_$flag=[ym]$" "$modules/config"; then exit 1; fi
done
grep -Fxq CONFIG_DEBUG_INFO_NONE=y "$modules/config"
jq -n --arg filesystem "$filesystem" --arg release "$release" \
    --arg image "$(sha256sum "$modules/vmlinuz" | cut -d ' ' -f1)" --arg phase "$phase" --arg repeat "$repeat" \
    '{schema_version:1,filesystem:$filesystem,kernel_release:$release,kernel_image_sha256:$image,
      enabled:true,phase:$phase,repeat_policy:$repeat,physical_image_boot_tested:false}' > "$output/growth-policy.json"
echo 'Installed Image, both boot containers, every module and extracted early userspace passed host readback.'
