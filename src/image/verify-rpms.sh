#!/usr/bin/env bash
# Sourced only in disposable build containers, before offline DNF transactions.
verify_stage_rpms() {
    local inputs=$1 stage=$2 archive file signature arch
    (cd "$inputs/$stage/packages" || exit 1; sha256sum -c ../SHA256SUMS)
    for archive in "$inputs/$stage/packages/"*.rpm; do
        [[ -f $archive ]] || continue
        file=${archive##*/}
        grep -Fx "$(sha256sum "$archive" | cut -d ' ' -f1)  $file" "$inputs/$stage/SHA256SUMS" >/dev/null
        signature=$(rpmkeys --checksig "$archive")
        if grep -Fx "$file" "$inputs/$stage/official-rpms.txt" >/dev/null; then
            grep -F 'signatures OK' <<< "$signature" >/dev/null
        fi
        arch=$(rpm -qp --qf '%{ARCH}' "$archive")
        [[ $arch == aarch64 || $arch == noarch ]]
    done
}
