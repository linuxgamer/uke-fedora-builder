#!/usr/bin/env bash
# Disposable AArch64 host userspace. Never invoked on the tablet.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
inputs=$1 output=$2
rpmkeys --import "$inputs/fedora-key.asc" "$inputs/copr-key.asc"
for archive in "$inputs"/runtime/packages/*.rpm; do
    rpmkeys --checksig "$archive" | grep -F 'signatures OK' >/dev/null
    arch=$(rpm -qp --qf '%{ARCH}' "$archive")
    [[ $arch == aarch64 || $arch == noarch ]]
done
# Only the reviewed Fedora-to-COPR GNU C++ runtime transition is allowed.
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=1 --allow-vendor-change replay "$inputs/runtime"
rpm -V uke-core-meta uke-desktop-metas libstdc++
if rpm -qa --qf '%{NAME}\n' | grep -Ei '^plasma-workspace$|^dolphin$'; then exit 1; fi
exec bash /builder/src/image/prepare-root.sh "$inputs" "$output" 7.2.9-senemos-uke "$inputs/boot/packages"
