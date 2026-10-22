#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 0 && -f /job/packages.complete ]]
install -m644 /job/inputs/compose.repo /etc/yum.repos.d/uke-compose.repo
install -m644 /job/inputs/fedora-46.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora46
install -m644 /job/inputs/uke-copr.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-copr
mkdir -p /job/inputs/device-rpms
dnf5 --use-host-config --installroot=/job/root --releasever=rawhide \
    --disable-repo='*' --enable-repo=uke-linux --setopt=cachedir=/job/cache \
    --setopt=keepcache=True --setopt=excludepkgs='*-debuginfo,*-debugsource' \
    download --destdir=/job/inputs/device-rpms \
    uke-touchscreen uke-boot-integration uke-adaptive-display \
    libssc iio-sensor-proxy uke-ssc-fileservice \
    mesa-dri-drivers mesa-vulkan-drivers mesa-filesystem mesa-libEGL mesa-libGL mesa-libgbm
