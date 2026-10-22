#!/usr/bin/env bash
# Host-side scan of an already extracted target payload. Never runs target files.
set -euo pipefail
export LC_ALL=C
original=''
if [[ ${1:-} == --original-kde-payload ]]; then
  [[ $# == 3 && -d $2 ]] || exit 2
  original=$(realpath -- "$2"); shift 2
fi
[[ $# == 1 && -d $1 ]] || { echo 'Usage: check-target-payload.sh [--original-kde-payload VERIFIED_ORIGINAL_DIRECTORY] EXTRACTED_TARGET_DIRECTORY' >&2; exit 2; }
for tool in realpath find readlink grep readelf cmp; do
  command -v "$tool" >/dev/null || { printf 'Missing host audit tool: %s\n' "$tool" >&2; exit 2; }
done
root=$(realpath -- "$1")
[[ $original != "$root" ]] || exit 2
failed=0
python_payload() {
  local path=$1 expected
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
    IFS= read -r -n 256 -d '' header < "$path" || :
    if [[ $header =~ ^\#\![^[:cntrl:]]*(python|pypy) ]]; then
      python_payload "$path"
    elif [[ ${header:0:4} == $'\177ELF' ]]; then
      if ! dynamic=$(readelf -d -- "$path" 2>/dev/null); then
        printf 'Unreadable target ELF rejected: %s\n' "${path#"$root/"}" >&2; failed=1
      elif grep 'NEEDED.*libpython' <<< "$dynamic" >/dev/null; then
        python_payload "$path"
      fi
    fi
  fi
done < <(find "$root" -mindepth 1 \( -type f -o -type l \) -print0)
((failed==0)) || exit 1
if [[ -n $original ]]; then
  echo 'Extracted target payload: Python limited to byte-identical verified original KDE closure'
else
  echo 'Extracted target payload: no recognized Python files, entrypoints or dynamic dependencies'
fi
