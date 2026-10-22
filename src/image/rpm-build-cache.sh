#!/usr/bin/env bash
# Cache only a complete, verified local RPM build.
set -Eeuo pipefail

[[ $# -ge 2 && ( $1 == check || $1 == record || $1 == invalidate ) ]] || {
    echo 'Usage: rpm-build-cache.sh check|record|invalidate RPMBUILD_TOP [DEPENDENCY_RPM ...]' >&2
    exit 2
}
action=$1
script=$(realpath -- "${BASH_SOURCE[0]}")
top=$(realpath -- "$2")
shift 2
cache=.fedora44-rpm-cache
if [[ $action == invalidate ]]; then
    cd "$top"
    rm -rf -- "$cache" RPMS
    exit 0
fi
dependencies=()
for dependency in "$@"; do
    [[ -s $dependency ]] || exit 1
    dependencies+=("$(realpath -- "$dependency")")
done
cd "$top"

[[ -d SOURCES && -d SPECS ]] || exit 1
mapfile -d '' -t inputs < <(find SOURCES SPECS -type f -print0 | LC_ALL=C sort -z)
((${#inputs[@]} > 0)) || exit 1
source_hash=$(sha256sum "${inputs[@]}" | sha256sum | cut -d' ' -f1)
dependency_hash=$(for dependency in "${dependencies[@]}"; do
    sha256sum "$dependency"
done | sha256sum | cut -d' ' -f1)
recipe_hash=$(sha256sum "$script" | cut -d' ' -f1)
key=$(printf '%s\n' "$source_hash" "$dependency_hash" "$recipe_hash" 'fedora44-aarch64-rpmbuild-v1' | sha256sum | cut -d' ' -f1)

if [[ $action == check ]]; then
    [[ -s $cache/INPUT-SHA256 && -s $cache/RPMS.sha256 ]] || exit 1
    [[ $(cat "$cache/INPUT-SHA256") == "$key" ]] || exit 1
    current=$(find RPMS -type f -name '*.rpm' | wc -l)
    recorded=$(wc -l < "$cache/RPMS.sha256")
    [[ $current == "$recorded" && $current != 0 ]] || exit 1
    sha256sum -c --status "$cache/RPMS.sha256"
    exit
fi

mapfile -d '' -t rpms < <(find RPMS -type f -name '*.rpm' -print0 | LC_ALL=C sort -z)
((${#rpms[@]} > 0)) || { echo "No binary RPMs in $top" >&2; exit 1; }
stage=$(mktemp -d "$top/.rpm-cache.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
printf '%s\n' "$key" > "$stage/INPUT-SHA256"
sha256sum "${rpms[@]}" > "$stage/RPMS.sha256"
mkdir -p "$cache"
mv -f -- "$stage/INPUT-SHA256" "$stage/RPMS.sha256" "$cache/"
printf 'Cached %s binary RPM(s) from %s\n' "${#rpms[@]}" "$top"
