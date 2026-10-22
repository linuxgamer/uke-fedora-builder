#!/bin/bash
# Host/composition-VM helper only; never installed in the tablet root.
set -Eeuo pipefail
[[ $# == 2 && -d $1 ]]
root=$(realpath "$1") output=$(realpath -m "$2")
[[ $root != / && $output != "$root"/* ]]
cd "$root"
getfattr --recursive --no-dereference --dump --encoding=hex \
    --match='^(security.capability|system.posix_acl_(access|default))$' . |
    awk '/^# file: / {path=substr($0,9); next}
         /^(security.capability|system.posix_acl_(access|default))=/ {print path "\t" $0}' |
    LC_ALL=C sort > "$output"
