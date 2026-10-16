#!/usr/bin/env bash
# Host-container implementation, called by the workspace build.sh entry.
set -Eeuo pipefail
[[ $# == 5 ]] || exit 2
work=$1 profile=$2 esp_mib=$3 root_mib=$4 sector=$5
[[ $work == /builder/build/images/* && -d $work && ! -L $work ]]
[[ $esp_mib =~ ^[1-9][0-9]*$ && $root_mib =~ ^[1-9][0-9]*$ ]]
[[ $sector == 512 || $sector == 4096 ]]
((esp_mib >= 128 && esp_mib <= 65536 && root_mib >= 4096 && root_mib <= 1048576))
[[ $(jq -er .esp_size_mib "$profile") == "$esp_mib" && $(jq -er .root_size_mib "$profile") == "$root_mib" && $(jq -er .fat_sector_bytes "$profile") == "$sector" ]]
root=$work/composition-root
out=$work/candidate
mkdir "$root" "$out"
tar --numeric-owner --same-owner --xattrs --xattrs-include='security.capability' -xf "$work/prepared-root.tar" -C "$root"
release=$(jq -er '.kernel_release' "$profile")
kernel=$root/usr/lib/modules/$release/vmlinuz
dtb=$root/usr/lib/modules/$release/dtb/qcom/sm7675-xiaomi-uke.dtb
initrd=$root/boot/initramfs-$release.img
[[ $(sha256sum "$kernel" | cut -d ' ' -f1) == "$(jq -er .kernel_image_sha256 "$profile")" ]]
[[ $(sha256sum "$root/usr/lib/modules/$release/config" | cut -d ' ' -f1) == "$(jq -er .kernel_config_sha256 "$profile")" ]]
[[ -s $dtb && -s $initrd && $(stat -c %u "$root") == 0 ]]
for option in EFI EFI_STUB BLK_DEV_INITRD EXT4_FS SECURITY_SELINUX; do
    grep -Fx "CONFIG_$option=y" "$root/usr/lib/modules/$release/config" >/dev/null
done
readelf -h "$root/usr/lib/systemd/systemd" | grep AArch64 >/dev/null
bash /builder/src/audit/check-target-elf.sh "$root"
bash /builder/src/audit/check-target-privacy.sh --namespace-policy /builder/configs/images/selinux-namespace-policy.json "$root"
[[ ! -s $root/etc/machine-id && ! -e $root/etc/ssh/ssh_host_ed25519_key ]]
[[ ! -e $root/var/lib/systemd/random-seed ]]
[[ ! -e $root/.dockerenv && ! -e $root/.containerenv && ! -e $root/run/.containerenv ]]
[[ $(readlink "$root/etc/systemd/system/getty@tty2.service") == /dev/null ]]
[[ -L $root/etc/systemd/system/multi-user.target.wants/uke-esp32-cdc-log.service ]]
[[ -L $root/etc/systemd/system/sysinit.target.wants/debug-shell.service ]]
grep -F 'StandardOutput=journal' "$root/etc/systemd/system/debug-shell.service.d/90-uke-core.conf"
[[ $(readlink "$root/etc/systemd/system/default.target") == /usr/lib/systemd/system/multi-user.target ]]
partlabel=$(jq -er .linux_partition_label "$profile")
[[ $partlabel == userdata || $partlabel == linux ]]
root_options=defaults
[[ $partlabel != userdata ]] || root_options=defaults,x-systemd.growfs
grep -Fx "PARTLABEL=$partlabel / ext4 $root_options 0 1" "$root/etc/fstab"
grep -Fx 'LABEL=UKE_ESP /boot/efi vfat umask=0077,nofail 0 2' "$root/etc/fstab"
mkdir "$work/initramfs-root"
gzip -cd "$initrd" | (cd "$work/initramfs-root"; cpio -id --quiet --no-absolute-filenames)
bash /builder/src/audit/check-target-elf.sh "$work/initramfs-root"
bash /builder/src/audit/check-target-privacy.sh "$work/initramfs-root"
[[ ! -s $work/initramfs-root/etc/machine-id && ! -s $work/initramfs-root/var/lib/systemd/random-seed ]]
[[ -e $work/initramfs-root/init || -L $work/initramfs-root/init ]]
grep -F "root=PARTLABEL=$partlabel " "$work/initramfs-root"/etc/cmdline.d/*.conf
for service in uke-initrd-shell uke-initrd-cdc; do
    [[ -f $work/initramfs-root/usr/lib/systemd/system/$service.service ]]
    grep -Fx 'ConditionKernelCommandLine=rd.senemos.tty=1' "$work/initramfs-root/usr/lib/systemd/system/$service.service"
    [[ -L $work/initramfs-root/usr/lib/systemd/system/initrd.target.wants/$service.service ]]
done
[[ -x $work/initramfs-root/usr/libexec/senemos-uke/uke-esp32-cdc ]]
# GNU cross objcopy supports PE ARM64 section placement; LLVM cannot do it.
if command -v aarch64-linux-gnu-objcopy >/dev/null; then prefix=aarch64-linux-gnu-; else prefix=''; fi
stub=$root/usr/lib/systemd/boot/efi/linuxaa64.efi.stub
[[ -s $stub ]]
cp "$root/usr/lib/os-release" "$work/os-release" # Target release identity, never host identity.
printf '%s\0' "$(jq -er .kernel_command_line "$profile")" > "$work/cmdline"
printf '%s\0' "$release" > "$work/uname"
# Place new sections after all stub virtual ranges, at the PE alignment.
max=0
while read -r size address; do
    end=$((16#$size + 16#$address))
    ((end <= max)) || max=$end
done < <("${prefix}objdump" -h "$stub" | awk '$1 ~ /^[0-9]+$/ {print $3,$4}')
alignment=$("${prefix}objdump" -p "$stub" | awk '$1=="SectionAlignment" {print $2}')
[[ $alignment =~ ^[0-9a-fA-F]+$ ]]
align=$((16#$alignment))
((align >= 512 && (align & (align - 1)) == 0))
offset=$(((max + align - 1) / align * align))
args=()
for section in linux osrel cmdline initrd dtb uname; do
    case $section in
        linux) file=$kernel;; osrel) file=$work/os-release;; cmdline) file=$work/cmdline;;
        initrd) file=$initrd;; dtb) file=$dtb;; uname) file=$work/uname;;
    esac
    args+=(--add-section ".$section=$file" --change-section-vma ".$section=$offset" \
        --set-section-flags ".$section=contents,alloc,load,readonly,data")
    size=$(stat -c %s "$file")
    offset=$(((offset + size + align - 1) / align * align))
done
uki=$out/senemos-uke-$release.efi
"${prefix}objcopy" "${args[@]}" "$stub" "$uki"
"${prefix}objdump" -f "$uki" | grep pei-aarch64-little >/dev/null
"${prefix}objdump" -p "$uki" | grep -E 'Subsystem[[:space:]]+0000000a' >/dev/null
# Independently extract resources and compare exact byte lengths and hashes.
for section in linux osrel cmdline initrd dtb uname; do
    case $section in
        linux) file=$kernel;; osrel) file=$work/os-release;; cmdline) file=$work/cmdline;;
        initrd) file=$initrd;; dtb) file=$dtb;; uname) file=$work/uname;;
    esac
    "${prefix}objcopy" --dump-section ".$section=$work/embedded-$section" "$uki"
    # PE raw sections are padded; virtual size must describe the actual input.
    virtual=$("${prefix}objdump" -h "$uki" | awk -v name=".$section" '$2==name {print $3}')
    [[ $((16#$virtual)) == "$(stat -c %s "$file")" ]]
    cmp -n "$(stat -c %s "$file")" "$file" "$work/embedded-$section"
done
cp "$root/etc/fstab" "$out/fstab"
cp "$root/usr/lib/modules/$release/config" "$out/kernel.config"
cp "$dtb" "$out/sm7675-xiaomi-uke.dtb"
cp "$work/installed-rpms.tsv" "$out/installed-rpms.tsv"
if bash /builder/src/image/audit-kernel-inputs.sh "$root" "$out/kernel-prerequisites.json"; then :;
else result=$?; ((result == 2)) || exit "$result"; fi
# Source admission is distinct from filesystem admission. A candidate is allowed
# to document the known missing USB/UFS/RAM chain; no device release is inferred.
jq --argjson acm "$(grep -Eq '^CONFIG_USB_ACM=[ym]$' "$root/usr/lib/modules/$release/config" && echo true || echo false)" \
    --argjson hid "$(grep -Eq '^CONFIG_USB_HID=[ym]$' "$root/usr/lib/modules/$release/config" && echo true || echo false)" \
    '. + {usb_host_cdc_driver_configuration:$acm,usb_host_hid_driver_configuration:$hid}' \
    "$out/kernel-prerequisites.json" > "$work/kernel-prerequisites.json"
mv "$work/kernel-prerequisites.json" "$out/kernel-prerequisites.json"
# ext4 is built without a loop mount; original ownership and xattrs are copied.
truncate -s "$((root_mib * 1024 * 1024))" "$out/uke-linux.img"
root_uid=$(stat -c %u "$root") root_gid=$(stat -c %g "$root") root_mode=$(stat -c %a "$root")
[[ $root_uid == 0 && $root_gid =~ ^[0-9]+$ && $root_mode =~ ^[0-7]{3,4}$ ]]
mkfs.ext4 -q -F -L UKE_LINUX -m 0 \
    -E "lazy_itable_init=0,lazy_journal_init=0,root_owner=$root_uid:$root_gid,root_perms=$root_mode" \
    -d "$root" "$out/uke-linux.img"
g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/src/image/ext4-labels.cpp \
    -o "$work/ext4-labels" -lext2fs -lcom_err -lselinux
contexts=$root/etc/selinux/targeted/contexts/files/file_contexts
"$work/ext4-labels" apply "$out/uke-linux.img" "$root" "$contexts"
"$work/ext4-labels" verify "$out/uke-linux.img" "$root" "$contexts"
e2fsck -fn "$out/uke-linux.img"
# Read complete filesystem bytes back and repeat payload/identity gates.
mkdir "$work/ext4-readback"
debugfs -R "rdump / $work/ext4-readback" "$out/uke-linux.img"
bash /builder/src/audit/check-target-elf.sh "$work/ext4-readback"
bash /builder/src/audit/check-target-privacy.sh --namespace-policy /builder/configs/images/selinux-namespace-policy.json "$work/ext4-readback"
cmp "$root/etc/fstab" "$work/ext4-readback/etc/fstab"
cmp "$kernel" "$work/ext4-readback/usr/lib/modules/$release/vmlinuz"
cmp "$dtb" "$work/ext4-readback/usr/lib/modules/$release/dtb/qcom/sm7675-xiaomi-uke.dtb"
cmp "$initrd" "$work/ext4-readback/boot/initramfs-$release.img"
[[ $(blkid -p -s LABEL -o value "$out/uke-linux.img") == UKE_LINUX ]]
truncate -s "$((esp_mib * 1024 * 1024))" "$out/uke-esp.img"
mkfs.fat -F 32 -S "$sector" -n UKE_ESP "$out/uke-esp.img"
mmd -i "$out/uke-esp.img" ::/EFI ::/EFI/Linux ::/EFI/UKE
mcopy -i "$out/uke-esp.img" "$uki" "::/EFI/Linux/${uki##*/}"
# No default loader, Android binary, guessed rEFInd entry or firmware port.
jq --arg release "$release" --argjson root_mib "$root_mib" --argjson esp_mib "$esp_mib" \
    --argjson sector "$sector" '. + {kernel_release:$release,root_size_mib:$root_mib,esp_size_mib:$esp_mib,fat_sector_bytes:$sector}' \
    "$profile" > "$out/partition-contract.json"
mcopy -i "$out/uke-esp.img" "$out/partition-contract.json" ::/EFI/UKE/partition-contract.json
mcopy -i "$out/uke-esp.img" "::/EFI/Linux/${uki##*/}" "$work/esp-uki-readback.efi"
cmp "$uki" "$work/esp-uki-readback.efi"
fsck.fat -n "$out/uke-esp.img"
[[ $(blkid -p -s LABEL -o value "$out/uke-esp.img") == UKE_ESP ]]
for file in uke-linux.img uke-esp.img; do
    zstd -T2 -3 -q "$out/$file" -o "$out/$file.zst"
    zstd -t -q "$out/$file.zst"
    [[ $(zstd -dc "$out/$file.zst" | sha256sum | cut -d ' ' -f1) == "$(sha256sum "$out/$file" | cut -d ' ' -f1)" ]]
done
cd "$out"
sha256sum ./* > SHA256SUMS
printf 'Filesystem, privacy, all-inode labels, UKI and ESP readback gates passed; boot/HIL untested\n'
