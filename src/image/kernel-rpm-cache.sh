#!/usr/bin/env bash
# Admit a previous kernel RPM build only when its inputs and output files match.
set -Eeuo pipefail

[[ $# == 2 && ( $1 == check || $1 == record ) ]] || {
    echo 'Usage: kernel-rpm-cache.sh check|record RPMBUILD_TOP' >&2
    exit 2
}
action=$1
top=$(realpath -- "$2")
cd "$top"

source_hash=$(find SOURCES SPECS -type f -print0 | LC_ALL=C sort -z | \
    xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
release=7.2.11-31.fc44
rpm_paths=()
for part in '' -core -modules -dtbs -boot; do
    path=RPMS/aarch64/senemos-uke-linux-kernel-mainline${part}-${release}.aarch64.rpm
    [[ -s $path ]] || { [[ $action == check ]] && exit 1; echo "Missing kernel RPM: $path" >&2; exit 1; }
    rpm_paths+=("$path")
done

source=BUILD/senemos-uke-linux-kernel-mainline-7.2.11-build/linux-7.2.11
out=native-kernel-out
build_paths=("$source/boot-recipe/src/boot/dracut/root-guard.sh" \
    "$out/.config" "$out/boot-initramfs.cpio.gz" "$out/Module.symvers" \
    "$out/boot-manifest" "$out/arch/arm64/boot/Image")
mode=native
if [[ -s $out/cross-source.sha256 ]]; then
    mode=cross
    build_paths+=("$out/cross-source.sha256")
fi
for path in "${build_paths[@]}"; do
    [[ -s $path ]] || { [[ $action == check ]] && exit 1; echo "Missing kernel build artifact: $path" >&2; exit 1; }
done

cache=.fedora44-kernel-cache
if [[ $action == check ]]; then
    [[ -s $cache/SOURCE-SHA256 && -s $cache/RPMS.sha256 && -s $cache/BUILD.sha256 ]] || exit 1
    [[ $(cat "$cache/SOURCE-SHA256") == "$source_hash" ]] || exit 1
    if [[ -s $cache/BUILD-MODE ]]; then
        [[ $(cat "$cache/BUILD-MODE") == "$mode" ]] || exit 1
    else
        [[ $mode == native ]] || exit 1
    fi
    sha256sum -c --status "$cache/RPMS.sha256" "$cache/BUILD.sha256" || exit 1
    exit 0
fi

mkdir -p "$cache"
stage=$(mktemp -d "$cache/.record.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
printf '%s\n' "$source_hash" > "$stage/SOURCE-SHA256"
printf '%s\n' "$mode" > "$stage/BUILD-MODE"
sha256sum "${rpm_paths[@]}" > "$stage/RPMS.sha256"
sha256sum "${build_paths[@]}" > "$stage/BUILD.sha256"
mv -f -- "$stage/SOURCE-SHA256" "$stage/BUILD-MODE" "$stage/RPMS.sha256" "$stage/BUILD.sha256" "$cache/"
printf 'Cached Linux %s RPM build for source %s\n' "$release" "$source_hash"
