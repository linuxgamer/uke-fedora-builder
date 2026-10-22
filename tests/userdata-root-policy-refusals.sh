#!/usr/bin/env bash
# Host-only fixtures execute the actual audit helper, without an image or RPM.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
sed -n '/^require_no_match() {$/,/^}$/p' "$repo/src/image/audit-userdata-root.sh" > "$work/helper.sh"
test -s "$work/helper.sh"
# shellcheck source=/dev/null
source "$work/helper.sh"
printf '%s\n' 'excludepkgs=kernel,kernel-core,kernel-modules*' > "$work/dnf.conf"
require_no_match -Fq 'senemos-uke-linux-kernel-mainline*' "$work/dnf.conf"
printf '%s\n' 'excludepkgs=senemos-uke-linux-kernel-mainline*' >> "$work/dnf.conf"
if require_no_match -Fq 'senemos-uke-linux-kernel-mainline*' "$work/dnf.conf"; then exit 1; fi
mkdir "$work/repos"
printf '%s\n' 'https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test/' > "$work/repos/test.repo"
require_no_match -rEq 'uke-linux-test:custom:|results/mcc45tr/uke-linux/' "$work/repos"
for invalid in 'uke-linux-test:custom:' 'results/mcc45tr/uke-linux/'; do
    printf '%s\n' "$invalid" > "$work/repos/invalid.repo"
    if require_no_match -rEq 'uke-linux-test:custom:|results/mcc45tr/uke-linux/' "$work/repos"; then exit 1; fi
done
if require_no_match -q anything "$work/missing" 2>/dev/null; then exit 1; fi
echo 'Actual image policy helper accepts safe inputs and rejects kernel holds, foreign COPR settings and unreadable inputs.'
