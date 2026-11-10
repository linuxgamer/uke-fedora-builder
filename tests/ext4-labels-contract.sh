#!/usr/bin/env bash
# Exercise the real offline inode labeler on a regular EXT4 image; no mount or device.
set -Eeuo pipefail
[[ $# == 1 ]]
labeler=$(realpath "$1")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -m755 "$work/root"
printf 'fixture\n' > "$work/root/file"
chmod 640 "$work/root/file"
touch -d '@1700000000.123456789' "$work/root/file"

ln -s /file "$work/root/link"
printf '/.* system_u:object_r:default_t:s0\n' > "$work/contexts"
truncate -s 32M "$work/root.img"
mkfs.ext4 -q -F -E "root_owner=$(id -u):$(id -g)" -d "$work/root" "$work/root.img"
if "$labeler" verify "$work/root.img" "$work/root" "$work/contexts" > "$work/unlabeled.log" 2>&1; then
    echo 'Unlabeled image was accepted' >&2; exit 1
fi
"$labeler" apply "$work/root.img" "$work/root" "$work/contexts"
"$labeler" verify "$work/root.img" "$work/root" "$work/contexts"
touch -d '@1700000000.987654321' "$work/root/file"
if "$labeler" verify "$work/root.img" "$work/root" "$work/contexts" > "$work/mtime-mismatch.log" 2>&1; then
    echo 'Source/image mtime mismatch was accepted' >&2; exit 1
fi
touch -d '@1700000000.123456789' "$work/root/file"

chmod 600 "$work/root/file"
if "$labeler" verify "$work/root.img" "$work/root" "$work/contexts" > "$work/mismatch.log" 2>&1; then
    echo 'Source/image mode mismatch was accepted' >&2; exit 1
fi
printf 'Actual EXT4 label apply/readback, symlink, missing label and mode-mismatch checks passed\n'
