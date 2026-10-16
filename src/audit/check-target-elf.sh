#!/usr/bin/env bash
# Host-side ELF readability check of an extracted target payload.
set -euo pipefail
[[ $# == 1 && -d $1 ]] || { echo 'Usage: check-target-elf.sh EXTRACTED_TARGET_DIRECTORY' >&2; exit 2; }
for tool in realpath find od tr readelf; do
  command -v "$tool" >/dev/null || { printf 'Missing host audit tool: %s\n' "$tool" >&2; exit 2; }
done
root=$(realpath -- "$1")
failed=0
while IFS= read -r -d '' path; do
  if [[ $(od -An -tx1 -N4 -- "$path" | tr -d ' \n') == 7f454c46 ]]; then
    if ! readelf -h -- "$path" >/dev/null 2>&1 ||
       ! readelf -d -- "$path" >/dev/null 2>&1; then
      printf 'Unreadable target ELF rejected: %s\n' "${path#"$root/"}" >&2
      failed=1
    fi
  fi
done < <(find "$root" -mindepth 1 -type f -print0)
((failed==0)) || exit 1
echo 'Extracted target ELF headers readable'
