#!/usr/bin/env bash
# Host-only fixture. Assemble/verify-arm64 use the pinned ARM64 console image;
# verify-host uses the native image-host toolchain. /builder is read-only.
set -Eeuo pipefail
[[ $# == 2 && -d $1 ]]
output=$1
phase=$2
[[ $phase == assemble || $phase == verify-arm64 || $phase == verify-host ]]
release=7.2.9-senemos-uke
if [[ $phase == assemble ]]; then
packages=(/builder/build/images/rpm-cache/uke-boot-integration-0.1.0-13.fc44.aarch64.rpm
    /builder/build/images/rpm-cache/uke-esp32-cdc-0.1.0-13.fc44.aarch64.rpm)
# These local development RPMs have no COPR signature; admit their exact
# configured SHA256 plus the RPM payload digest before installing offline.
for package in "${packages[@]}"; do
    expected=$(jq -er --arg file "${package##*/}" '.[]|select(.file==$file)|.sha256' \
        /builder/configs/boot/uke-boot-pair-support-rpms.json)
    printf '%s  %s\n' "$expected" "$package" | sha256sum -c -
    rpmkeys --checksig --nosignature "$package" | grep -F 'digests OK'
done
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=0 install "${packages[@]}"
mkdir -p /usr/lib/dracut/modules.d/91uke-bringup
install -m644 /builder/src/image/dracut/91uke-bringup/* /usr/lib/dracut/modules.d/91uke-bringup/
chmod 755 /usr/lib/dracut/modules.d/91uke-bringup/module-setup.sh
dracut --force --no-hostonly --no-hostonly-cmdline --no-early-microcode \
    --gzip --add "uke-bringup" --filesystems ext4 \
    --omit 'network plymouth crypt systemd-cryptsetup syslog lvm mdraid btrfs i18n' \
    "$output/initramfs.img" "$release"
mkdir "$output/root"
gzip -cd "$output/initramfs.img" | (cd "$output/root"; cpio -id --quiet --no-absolute-filenames)
rpm -q dracut systemd kmod uke-boot-integration uke-esp32-cdc > "$output/tools.txt"
sha256sum "$output/initramfs.img" > "$output/SHA256SUMS"
echo 'Actual AArch64 initramfs assembled; independent host and ARM64 checks must follow'
exit 0
fi
if [[ $phase == verify-host ]]; then
bash /builder/src/audit/check-target-elf.sh "$output/root"
bash /builder/src/audit/check-target-privacy.sh "$output/root"
[[ ! -s $output/root/etc/machine-id && ! -s $output/root/var/lib/systemd/random-seed ]]
for service in uke-initrd-shell uke-initrd-cdc; do
    unit=$output/root/usr/lib/systemd/system/$service.service
    [[ -f $unit && -L $output/root/usr/lib/systemd/system/initrd.target.wants/$service.service ]]
    grep -Fx 'ConditionKernelCommandLine=rd.senemos.tty=1' "$unit"
    grep -Fx 'ConditionKernelCommandLine=senemos.debug=esp32-cdc' "$unit"
done
[[ -s $output/root/usr/lib/modules/$release/kernel/drivers/usb/class/cdc-acm.ko.zst ]]
[[ -s $output/root/usr/lib/modules/$release/kernel/drivers/usb/dwc3/dwc3-qcom.ko.zst ]]
echo 'Independent initramfs service/module/payload checks passed; physical boot untested'
exit 0
fi
for binary in /bin/sh /usr/bin/uke-boot-status /usr/libexec/senemos-uke/uke-esp32-cdc /usr/bin/journalctl; do
    # No audit/ldd utility is added to the target initramfs. Use its own loader.
    chroot "$output/root" /lib/ld-linux-aarch64.so.1 --list "$binary" > "$output/$(basename "$binary").libraries"
done
chroot "$output/root" /usr/bin/uke-boot-status --help >/dev/null
chroot "$output/root" /usr/libexec/senemos-uke/uke-esp32-cdc --help >/dev/null
chroot "$output/root" /usr/bin/journalctl --version >/dev/null
systemd-analyze --root="$output/root" verify \
    "$output/root/usr/lib/systemd/system/uke-initrd-shell.service" \
    "$output/root/usr/lib/systemd/system/uke-initrd-cdc.service"
echo 'Actual ARM64 initramfs native helper/library smoke checks passed; no kernel boot or USB device test'
