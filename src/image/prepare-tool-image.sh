#!/usr/bin/env bash
# Runs once in a Fedora 44 container before that container becomes a cached image.
set -Eeuo pipefail
[[ $# == 1 && ( $1 == arm64 || $1 == amd64 ) ]] || exit 2
arch=$1
mirror=${UKE_FEDORA_MIRROR%/}
sed -i "0,/^metalink=/s@^metalink=.*@baseurl=${mirror}/releases/44/Everything/\$basearch/os/@" \
    /etc/yum.repos.d/fedora.repo
sed -i "0,/^metalink=/s@^metalink=.*@baseurl=${mirror}/updates/44/Everything/\$basearch/@" \
    /etc/yum.repos.d/fedora-updates.repo
# Fedora's Cisco repository is unreachable from some build locations. The
# desktop recipe requests Fedora's noopenh264 package explicitly instead.
if [[ -f /etc/yum.repos.d/fedora-cisco-openh264.repo ]]; then
    sed -i 's/^enabled=1$/enabled=0/' /etc/yum.repos.d/fedora-cisco-openh264.repo
fi
case $arch in
    arm64) cache=dnf; extra=(dnf5-plugins e2fsprogs e2fsprogs-devel git-core gnupg2 jq libselinux-devel patch systemd);;
    amd64) cache=dnf-x86_64; extra=(binutils ripgrep);;
esac
dnf5 -y --setopt="system_cachedir=/build-cache/$cache" --setopt=keepcache=True \
    --setopt=install_weak_deps=False install \
    bc bison ccache clang compiler-rt coreutils cpio curl diffutils dtc \
    elfutils-libelf-devel findutils flex gcc gcc-c++ gzip kmod lld llvm make \
    ncurses-devel openssl-devel perl python3 rpm-build rsync tar xz zstd \
    "${extra[@]}"
