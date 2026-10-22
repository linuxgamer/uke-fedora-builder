#!/usr/bin/env bash
# Host-only proof for unchanged Fedora desktop helpers and namespace examples.
set -Eeuo pipefail
append=0
if [[ $# == 1 && $1 == --append ]]; then append=1; else [[ $# == 0 ]]; fi
if ((append)); then
    [[ -d /job/original-fedora && -s /job/audit/original-fedora-rpms.tsv ]]
else
    [[ ! -e /job/original-fedora ]]
fi
mkdir -p /job/audit/fedora-keydb /job/original-fedora
rpmkeys --dbpath /job/audit/fedora-keydb --import /job/inputs/fedora-46.asc
shopt -s nullglob
archives=(/job/cache/rawhide-*/packages/*.rpm)
(( ${#archives[@]} >= 900 ))
: > /job/audit/fedora-signatures.log
if (( ! append )); then : > /job/audit/original-fedora-rpms.tsv; fi
rpmkeys --dbpath /job/audit/fedora-keydb --checksig "${archives[@]}" > /job/audit/fedora-signatures.log
[[ $(grep -c 'signatures OK' /job/audit/fedora-signatures.log) == "${#archives[@]}" ]]
for archive in "${archives[@]}"; do
    hash=$(sha256sum "$archive" | cut -d ' ' -f1)
    if ((append)); then
        known=$(awk -F '\t' -v name="${archive##*/}" '$1==name {print $3}' /job/audit/original-fedora-rpms.tsv)
        if [[ -n $known ]]; then [[ $known == "$hash" ]]; continue; fi
    fi
    arch=$(rpm --dbpath /job/audit/fedora-keydb -qp --qf '%{ARCH}' "$archive")
    [[ $arch == aarch64 || $arch == noarch ]]
    vendor=$(rpm --dbpath /job/audit/fedora-keydb -qp --qf '%{VENDOR}' "$archive")
    [[ $vendor == 'Fedora Project' ]]
    # A complete spool avoids an early cpio TRAILER exit turning rpm2cpio's
    # remaining padding into SIGPIPE, without suppressing either tool's errors.
    rpm2cpio "$archive" > /job/audit/current-payload.cpio
    (cd /job/original-fedora; cpio -idmu --quiet --no-absolute-filenames < /job/audit/current-payload.cpio)
    printf '%s\t%s\t%s\n' "${archive##*/}" "$(rpm --dbpath /job/audit/fedora-keydb -qp --qf '%{NEVRA}' "$archive")" \
        "$hash" >> /job/audit/original-fedora-rpms.tsv
done
if [[ -e /job/audit/current-payload.cpio ]]; then unlink /job/audit/current-payload.cpio; fi
echo "Original Fedora signatures, architectures and payload extraction verified: ${#archives[@]} RPMs"
