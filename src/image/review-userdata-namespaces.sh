#!/usr/bin/env bash
# Host-only: exact original Fedora, device-matched private RPMs and policy outputs.
set -Eeuo pipefail
[[ $# == 5 ]]
root=$(realpath "$1") original=$(realpath "$2") proof=$(realpath "$3") output=$4 private=$(realpath "$5")
[[ $root != "$original" && $root != "$private" && -d $root && -d $original && -d $proof && -d $private ]]
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
status=0
# The single-quoted Windows regular expression intentionally ends in backslashes.
# shellcheck disable=SC1003
rg -a -l --hidden --no-ignore --pcre2 \
    -e '(?<![A-Za-z0-9_./-])/home/[^/:\s\x00]+/' \
    -e '(?<![A-Za-z0-9_./-])/Users/[^/\s\x00]+/' \
    -e 'C:\\Users\\' "$root" > "$work/paths" || status=$?
[[ $status == 0 || $status == 1 ]]
while IFS= read -r path; do
    relative=${path#"$root/"}
    [[ $relative != "$path" && ! -L $path && -f $path ]]
    if [[ -n ${SENEMOS_PRIVATE_HOST_HOME:-} ]] && rg -a -q -F -- "${SENEMOS_PRIVATE_HOST_HOME}/" "$path"; then
        echo 'Actual private host path rejected' >&2; exit 1
    fi
    provenance='original-signed-fedora-rpm'
    if ! cmp -s "$path" "$original/$relative"; then
        case "$relative" in
            usr/lib/firmware/*|usr/share/uke-sensors/*)
                [[ ! -L $private/$relative && $(realpath "$private/$relative") == "$private/"* ]]
                cmp "$path" "$private/$relative"
                provenance='exact-verified-firmware-rpm'
                ;;
            etc/selinux/targeted/contexts/files/file_contexts.bin|etc/selinux/targeted/contexts/files/file_contexts.homedirs.bin|etc/selinux/targeted/contexts/files/file_contexts|etc/selinux/targeted/contexts/files/file_contexts.homedirs|var/lib/selinux/targeted/active/file_contexts|var/lib/selinux/targeted/active/file_contexts.homedirs)
                cmp "$path" "$proof/${relative##*/}"
                provenance='verified-original-fedora-policy-with-signed-uke-power-profile-context'
                ;;
            *) printf 'Unverified namespace file rejected: %s\n' "$relative" >&2; exit 1;;
        esac
    fi
    hash=$(sha256sum "$path" | cut -d ' ' -f1)
    jq -nc --arg path "$relative" --arg sha256 "$hash" --arg provenance "$provenance" \
        '{path:$path,sha256:$sha256,provenance:$provenance}' >> "$work/entries"
done < "$work/paths"
jq -s '{schema_version:1,policy:"Exact signed Fedora, device-matched private firmware and verified SELinux bytes; private host paths remain rejected",files:sort_by(.path)}' \
    "$work/entries" > "$output"
