#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../src/public/source-inputs.sh
# shellcheck disable=SC1091
source "$root/src/public/source-inputs.sh"
fixture=$(mktemp -d)
trap 'find "$fixture" -depth -delete' EXIT
mkdir -p "$fixture/source/packaging/families"
digest=$(printf 'source fixture\n' | sha256sum | cut -d ' ' -f1)
jq -n --arg digest "$digest" '[{name:"fixture",sha256:$digest}]' > "$fixture/source/packaging/families/source-inputs.json"
jq '.[] += {url:"https://github.com/MCC45TR/uke-linux-hardware-support/releases/download/copr-migration-archive-20261020/fixture.src.rpm"}' "$fixture/source/packaging/families/source-inputs.json" > "$fixture/mirrors.json"
curl() {
    local output=''
    while (($#)); do
        if [[ $1 == -o ]]; then output=$2; shift; fi
        shift
    done
    printf 'download\n' >> "$fixture/calls"
    printf 'source fixture\n' > "$output"
}
reject() { if public_source_inputs "$fixture/source" "$fixture/mirrors.json" > /dev/null 2>&1; then echo "Invalid source cache accepted: $1" >&2; exit 1; fi; }
public_source_inputs "$fixture/source" "$fixture/mirrors.json" > /dev/null
input=$fixture/source/packaging/families/source-cache/inputs/fixture.src.rpm
[[ -s $input && $(wc -l < "$fixture/calls") == 1 ]]
UKE_OFFLINE=1 public_source_inputs "$fixture/source" "$fixture/mirrors.json" > /dev/null
[[ $(wc -l < "$fixture/calls") == 1 ]]
printf 'corrupt\n' > "$input"
reject 'corrupt existing cache'
unlink "$input"
UKE_OFFLINE=1 reject 'missing offline input'
[[ $(wc -l < "$fixture/calls") == 1 ]]
jq '.[0].sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$fixture/source/packaging/families/source-inputs.json" > "$fixture/changed.json"
mv "$fixture/changed.json" "$fixture/source/packaging/families/source-inputs.json"
reject 'unmapped source hash'
[[ $(wc -l < "$fixture/calls") == 1 ]]
jq '.[0].sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$fixture/mirrors.json" > "$fixture/changed.json"
mv "$fixture/changed.json" "$fixture/mirrors.json"
reject 'download hash mismatch'
[[ ! -e $input && $(wc -l < "$fixture/calls") == 2 ]]
echo 'Pinned source download, offline reuse and corrupt/missing/unmapped/hash-mismatch refusals passed'
