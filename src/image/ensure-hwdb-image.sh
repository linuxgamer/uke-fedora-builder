#!/usr/bin/env bash
# Cache native Fedora 44 tools for udev database and ext4 image creation.
set -Eeuo pipefail
[[ $# == 1 ]] || { echo 'Usage: ensure-hwdb-image.sh docker|podman' >&2; exit 2; }
container=$1
case $container in docker|podman) ;; *) exit 2;; esac
case $(uname -m) in x86_64) platform=linux/amd64;; aarch64) platform=linux/arm64;; *) echo 'Unsupported host architecture' >&2; exit 2;; esac
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mirror=${UKE_FEDORA_MIRROR:-https://mirror.yandex.ru/fedora/linux}
[[ $mirror =~ ^https://[A-Za-z0-9._:/-]+$ ]] || { echo 'Invalid UKE_FEDORA_MIRROR' >&2; exit 2; }
mirror=${mirror%/}
key=$( { sha256sum "$here/ensure-hwdb-image.sh" | cut -d' ' -f1;
         printf '%s\n' "$mirror" "$platform"; } | sha256sum | cut -c1-16)
image=localhost/uke-fedora44-hwdb:$key
if ! "$container" image inspect "$image" >/dev/null 2>&1; then
    name=uke-fedora44-hwdb-$key-$$
    cleanup() { "$container" rm -f "$name" >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    run_label=()
    [[ -z ${UKE_BUILD_RUN_ID:-} ]] || run_label=(--label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID")
    "$container" run --name "$name" --platform "$platform" --network=host \
        --security-opt label=disable "${run_label[@]}" \
        -e "UKE_FEDORA_MIRROR=$mirror" \
        registry.fedoraproject.org/fedora:44 bash -euc '
            mirror=${UKE_FEDORA_MIRROR%/}
            sed -i "0,/^metalink=/s@^metalink=.*@baseurl=${mirror}/releases/44/Everything/\$basearch/os/@" /etc/yum.repos.d/fedora.repo
            sed -i "0,/^metalink=/s@^metalink=.*@baseurl=${mirror}/updates/44/Everything/\$basearch/@" /etc/yum.repos.d/fedora-updates.repo
            dnf5 -y --disable-repo=fedora-cisco-openh264 --setopt=install_weak_deps=False install \
                systemd-udev gcc-c++ e2fsprogs e2fsprogs-devel libselinux-devel \
                diffutils tar zstd
            command -v systemd-hwdb
            command -v mkfs.ext4
            command -v g++
        ' >&2
    "$container" commit "$name" "$image" >&2
    trap - EXIT
    cleanup
fi
printf '%s\n' "$image"
