#!/usr/bin/env bash
# Native host stage: require native profiles and original Fedora context text.
set -Eeuo pipefail
[[ $# == 0 && -f /job/device-packages.complete && ! -e /job/rootfs-frozen ]]
root=/job/root original=/job/original-fedora proof=/job/audit/selinux-recompiled
release=$(jq -er .kernel_release /builder/configs/images/userdata-rawhide.json)
[[ $release =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
rpm --root "$root" -q --provides "senemos-uke-linux-kernel-mainline-core-$release.fc46.aarch64" |
    grep -Fx 'uke-kernel(platform-profile-qos-v1) = 1' >/dev/null
rpm --root "$root" -V power-profiles-daemon
for capability in factory-wlan-v1 factory-bluetooth-v1; do
    [[ $(rpm --root "$root" -q --whatprovides "uke-boot-integration($capability)" --qf '%{NAME}\n') == uke-boot-integration ]]
done
for package in uke-power-profile-backend uke-bluetooth uke-wifi-factory; do
    if rpm --root "$root" -q "$package" >/dev/null 2>&1; then
        printf 'Retired standalone package remains installed: %s\n' "$package" >&2; exit 1
    fi
done
for file in usr/libexec/uke-power-profiles-daemon \
    usr/lib/systemd/system/power-profiles-daemon.service.d/60-uke-cpufreq.conf \
    usr/share/selinux/packages/uke-power-profile.cil; do
    [[ ! -e $root/$file && ! -L $root/$file ]]
done
mkdir -p "$proof"
contexts=etc/selinux/targeted/contexts/files
for name in file_contexts file_contexts.homedirs; do
    cmp "$root/$contexts/$name" "$original/$contexts/$name"
    cmp "$root/$contexts/$name" "$root/var/lib/selinux/targeted/active/$name"
    cp "$root/$contexts/$name" "$proof/$name"
done
echo 'Selected kernel provides native profiles; boot integration owns factory bridges; original Fedora daemon and SELinux context text are retained.'
