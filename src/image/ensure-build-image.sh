#!/usr/bin/env bash
# Keep tool packages in a reusable container image instead of reinstalling them.
set -Eeuo pipefail

[[ $# == 2 ]] || { echo 'Usage: ensure-build-image.sh docker|podman linux/arm64|linux/amd64' >&2; exit 2; }
container=$1 platform=$2
case $container in docker|podman) ;; *) exit 2;; esac
container_cli=$(command -v "$container")
case $platform in linux/arm64) arch=arm64;; linux/amd64) arch=amd64;; *) exit 2;; esac
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mirror=${UKE_FEDORA_MIRROR:-https://mirror.yandex.ru/fedora/linux}
[[ $mirror =~ ^https://[A-Za-z0-9._:/-]+$ ]] || {
    echo 'UKE_FEDORA_MIRROR must be an HTTPS Fedora linux mirror root' >&2; exit 2;
}
mirror=${mirror%/}
recipe=$here/prepare-tool-image.sh
key=$( { sha256sum "$recipe" | cut -d' ' -f1; printf '%s\n' "$mirror" "$arch"; } | sha256sum | cut -c1-16)
image=localhost/uke-fedora44-tools:$arch-$key
if ! "$container_cli" image inspect "$image" >/dev/null 2>&1; then
    printf 'Building reusable Fedora 44 %s tool image from %s\n' "$arch" "$mirror" >&2
    task_container_name=uke-fedora44-tools-$arch-$key-$$
    cleanup() { "$container_cli" rm -f "$task_container_name" >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    run_label=()
    [[ -z ${UKE_BUILD_RUN_ID:-} ]] || run_label=(--label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID")
    "$container_cli" run --name "$task_container_name" --platform "$platform" --network=host \
        --security-opt label=disable "${run_label[@]}" -e "UKE_FEDORA_MIRROR=$mirror" \
        -v "$here/prepare-tool-image.sh:/prepare-tool-image.sh:ro" \
        -v "$here/../../build/cache:/build-cache" \
        registry.fedoraproject.org/fedora:44 bash /prepare-tool-image.sh "$arch" >&2
    "$container_cli" commit "$task_container_name" "$image" >&2
    trap - EXIT
    cleanup
fi
[[ $("$container_cli" image inspect "$image" --format '{{.Architecture}}') == "$arch" ]] || {
    echo "Cached tool image has the wrong architecture: $image" >&2; exit 1;
}
printf '%s\n' "$image"
