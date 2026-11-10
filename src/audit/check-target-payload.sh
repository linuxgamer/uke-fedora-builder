#!/usr/bin/env bash
# Host-side scan of an already extracted target payload. Never runs target files.
set -euo pipefail
export LC_ALL=C
original=''
cutefish_original=''
while (($# > 1)); do
  case $1 in
    --original-kde-payload) [[ -d $2 ]] || exit 2; original=$(realpath -- "$2"); shift 2;;
    --verified-cutefish-payload) [[ -d $2 ]] || exit 2; cutefish_original=$(realpath -- "$2"); shift 2;;
    *) break;;
  esac
done
[[ $# == 1 && -d $1 ]] || { echo 'Usage: check-target-payload.sh [--original-kde-payload VERIFIED_DIRECTORY] [--verified-cutefish-payload VERIFIED_RPM_DIRECTORY] EXTRACTED_TARGET_DIRECTORY' >&2; exit 2; }
for tool in realpath find findmnt jq readlink readelf cmp mktemp rm grep head tail stat; do
  command -v "$tool" >/dev/null || { printf 'Missing host audit tool: %s\n' "$tool" >&2; exit 2; }
done
root=$(realpath -- "$1")
[[ $root != / && $original != "$root" ]] || exit 2
[[ -z $cutefish_original || ( $cutefish_original != "$root" && $cutefish_original != "$root/"* ) ]] || exit 2
# Finish discovery before issuing any acceptance result. Process substitution
# would hide find's exit status and could silently omit an unreadable subtree.
listing=$(mktemp)
mounts=$(mktemp)
read_errors=$(mktemp)
trap 'rm -f -- "$listing" "$mounts" "$read_errors"' EXIT
# Never inspect a live procfs/sysfs/device mount as extracted RPM bytes. Fail
# before discovery rather than pruning paths that could contain real payload.
if ! findmnt --all --list --json --output TARGET > "$mounts" ||
   ! jq -e --arg prefix "$root/" '
     (.filesystems | type == "array" and length > 0) and
     all(.filesystems[]; (.target | type == "string") and
                        (.target | startswith($prefix) | not))' "$mounts" >/dev/null; then
  echo 'Mounted target subtree or incomplete mount inventory; payload audit refused' >&2
  exit 1
fi
if ! find "$root" -mindepth 1 \( -type f -o -type l \) -print0 > "$listing"; then
  echo 'Target traversal failed; payload audit is incomplete' >&2
  exit 1
fi
python_needed=$'NEEDED[^\n]*libpython'
failed=0
verified_passive_cutefish_icon() {
  local path=$1 relative expected theme proof_theme target proof_target header ending bytes status references reference value
  relative=${path#"$root/"}
  [[ -n $cutefish_original && $relative == usr/share/icons/Cutefish/*.svg ]] || return 1
  theme=$root/usr/share/icons/Cutefish
  proof_theme=$cutefish_original/usr/share/icons/Cutefish
  expected=$cutefish_original/$relative
  target=$(realpath -e -- "$path") || return 1
  proof_target=$(realpath -e -- "$expected") || return 1
  [[ $target == "$theme/"* && $proof_target == "$proof_theme/"* && -f $target && -f $proof_target && ! -x $target && ! -x $proof_target ]] || return 1
  if [[ -L $path ]]; then
    [[ -L $expected && $(readlink -- "$path") == "$(readlink -- "$expected")" ]] || return 1
  else [[ ! -L $expected ]] || return 1; fi
  cmp -s -- "$target" "$proof_target" || return 1
  bytes=$(stat -c %s -- "$target") || return 1
  [[ $bytes =~ ^[0-9]+$ && $bytes -le 1048576 ]] || return 1
  header=$(head -c 256 -- "$target") || return 1
  local svg_start='^[[:space:]]*(<svg([[:space:]>])|<\?xml[[:space:]])'
  [[ $header =~ $svg_start ]] || return 1
  ending=$(tail -c 512 -- "$target") || return 1
  local svg_end='</svg>[[:space:]]*$'
  [[ $ending =~ $svg_end ]] && grep -Iq . "$target" || return 1
  # Passive, package-owned artwork only; no scripts, event handlers, entities,
  # external resources or embedded foreign content are admitted by this rule.
  if grep -Eiq '<[[:space:]]*(script|foreignObject)([[:space:]>])|<!DOCTYPE|<!ENTITY|[[:space:]]on[a-z]+[[:space:]]*=' "$target"; then return 1
  else status=$?; [[ $status == 1 ]] || return 1; fi
  references=$(grep -Eio "(xlink:)?href[[:space:]]*=[[:space:]]*['\"][^'\"]*['\"]" "$target") || { status=$?; [[ $status == 1 ]] || return 1; }
  while IFS= read -r reference; do
    [[ -n $reference ]] || continue
    value=${reference#*=}; value=${value#"${value%%[![:space:]]*}"}; value=${value:1:-1}
    # The signed theme embeds a PNG shadow. Admit only inert inline PNG data,
    # never arbitrary data URLs, remote resources or embedded SVG/HTML.
    [[ $value == \#* || $value =~ ^data:image/png\;base64,[A-Za-z0-9+/=[:space:]]+$ ]] || return 1
  done <<< "$references"
}
python_payload() {
  local path=$1 expected
  if verified_passive_cutefish_icon "$path"; then return; fi
  if [[ -n $original ]]; then
    expected=$original/${path#"$root/"}
    # Only bytes from the separately verified original KDE closure may pass.
    if [[ -L $path && -L $expected && $(realpath -- "$(dirname -- "$expected")") == "$original/"* && $(readlink -- "$path") == "$(readlink -- "$expected")" ]]; then return; fi
    if [[ ! -L $path && ! -L $expected && -f $expected && $(realpath -- "$expected") == "$original/"* ]] && cmp -s -- "$path" "$expected"; then return; fi
  fi
  printf 'Unapproved Python target payload: %s\n' "${path#"$root/"}" >&2
  failed=1
}
while IFS= read -r -d '' path; do
  name=${path##*/}
  case "$name" in
    *.py|*.pyc|*.pyo|*.pyz|python|python[0-9]*|libpython*|pypy*)
      python_payload "$path"; continue;;
  esac
  if [[ -L $path ]]; then
    link=$(readlink -- "$path")
    case "${link##*/}" in python*|pypy*|libpython*) python_payload "$path";; esac
  elif [[ -f $path ]]; then
    [[ -r $path ]] || { printf 'Unreadable target file: %s\n' "${path#"$root/"}" >&2; failed=1; continue; }
    # Bound the header read without spawning several processes for every file.
    header=''
    if IFS= read -r -n 256 -d '' header 2> "$read_errors" < "$path"; then :
    elif [[ -s $read_errors ]]; then
      printf 'Unreadable target header rejected: %s\n' "${path#"$root/"}" >&2
      failed=1; continue
    fi
    if [[ $header =~ ^\#\![^[:cntrl:]]*(python|pypy) ]]; then
      python_payload "$path"
    elif [[ ${header:0:4} == $'\177ELF' ]]; then
      if ! dynamic=$(readelf -d -- "$path" 2>/dev/null); then
        printf 'Unreadable target ELF rejected: %s\n' "${path#"$root/"}" >&2; failed=1
      elif [[ $dynamic =~ $python_needed ]]; then
        python_payload "$path"
      fi
    fi
  fi
done < "$listing"
((failed==0)) || exit 1
if [[ -n $original ]]; then
  echo 'Extracted target payload: Python limited to byte-identical verified original KDE closure'
else
  echo 'Extracted target payload: no recognized Python files, entrypoints or dynamic dependencies'
fi
