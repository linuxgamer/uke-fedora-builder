#!/usr/bin/env bash
# Regular-file fixtures only; no firmware or device operation.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work"/{root/usr/lib/firmware,private/usr/lib/firmware,fedora,policy}
target=$work/root/usr/lib/firmware/adsp.b09
expected=$work/private/usr/lib/firmware/adsp.b09
printf 'OEM path /home/oem-build/work/\n' > "$target"
cp "$target" "$expected"
review() {
    bash "$repo/src/image/review-userdata-namespaces.sh" "$work/root" "$work/fedora" \
        "$work/policy" "$work/result.json" "$work/private"
}
review
jq -e '.files|length==1 and .[0].provenance=="exact-verified-firmware-rpm"' "$work/result.json" >/dev/null
printf 'changed\n' >> "$target"
if review >/dev/null 2>&1; then exit 1; fi
cp "$expected" "$target"
rm "$expected"
ln -s "$target" "$expected"
if review >/dev/null 2>&1; then exit 1; fi
rm "$expected"
printf 'Private host /home/private-owner/work/\n' > "$target"
cp "$target" "$expected"
if SENEMOS_PRIVATE_HOST_HOME=/home/private-owner review >/dev/null 2>&1; then exit 1; fi
echo 'Exact OEM namespace bytes pass; changed, symlinked and private-host bytes reject'
