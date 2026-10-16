#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 && -d $1 ]] || exit 2
root=${1%/}
shopt -s nullglob
sessions=("$root"/usr/share/wayland-sessions/*.desktop "$root"/usr/share/xsessions/*.desktop)
if ((${#sessions[@]})); then
    printf 'Console image contains a graphical session: %s\n' "${sessions[0]}" >&2
    exit 1
fi
