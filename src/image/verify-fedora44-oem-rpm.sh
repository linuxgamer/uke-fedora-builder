#!/usr/bin/env bash
# Refuse a cached OEM RPM whose file digests differ from the pinned 3.304 set.
set -Eeuo pipefail
[[ $# == 1 && -s $1 ]] || { echo 'Usage: verify-fedora44-oem-rpm.sh RPM' >&2; exit 2; }
rpm_file=$(realpath -- "$1")
manifest=$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../uke-linux-hardware-support/xiaomi-uke-firmware/manifests/local-firmware-candidates.json")
file_list=$(mktemp)
trap 'rm -f -- "$file_list"' EXIT
rpm -qp --qf '[%{FILENAMES}\t%{FILEDIGESTS}\n]' "$rpm_file" > "$file_list"
count=0
while IFS=$'\t' read -r path expected; do
    actual=$(awk -F '\t' -v name="/usr/lib/firmware/$path" '$1 == name { print $2 }' "$file_list")
    [[ $actual == "$expected" ]] || {
        printf 'OEM RPM firmware mismatch: %s (expected %s, got %s)\n' "$path" "$expected" "${actual:-missing}" >&2
        exit 1
    }
    ((count+=1))
done < <(jq -r '.files[] | [.target_path, .sha256] | @tsv' "$manifest")
[[ $count == 74 ]] || { printf 'Expected 74 pinned firmware files; got %s\n' "$count" >&2; exit 1; }
printf 'OEM RPM: %s pinned firmware files verified\n' "$count"
