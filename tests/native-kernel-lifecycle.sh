#!/usr/bin/env bash
# Historical Rawhide signed-COPR fixture: recorded fc46 kernel1.3 ->1.4.
# Fedora44 lifecycle evidence is produced by uke-mainline-linux/build.sh.
# Host-only, disposable AArch64 userspace. The recorded console base has 1.3.
# Check an actual signed 1.4 upgrade, removal, fresh install and second removal.
set -Eeuo pipefail
[[ $# == 2 && -d $1 && -d $2 ]]
builder=$1 out=$2
names=(senemos-uke-linux-kernel-mainline{,-core,-modules,-dtbs})
packages=("$builder"/build/images/rpm-cache/senemos-uke-linux-kernel-mainline*-7.2.9-1.4.fc46.aarch64.rpm)
[[ ${#packages[@]} == 4 ]]
rpmkeys --import "$builder/configs/keys/uke-copr.asc"
for package in "${packages[@]}"; do
    rpmkeys --checksig "$package" | grep -F 'signatures OK'
done
for name in "${names[@]}"; do
    [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$name") == 7.2.9-1.3.fc46.aarch64 ]]
done
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=1 install "${packages[@]}"
check_installed() {
    for name in "${names[@]}"; do
        [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$name") == 7.2.9-1.4.fc46.aarch64 ]]
    done
    echo 'ea84ecff30bd0ab799ba6a5f02faee1bf3b28099fbffd75f234adf4a2a85c97e  /usr/lib/modules/7.2.9-senemos-uke/vmlinuz' | sha256sum -c -
    [[ -s /usr/lib/modules/7.2.9-senemos-uke/kernel/drivers/usb/class/cdc-acm.ko.zst ]]
}
check_absent() {
    for name in "${names[@]}"; do
        if rpm -q "$name"; then echo "Package remained after removal: $name" >&2; exit 1; fi
    done
    [[ ! -e /usr/lib/modules/7.2.9-senemos-uke/vmlinuz ]]
}
check_installed
dnf -y remove "${names[@]}"
check_absent
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=1 install "${packages[@]}"
check_installed
rpm -q "${names[@]}" > "$out/fresh-installed-nevra.txt"
dnf -y remove "${names[@]}"
check_absent
echo 'Signed native COPR 11081958: upgrade, removal, fresh 1.4 install and final removal passed'
