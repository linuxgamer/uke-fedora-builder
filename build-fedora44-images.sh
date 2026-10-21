#!/usr/bin/env bash
# Build the five Fedora 44 Xiaomi Pad 7 image pairs from one source checkout.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$here/.." && pwd)
stock=''
stock_archive=$here/payload/uke-os3.0.303.0-boot.zst
output=$workspace/build/fedora44-images
rebuild_kernel=0
cross_kernel=0

usage() {
    cat <<'HELP'
Usage: ./uke-fedora-builder/build-fedora44-images.sh [--stock-boot FILE] [--output NEW_DIR]
       [--rebuild-kernel] [--cross-kernel]

Build Linux 7.2.11 and Fedora 44 RPMs, then make separate TTY, KDE, GNOME,
Phosh and Plasma Mobile boot_a/userdata pairs. Bundled OEM inputs, including
the reviewed stock boot template, are verified automatically. The script does
not flash or select a device slot. A matching previous kernel RPM build is
reused unless --rebuild-kernel is given.
On x86_64, --cross-kernel compiles the ARM64 kernel with native Clang.
HELP
}
die() { printf 'fedora44-images: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case $1 in
        --stock-boot|--output)
            (($# >= 2)) || die "Missing value for $1"
            case $1 in --stock-boot) stock=$2;; --output) output=$2;; esac
            shift 2;;
        -h|--help) usage; exit 0;;
        --rebuild-kernel) rebuild_kernel=1; shift;;
        --cross-kernel) cross_kernel=1; shift;;
        *) die "Unknown argument: $1";;
    esac
done
[[ -x $here/build-fedora44-rootfs.sh && -x $here/build-fedora44-boot-a.sh ]] || die 'Image builders are missing'
[[ -x $workspace/uke-linux-hardware-support/xiaomi-uke-firmware/src/verify-local-blobs.sh ]] || die 'OEM input verifier is missing'
"$workspace/uke-linux-hardware-support/xiaomi-uke-firmware/src/verify-local-blobs.sh" || die 'Bundled OEM inputs are incomplete'
if command -v podman >/dev/null; then container=podman
elif command -v docker >/dev/null; then container=docker
else die 'Docker or Podman is required'; fi
for command in avbtool jq g++ sha256sum zstd; do command -v "$command" >/dev/null || die "Missing host command: $command"; done
output=$(realpath -m -- "$output")
[[ ! -e $output && ! -L $output ]] || die 'Output directory already exists; choose a new --output'
mkdir -p "$output"
if [[ -z $stock ]]; then
    [[ -f $stock_archive && ! -L $stock_archive ]] || die 'Bundled OS3.0.303.0 stock boot template is missing'
    [[ $(sha256sum "$stock_archive" | cut -d' ' -f1) == 47851c5899e9343a544f3efa6e12f5408fdc87f54da7078070025e7745160263 ]] || die 'Bundled stock boot archive hash mismatch'
    stock_dir=$(mktemp -d "$output/.stock.XXXXXXXX")
    trap 'rm -rf -- "$stock_dir"' EXIT
    stock=$stock_dir/boot.img
    zstd -q -dc "$stock_archive" > "$stock"
fi
[[ -f $stock && ! -L $stock ]] || die 'Stock boot.img is missing'
[[ $(sha256sum "$stock" | cut -d' ' -f1) == efdee1d4e1acd7f6e77615330dbcb045caeeccad8568d89fa6abd627f606e77f ]] || die 'Unexpected stock boot.img'
if ((cross_kernel)); then
    [[ $(uname -m) == x86_64 ]] || die '--cross-kernel requires an x86_64 host'
fi
cache_dir=$here/build/cache
mkdir -p "$cache_dir/dnf" "$cache_dir/dnf-x86_64" "$cache_dir/ccache" "$cache_dir/ccache-cross"

# bash -s reads the build recipe from stdin; keep stdin attached to the container.
"$container" run --rm -i --network=host --platform linux/arm64 --security-opt label=disable \
    -e UKE_REBUILD_KERNEL="$rebuild_kernel" -e UKE_CROSS_KERNEL="$cross_kernel" \
    -v "$cache_dir:/build-cache" \
    -v "$workspace:/work" -w /work registry.fedoraproject.org/fedora:44 \
    bash -s <<'BUILD_RPMS'
set -Eeuo pipefail
dnf=(dnf5 -y --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True)
"${dnf[@]}" install rpm-build dnf5-plugins make git-core jq curl gnupg2 xz tar patch \
  gzip coreutils findutils diffutils ccache
export UKE_CCACHE=1 CCACHE_DIR=/build-cache/ccache CCACHE_MAXSIZE=10G
git config --global --add safe.directory /work/senemos-uke-kernel
make -C senemos-uke-kernel srpm
make -C uke-linux-hardware-support/uke-core-meta srpm
make -C uke-linux-hardware-support/uke-sensors touchscreen-srpm
make -C uke-linux-hardware-support/uke-platform-runtime srpm
make -C uke-linux-hardware-support/uke-boot srpm
make -C uke-linux-hardware-support/uke-desktop-integration bluetooth-srpm
make -C uke-linux-hardware-support/xiaomi-uke-firmware fedora44-image-data-srpm
for package in libssc iio-sensor-proxy uke-ssc-fileservice; do
    make -C uke-linux-hardware-support/uke-sensors PACKAGE="$package" srpm
done
tops=(
  senemos-uke-kernel/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-core-meta/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-sensors/build/rpmbuild
  uke-linux-hardware-support/uke-platform-runtime/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-desktop-integration/build/bluetooth-srpm/rpmbuild
)
for top in "${tops[@]}"; do
    specs=("$top"/SPECS/*.spec)
    ((${#specs[@]} == 1)) || { printf 'Expected one spec in %s\n' "$top" >&2; exit 1; }
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        rm -f -- "$top/.fedora44-cross-pending"
    fi
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild && $UKE_REBUILD_KERNEL == 0 ]] && \
       bash uke-fedora-builder/src/image/kernel-rpm-cache.sh check "$top"; then
        printf 'Reusing verified Linux 7.2.11 RPMs and boot build\n'
        continue
    fi
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        rm -f -- "$top/.fedora44-kernel-cache/SOURCE-SHA256"
        if [[ -e $top/native-kernel-out || -e $top/boot-userspace ]]; then
            previous=$(mktemp -d "$top/previous-native-kernel-out.XXXXXXXX")
            for path in native-kernel-out boot-userspace; do
                [[ ! -e $top/$path ]] || mv -- "$top/$path" "$previous/"
            done
            printf 'Preserved the previous kernel work at %s\n' "$previous"
        fi
    fi
    "${dnf[@]}" builddep "${specs[0]}"
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild && $UKE_CROSS_KERNEL == 1 ]]; then
        rpmbuild -bp --nodeps --target aarch64 --define "_topdir /work/$top" "${specs[0]}"
        source=$top/BUILD/senemos-uke-linux-kernel-mainline-7.2.11-build/linux-7.2.11
        base=$top/boot-userspace
        bash "$source/boot-recipe/src/boot/make-initramfs-base.sh" "$base" 7.2.11-6
        clang++ -std=c++17 -O2 -Wall -Wextra -Werror -ffile-prefix-map="$PWD"=. \
            "$source/boot-recipe/src/boot/offline-switch-root.cpp" -o "$base/uke-offline-switch-root"
        clang++ -std=c++20 -O2 -Wall -Wextra -Werror \
            "$source/boot-recipe/src/boot/boot-image.cpp" -o "$base/boot-image-aarch64"
        for binary in uke-offline-switch-root boot-image-aarch64; do
            readelf -h "$base/$binary" | grep -E 'Machine:.*AArch64' >/dev/null
        done
        printf '7.2.11-6\n' > "$top/.fedora44-cross-pending"
        continue
    fi
    rpmbuild -ba --target aarch64 --define "_topdir /work/$top" "${specs[0]}"
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        bash uke-fedora-builder/src/image/kernel-rpm-cache.sh record "$top"
    fi
done
sensor_root=uke-linux-hardware-support/uke-sensors/build/srpm
for package in libssc iio-sensor-proxy uke-ssc-fileservice; do
    top=$sensor_root/$package/rpmbuild
    spec=$top/SPECS/$package.spec
    "${dnf[@]}" builddep "$spec"
    rpmbuild -ba --target aarch64 --define "_topdir /work/$top" "$spec"
    if [[ $package == libssc ]]; then
        "${dnf[@]}" install "$top"/RPMS/aarch64/libssc-devel-0.4.4-*.fc44.aarch64.rpm
    fi
done
top=uke-linux-hardware-support/xiaomi-uke-firmware/build/fedora44-image-data/rpmbuild
rpmbuild -ba --target noarch --define "_topdir /work/$top" \
    "$top/SPECS/uke-fedora44-oem-data.spec"
BUILD_RPMS

kernel_top=$workspace/senemos-uke-kernel/build/srpm/rpmbuild
if [[ -f $kernel_top/.fedora44-cross-pending ]]; then
    "$container" run --rm -i --network=host --platform linux/amd64 --security-opt label=disable \
        -v "$cache_dir:/build-cache" -v "$workspace:/work" -w /work \
        registry.fedoraproject.org/fedora:44 bash -s <<'CROSS_KERNEL'
set -Eeuo pipefail
dnf5 -y --setopt=system_cachedir=/build-cache/dnf-x86_64 --setopt=keepcache=True install \
    bc bison clang compiler-rt elfutils-libelf-devel flex gcc gcc-c++ gzip \
    llvm lld make ncurses-devel openssl-devel perl python3 rsync zstd dtc \
    kmod findutils binutils ccache cpio tar ripgrep
top=/work/senemos-uke-kernel/build/srpm/rpmbuild
source=$top/BUILD/senemos-uke-linux-kernel-mainline-7.2.11-build/linux-7.2.11
[[ $(cat "$top/.fedora44-cross-pending") == 7.2.11-6 ]] || exit 2
export UKE_CROSS_KERNEL=1 UKE_CCACHE=1 CCACHE_DIR=/build-cache/ccache-cross CCACHE_MAXSIZE=10G
export KBUILD_BUILD_USER=senemos KBUILD_BUILD_HOST=copr-builder KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1791725270
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')
export KBUILD_BUILD_TIMESTAMP
bash "$source/boot-recipe/src/boot/build-payload.sh" "$source" \
    "$top/native-kernel-out" "$top/boot-userspace/base" 7.2.11-6 8
CROSS_KERNEL

    "$container" run --rm -i --network=host --platform linux/arm64 --security-opt label=disable \
        -v "$cache_dir:/build-cache" -v "$workspace:/work" -w /work \
        registry.fedoraproject.org/fedora:44 bash -s <<'PACKAGE_KERNEL'
set -Eeuo pipefail
dnf=(dnf5 -y --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True)
"${dnf[@]}" install rpm-build dnf5-plugins make
top=/work/senemos-uke-kernel/build/srpm/rpmbuild
spec=$top/SPECS/senemos-uke-linux-kernel-mainline.spec
"${dnf[@]}" builddep "$spec"
UKE_PREBUILT_KERNEL=1 rpmbuild -ba --target aarch64 --define "_topdir $top" "$spec"
bash /work/uke-fedora-builder/src/image/kernel-rpm-cache.sh record "$top"
rm -f -- "$top/.fedora44-cross-pending"
PACKAGE_KERNEL
fi

[[ -d $kernel_top/BUILD ]] || die 'Kernel RPM build did not create its BUILD directory'
kernel_rpms=$kernel_top/RPMS/aarch64
kernel_out=$kernel_top/native-kernel-out
guard=$(find "$kernel_top/BUILD" -type f \
  -path '*/linux-7.2.11/boot-recipe/src/boot/dracut/root-guard.sh' -print -quit)
[[ -n $guard ]] || die 'Prepared kernel source was not found'
kernel_source=${guard%/boot-recipe/src/boot/dracut/root-guard.sh}
core_rpm=$workspace/uke-linux-hardware-support/uke-core-meta/build/srpm/rpmbuild/RPMS/aarch64/uke-core-meta-1.0.0-5.fc44.aarch64.rpm
hardware_rpms=$output/hardware-rpms
mkdir "$hardware_rpms"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/rpmbuild/RPMS/aarch64/uke-touchscreen-0.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-platform-runtime/build/srpm/rpmbuild/RPMS/aarch64/uke-battery-observer-0.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild/RPMS/aarch64/uke-wifi-factory-0.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-desktop-integration/build/bluetooth-srpm/rpmbuild/RPMS/aarch64/uke-bluetooth-0.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/libssc/rpmbuild/RPMS/aarch64/libssc-0.4.4-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/iio-sensor-proxy/rpmbuild/RPMS/aarch64/iio-sensor-proxy-3.9-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/uke-ssc-fileservice/rpmbuild/RPMS/aarch64/uke-ssc-fileservice-2026.09.21-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/xiaomi-uke-firmware/build/fedora44-image-data/rpmbuild/RPMS/noarch/uke-fedora44-oem-data-3.0.303.0-2.fc44.noarch.rpm "$hardware_rpms/"

for profile in tty kde gnome phosh plasma-mobile; do
    root_mib=4096
    [[ $profile == tty ]] || root_mib=8192
    "$here/build-fedora44-rootfs.sh" \
        --profile "$profile" --kernel-rpms "$kernel_rpms" \
        --core-rpm "$core_rpm" --hardware-rpms "$hardware_rpms" \
        --root-mib "$root_mib" --output "$output/$profile-rootfs"
    "$here/build-fedora44-boot-a.sh" \
        --rootfs "$output/$profile-rootfs" --kernel-source "$kernel_source" \
        --kernel-out "$kernel_out" --stock-boot "$stock" \
        --output "$output/$profile-pair"
    (cd "$output/$profile-pair" && sha256sum -c SHA256SUMS)
done
printf 'Five image pairs are in %s\n' "$output"
