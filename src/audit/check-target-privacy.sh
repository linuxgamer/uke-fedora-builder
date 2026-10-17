#!/usr/bin/env bash
# Host-side privacy gate for extracted tablet payloads. Never runs target files.
set -euo pipefail
allowlist=''
private_home=''
while [[ ${1:-} == --* ]]; do
  case $1 in
    --namespace-policy) [[ $# -ge 3 && -z $allowlist && -f $2 ]] || exit 2; allowlist=$2; shift 2;;
    --private-home) [[ $# -ge 3 && -z $private_home && $2 =~ ^(/home|/Users)/[^/]+$ ]] || exit 2; private_home=$2; shift 2;;
    *) exit 2;;
  esac
done
[[ $# == 1 && -d $1 ]] || { echo 'Usage: check-target-privacy.sh [--namespace-policy JSON] [--private-home HOST_HOME] EXTRACTED_TARGET_DIRECTORY' >&2; exit 2; }
for tool in realpath find readlink rg sha256sum cut mktemp; do
  command -v "$tool" >/dev/null || { printf 'Missing host privacy tool: %s\n' "$tool" >&2; exit 2; }
done
if [[ -n $allowlist ]]; then command -v jq >/dev/null || exit 2; fi
root=$(realpath -- "$1")
failed=0
matches=$(mktemp)
trap 'rm -f "$matches"' EXIT
# Do not convert scanner/tool failures into an empty successful result.
# shellcheck disable=SC1003
if [[ -n $private_home ]]; then
  # Signed desktop RPMs contain public upstream /home examples and source
  # paths. Audit the actual build owner's home without admitting its bytes.
  rg -a -l --hidden --no-ignore -F -- "$private_home/" "$root" > "$matches" && status=0 || status=$?
else
  rg -a -l --hidden --no-ignore --pcre2 \
    -e '(?<![A-Za-z0-9_./-])/home/[^/:\s\x00]+/' \
    -e '(?<![A-Za-z0-9_./-])/Users/[^/\s\x00]+/' \
    -e 'C:\\Users\\' "$root" > "$matches" && status=0 || status=$?
fi
((status == 0 || status == 1)) || { echo 'Privacy scanner failed' >&2; exit 2; }

while IFS= read -r path; do
  relative=${path#"$root/"}
  if [[ -n $allowlist ]]; then
    # Exact reviewed public namespace files may contain non-private home prefixes.
    # An altered file, unknown path or actual invoking host home is still denied.
    expected=$(jq -er --arg path "$relative" '.files[] | select(.path==$path) | .sha256' "$allowlist" 2>/dev/null) || expected=''
    if [[ -n $expected && $(sha256sum "$path" | cut -d ' ' -f1) == "$expected" ]]; then
      if [[ -z ${SENEMOS_PRIVATE_HOST_HOME:-} ]] || ! rg -a -q -F -- "${SENEMOS_PRIVATE_HOST_HOME}/" "$path"; then
        continue
      fi
    fi
  fi
  printf 'Private absolute build path in target payload: %s\n' "${path#"$root/"}" >&2
  failed=1
done < "$matches"

while IFS= read -r -d '' path; do
  link=$(readlink -- "$path")
  if [[ -n $private_home && $link == "$private_home/"* ]] ||
     [[ -z $private_home && $link =~ ^(/home/[^/]+/|/Users/[^/]+/|[A-Za-z]:\\Users\\) ]]; then
    printf 'Private absolute symlink in target payload: %s\n' "${path#"$root/"}" >&2
    failed=1
  fi
done < <(find "$root" -type l -print0)

if [[ -f $root/prop.default ]]; then
  for expected in 'ro.build.user=uke-builder' 'ro.build.host=uke-build'; do
    if ! grep -Fqx -- "$expected" "$root/prop.default"; then
      printf 'Unsanitized or missing recovery build identity: %s\n' "${expected%%=*}" >&2
      failed=1
    fi
  done
fi

((failed==0)) || exit 1
echo 'Extracted target payload: no recognized private build paths or host identity'
