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
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=1 replay "$inputs/runtime"
rpm -V uke-core-meta uke-desktop-metas libstdc++
[[ $(rpm -q --qf '%{SOURCERPM}' libstdc++) == gcc-*.src.rpm ]]
bash /builder/src/audit/check-console-session.sh /
exec bash /builder/src/image/prepare-root.sh "$inputs" "$output" 7.2.9-senemos-uke "$inputs/boot/packages"
