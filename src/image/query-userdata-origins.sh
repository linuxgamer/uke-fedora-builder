#!/usr/bin/env bash
# Native host stage: query recorded origins without applying target update holds.
set -Eeuo pipefail
[[ $# == 0 && -f /job/device-packages.complete && ! -e /job/rootfs-frozen ]]
dnf5 --installroot=/job/root --releasever=rawhide --disable-repo='*' \
    --setopt=excludepkgs= repoquery --installed \
    --queryformat=$'%{full_nevra}\t%{from_repo}\n' > /job/audit/installed-origins.tsv
awk -F '\t' 'NF!=2 || $2!~/^(rawhide|uke-linux|uke-linux-test|@commandline)$/ {bad=1} END {exit bad}' \
    /job/audit/installed-origins.tsv
expected=$(rpm --root /job/root -qa --qf '%{NAME}\n' | grep -vc '^gpg-pubkey$')
[[ $(wc -l < /job/audit/installed-origins.tsv) == "$expected" ]]
echo 'Recorded origins cover all installed payload packages; RPM public-key entries are counted separately.'
