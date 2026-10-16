#!/usr/bin/env bash
# Disposable AArch64 host userspace. Never invoked on the tablet.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
inputs=$1 output=$2
rpmkeys --import "$inputs/fedora-key.asc"
# shellcheck source=verify-rpms.sh
# shellcheck disable=SC1091
source /builder/src/image/verify-rpms.sh
verify_stage_rpms "$inputs" runtime
# Fedora signatures and all hashes were checked above. Local development RPMs
# are unsigned, so replay cannot require signatures for every package.
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=0 replay "$inputs/runtime"
rpm -V uke-core-meta uke-desktop-metas libstdc++
[[ $(rpm -q --qf '%{SOURCERPM}' libstdc++) == gcc-*.src.rpm ]]
bash /builder/src/audit/check-console-session.sh /
exec bash /builder/src/image/prepare-root.sh "$inputs" "$output" 7.2.9-senemos-uke "$inputs/boot/packages"
