#!/usr/bin/env bash
# Disposable ARM64 package fixture; no tablet or firmware operations.
set -Eeuo pipefail
[[ $# == 1 && -d $1 ]]
output=$1
rpmkeys --import /builder/configs/keys/uke-copr.asc
for revision in 3 4; do
    packages=("/builder/build/images/rpm-cache/uke-boot-integration-0.1.0-$revision.fc46.aarch64.rpm"
        "/builder/build/images/rpm-cache/uke-esp32-cdc-0.1.0-$revision.fc46.aarch64.rpm")
    for package in "${packages[@]}"; do
        rpmkeys --checksig "$package" | grep -F 'signatures OK'
        [[ $(rpm -qp --qf '%{ARCH}' "$package") == aarch64 ]]
        [[ -z $(rpm -qp --scripts "$package") ]]
    done
    dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=1 install "${packages[@]}"
    [[ $(rpm -q --qf '%{RELEASE}' uke-boot-integration) == "$revision.fc46" ]]
    rpm -V uke-boot-integration uke-esp32-cdc
done
fixture=$output/fixture
mkdir -p "$fixture/sys/firmware/efi" "$fixture/sys/firmware/devicetree/base" "$fixture/proc/sys/kernel"
printf 'xiaomi,uke\0qcom,sm7675\0' > "$fixture/sys/firmware/devicetree/base/compatible"
printf '7.2.9-senemos-uke\n' > "$fixture/proc/sys/kernel/osrelease"
printf 'root=LABEL=UKE_LINUX rw\n' > "$fixture/proc/cmdline"
/usr/bin/uke-boot-status --root "$fixture" > "$output/label-inspection.json"
printf 'root=LABEL=UKE_LINUX root=LABEL=foreign\n' > "$fixture/proc/cmdline"
if /usr/bin/uke-boot-status --root "$fixture" >/dev/null; then exit 1; else test "$?" -eq 2; fi
grep -Fx 'LABEL=UKE_LINUX / ext4 defaults 0 1' /usr/share/senemos/boot/uke/fstab.template
[[ ! -e /etc/systemd/system/multi-user.target.wants/uke-esp32-cdc-log.service ]]
[[ ! -e /etc/senemos/esp32-cdc.conf ]]
rpm -qa --qf '%{NAME}\n' | sort > "$output/installed-before-removal.txt"
dnf -y --disablerepo='*' --setopt=clean_requirements_on_remove=False remove uke-esp32-cdc uke-boot-integration
if rpm -q uke-boot-integration uke-esp32-cdc >/dev/null; then exit 1; fi
[[ ! -e /usr/bin/uke-boot-status && ! -e /usr/libexec/senemos-uke/uke-esp32-cdc ]]
echo 'Signed ARM64 boot RPM fresh install, release-3 to release-4 upgrade, label/override inspection and removal passed; no tablet boot'
