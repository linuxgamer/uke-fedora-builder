#!/usr/bin/env bash
# Build selected Fedora 44 Xiaomi Pad 7 image pairs from one source checkout.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$here/.." && pwd)
stock=''
stock_archive=$here/payload/uke-os3.0.304.0-boot.zst
output=$workspace/build/fedora44-images
rebuild_kernel=0
cross_kernel=0
resume=0
control=''
profiles_arg=all
profiles_seen=0
touch_panel=tm

usage() {
    cat <<'HELP'
Usage: ./uke-fedora-builder/build-fedora44-images.sh [--stock-boot FILE] [--output DIR]
       [--profiles LIST] [--touch-panel tm|csot]
       [--rebuild-kernel] [--cross-kernel] [--resume]
       ./uke-fedora-builder/build-fedora44-images.sh --status|--stop --output DIR
       ./uke-fedora-builder/build-fedora44-images.sh --audit-only --profiles LIST --output DIR

Build Linux 7.2.11 and Fedora 44 RPMs, then make separate TTY, KDE, GNOME,
Phosh and Plasma Mobile boot_a/userdata pairs. LIST is all (the default) or
a comma-separated subset of tty,kde,gnome,phosh,plasma-mobile. Desktop profiles
also build the TTY rootfs and boot pair as shared prerequisites. Bundled OEM
inputs, including the reviewed stock boot template, are verified automatically.
The touch panel defaults to TM, matching the tested tablet; select CSOT for a
tablet whose stock driver identifies that panel.
The stock panel selector uses native DPU/DSI with seven fixed OEM modes on
O82-36. Keep a previously tested boot image for recovery while testing rates.
The script does not flash or select a device slot. A matching kernel RPM build is
reused unless --rebuild-kernel is given.
On x86_64, --cross-kernel compiles the ARM64 kernel with native Clang.
Use --status for concise progress, --stop to cancel, and --resume to reuse
completed artifacts from an interrupted run. --audit-only rechecks completed
image pairs or finishes a run that stopped at the final audit.
HELP
}
die() { printf 'fedora44-images: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case $1 in
        --stock-boot|--output|--profiles|--touch-panel)
            (($# >= 2)) || die "Missing value for $1"
            case $1 in --stock-boot) stock=$2;; --output) output=$2;; --profiles) ((profiles_seen == 0)) || die 'Specify --profiles once'; profiles_seen=1; profiles_arg=$2;; --touch-panel) touch_panel=$2;; esac
            shift 2;;
        -h|--help) usage; exit 0;;
        --rebuild-kernel) rebuild_kernel=1; shift;;
        --cross-kernel) cross_kernel=1; shift;;
        --resume) resume=1; shift;;
        --status|--stop|--audit-only) [[ -z $control ]] || die 'Choose one control command'; control=$1; shift;;
        *) die "Unknown argument: $1";;
    esac
done
[[ $touch_panel == tm || $touch_panel == csot ]] || die 'Select tm or csot touch panel'
canonical_profiles=(tty kde gnome phosh plasma-mobile)
declare -A seen_profiles=()
if [[ $profiles_arg != all ]]; then
    [[ $profiles_arg =~ ^(tty|kde|gnome|phosh|plasma-mobile)(,(tty|kde|gnome|phosh|plasma-mobile))*$ ]] || die 'Invalid --profiles list'
    IFS=, read -r -a requested_profiles <<< "$profiles_arg"
else
    requested_profiles=("${canonical_profiles[@]}")
fi
for profile in "${requested_profiles[@]}"; do
    [[ ! ${seen_profiles[$profile]+present} ]] || die "Duplicate profile: $profile"
    seen_profiles[$profile]=1
done
build_profiles=()
for profile in "${canonical_profiles[@]}"; do
    if [[ $profile == tty || ${seen_profiles[$profile]+present} ]]; then
        build_profiles+=("$profile")
    fi
done
build_total=$((12 + 2 * ${#build_profiles[@]}))
output=$(realpath -m -- "$output")
source "$here/src/image/build-control.sh"
if [[ $control == --status ]]; then build_status; exit; fi
if [[ $control == --stop ]]; then build_stop; exit; fi
profile_valid() {
    local path=$1 profile=$2
    [[ -d $path && ! -L $path && -s $path/SHA256SUMS && -s $path/BUILD-INPUTS.sha256 ]] || return 1
    [[ $(cat "$path/PROFILE-ID" 2>/dev/null) == "$profile" ]] || return 1
    [[ $(cat "$path/BUILD-INPUTS.sha256") == "$input_hash" ]] || return 1
    (cd "$path" && sha256sum -c --status SHA256SUMS) || return 1
    if [[ -d $path/root ]]; then
        bash "$here/src/image/audit-fedora44-rootfs.sh" "$path" || return 1
    fi
}
audit_final() {
    : > "$output/audit-report.txt"
    for profile in "${build_profiles[@]}"; do
        profile_valid "$output/$profile-rootfs" "$profile" || die "Invalid $profile rootfs"
        profile_valid "$output/$profile-pair" "$profile" || die "Invalid $profile image pair"
        if grep -Eq 'CONFIG_CMDLINE=".*[[:space:]]systemd\.unit=' "$output/$profile-pair/boot.config"; then
            die "Forced systemd target in $profile boot image"
        fi
        for receipt in NATIVE-O82-36 NATIVE-O82-36-RATES NATIVE-O82-36-ALL-RATES; do
            [[ $(cat "$output/$profile-pair/$receipt") == 1 ]] || die "Incorrect $profile $receipt receipt"
        done
        jq -e '.experimental_native_o82_36 and .experimental_native_o82_36_rates and
               .experimental_native_o82_36_all_rates' \
            "$output/$profile-pair/manifest.json" >/dev/null || die "Incorrect $profile native display manifest"
        if grep -Eq 'uke\.native_o82_36(_rates)?=' "$output/$profile-pair/boot.config"; then
            die "Obsolete O82-36 boot selector in $profile image"
        fi
        expected_target=graphical.target
        [[ $profile != tty ]] || expected_target=multi-user.target
        [[ $(readlink "$output/$profile-rootfs/root/etc/systemd/system/default.target") == "/usr/lib/systemd/system/$expected_target" ]] \
            || die "Incorrect default.target in $profile rootfs"
        printf 'PASS %s: rootfs and image pair checksums, critical files, OEM firmware\n' "$profile" \
            >> "$output/audit-report.txt"
    done
    python3 "$here/src/image/audit-fedora44-build-log.py" "$output/build.log" "$UKE_BUILD_RUN_ID" \
        | tee -a "$output/audit-report.txt" \
        || die 'Unreviewed package scriptlet error in build log'
}
if [[ $control == --audit-only ]]; then
    [[ $profiles_seen == 1 && -d $output && ! -L $output && -s $output/BUILD-INPUTS.sha256 ]] \
        || die '--audit-only requires the original --profiles list and output directory'
    exec 9>"$output/.build.lock"
    flock -n 9 || die 'Build already active'
    jq -e --argjson total "$build_total" \
        '(.state == "complete" or (.state == "failed" and .stage == "Audit release outputs" and .completed == ($total - 1))) and .total == $total' \
        "$output/status.json" >/dev/null || die 'This run has no complete set of requested image pairs'
    UKE_BUILD_RUN_ID=$(jq -er .run_id "$output/status.json")
    input_hash=$(cat "$output/BUILD-INPUTS.sha256")
    audit_status=$(mktemp "$output/.status.XXXXXXXX")
    jq --argjson updated "$(date +%s)" \
        '.state="failed" | .stage="Audit release outputs" | .completed=(.total - 1) | .updated_unix=$updated' \
        "$output/status.json" > "$audit_status"
    chmod 0666 "$audit_status"
    mv -f -- "$audit_status" "$output/status.json"
    audit_final
    status_stage=$(mktemp "$output/.status.XXXXXXXX")
    jq --argjson updated "$(date +%s)" \
        '.state="complete" | .stage="Requested image pairs complete" | .completed=.total | .updated_unix=$updated' \
        "$output/status.json" > "$status_stage"
    chmod 0666 "$status_stage"
    mv -f -- "$status_stage" "$output/status.json"
    printf 'complete: Requested image pairs complete (%s/%s stages)\n' "$build_total" "$build_total" \
        | tee -a "$output/progress.log"
    exit
fi
[[ -x $here/build-fedora44-rootfs.sh && -x $here/build-fedora44-boot-a.sh ]] || die 'Image builders are missing'
[[ -x $workspace/uke-linux-hardware-support/xiaomi-uke-firmware/src/verify-fedora44-oem-304.sh ]] || die 'OEM input verifier is missing'
"$workspace/uke-linux-hardware-support/xiaomi-uke-firmware/src/verify-fedora44-oem-304.sh" || die 'Bundled OS3.0.304.0 OEM inputs are incomplete'
if command -v podman >/dev/null; then container=podman
elif command -v docker >/dev/null; then container=docker
else die 'Docker or Podman is required'; fi
# LeakSanitizer cannot inspect ARM64 test processes under user-mode emulation.
# Keep AddressSanitizer and UndefinedBehaviorSanitizer enabled in RPM checks.
sanitizer_env=()
[[ $(uname -m) == aarch64 ]] || sanitizer_env=(-e ASAN_OPTIONS=detect_leaks=0)
for command in avbtool jq g++ python3 sha256sum zstd; do command -v "$command" >/dev/null || die "Missing host command: $command"; done
if ((resume)); then
    [[ -d $output && ! -L $output ]] || die '--resume requires an existing output directory'
else
    [[ ! -e $output && ! -L $output ]] || die 'Output directory already exists; use --resume or choose a new --output'
    mkdir -p "$output"
fi
build_start
exec > >(tee -a "$output/build.log") 2>&1
printf '===== UKE BUILD RUN %s =====\n' "$UKE_BUILD_RUN_ID"
printf 'O82-36 native display: seven fixed OEM modes selected by default\n'
if [[ -z $stock ]]; then
    [[ -f $stock_archive && ! -L $stock_archive ]] || die 'Bundled OS3.0.304.0 stock boot template is missing'
    [[ $(sha256sum "$stock_archive" | cut -d' ' -f1) == d001b8d7a15d088ae24fcb90d85023bd7af2360f8fdb72cf70f4e1b8c6085f1b ]] || die 'Bundled stock boot archive hash mismatch'
    stock_dir=$(mktemp -d "$output/.stock.XXXXXXXX")
    stock=$stock_dir/boot.img
    zstd -q -dc "$stock_archive" > "$stock"
fi
[[ -f $stock && ! -L $stock ]] || die 'Stock boot.img is missing'
[[ $(sha256sum "$stock" | cut -d' ' -f1) == 1eaf4858a7c70bee9b663b485f3192b164738bbdae3edbb986a5419621c8ef30 ]] || die 'Unexpected stock boot.img'
if ((cross_kernel)); then
    [[ $(uname -m) == x86_64 ]] || die '--cross-kernel requires an x86_64 host'
fi
cache_dir=$here/build/cache
mkdir -p "$cache_dir/dnf" "$cache_dir/dnf-x86_64" "$cache_dir/ccache" "$cache_dir/ccache-cross"
build_stage='Prepare reusable build tools'
build_write_status
arm_image=$("$here/src/image/ensure-build-image.sh" "$container" linux/arm64)

# bash -s reads the build recipe from stdin; keep stdin attached to the container.
"$container" run --rm -i --network=host --platform linux/arm64 --security-opt label=disable \
    --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
    "${sanitizer_env[@]}" \
    -e UKE_REBUILD_KERNEL="$rebuild_kernel" -e UKE_CROSS_KERNEL="$cross_kernel" \
    -e UKE_BUILD_RUN_ID -e UKE_BUILD_OUTPUT=/build-output \
    -v "$cache_dir:/build-cache" -v "$output:/build-output" \
    -v "$workspace:/work" -w /work "$arm_image" \
    bash -s <<'BUILD_RPMS'
set -Eeuo pipefail
dnf=(dnf5 -y --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True)
export UKE_CCACHE=1 CCACHE_DIR=/build-cache/ccache CCACHE_MAXSIZE=10G
git config --global --add safe.directory /work/senemos-uke-kernel
bash uke-fedora-builder/src/image/build-control.sh stage 'Prepare source RPMs'
make -C senemos-uke-kernel srpm
make -C uke-linux-hardware-support/uke-core-meta srpm
make -C uke-linux-hardware-support/uke-sensors touchscreen-srpm
make -C uke-linux-hardware-support/uke-console-input srpm
make -C uke-linux-hardware-support/uke-platform-runtime srpm
make -C uke-linux-hardware-support/uke-boot srpm
make -C uke-linux-hardware-support/xiaomi-uke-firmware fedora44-image-data-srpm
for package in libssc iio-sensor-proxy uke-ssc-fileservice; do
    make -C uke-linux-hardware-support/uke-sensors PACKAGE="$package" srpm
done
bash uke-fedora-builder/src/image/build-control.sh done
tops=(
  senemos-uke-kernel/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-core-meta/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-sensors/build/rpmbuild
  uke-linux-hardware-support/uke-console-input/build/rpmbuild
  uke-linux-hardware-support/uke-platform-runtime/build/rpmbuild
  uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild
)
for top in "${tops[@]}"; do
    case $top in
        senemos-uke-kernel/*) component=kernel;;
        */uke-core-meta/*) component=core-meta;;
        */uke-sensors/*) component=touchscreen;;
        */uke-console-input/*) component=console-input;;
        */uke-platform-runtime/*) component=battery;;
        */uke-boot/*) component=boot-integration;;
    esac
    bash uke-fedora-builder/src/image/build-control.sh stage "RPM: $component"
    specs=("$top"/SPECS/*.spec)
    ((${#specs[@]} == 1)) && [[ -f ${specs[0]} ]] || { printf 'Expected one spec in %s\n' "$top" >&2; exit 1; }
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        rm -f -- "$top/.fedora44-cross-pending"
    fi
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild && $UKE_REBUILD_KERNEL == 0 ]] && \
       bash uke-fedora-builder/src/image/kernel-rpm-cache.sh check "$top"; then
        printf 'Reusing verified Linux 7.2.11 RPMs and boot build\n'
        bash uke-fedora-builder/src/image/build-control.sh done
        continue
    fi
    if [[ $top != senemos-uke-kernel/build/srpm/rpmbuild ]] && \
       bash uke-fedora-builder/src/image/rpm-build-cache.sh check "$top"; then
        printf 'Reusing verified RPMs from %s\n' "$top"
        bash uke-fedora-builder/src/image/build-control.sh done
        continue
    fi
    if [[ $top != senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        bash uke-fedora-builder/src/image/rpm-build-cache.sh invalidate "$top"
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
        bash "$source/boot-recipe/src/boot/make-initramfs-base.sh" "$base" 7.2.11-33
        clang++ -std=c++17 -O2 -Wall -Wextra -Werror -ffile-prefix-map="$PWD"=. \
            "$source/boot-recipe/src/boot/offline-switch-root.cpp" -o "$base/uke-offline-switch-root"
        clang++ -std=c++20 -O2 -Wall -Wextra -Werror \
            "$source/boot-recipe/src/boot/boot-image.cpp" -o "$base/boot-image-aarch64"
        for binary in uke-offline-switch-root boot-image-aarch64; do
            readelf -h "$base/$binary" | grep -E 'Machine:.*AArch64' >/dev/null
        done
        printf '7.2.11-33\n' > "$top/.fedora44-cross-pending"
        continue
    fi
    rpmbuild -ba --target aarch64 --define "_topdir /work/$top" "${specs[0]}"
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        # RPM removes BUILD after -ba; restore the verified source needed by
        # the cache receipt and the per-profile boot image builds.
        rpmbuild -bp --nodeps --target aarch64 --define "_topdir /work/$top" "${specs[0]}"
        bash uke-fedora-builder/src/image/kernel-rpm-cache.sh record "$top"
    else
        bash uke-fedora-builder/src/image/rpm-build-cache.sh record "$top"
    fi
    bash uke-fedora-builder/src/image/build-control.sh done
done
sensor_root=uke-linux-hardware-support/uke-sensors/build/srpm
for package in libssc iio-sensor-proxy uke-ssc-fileservice; do
    bash uke-fedora-builder/src/image/build-control.sh stage "RPM: $package"
    top=$sensor_root/$package/rpmbuild
    spec=$top/SPECS/$package.spec
    dependencies=()
    if [[ $package == iio-sensor-proxy ]]; then
        dependencies=("$sensor_root/libssc/rpmbuild/RPMS/aarch64/"libssc{,-devel}-0.4.4-*.fc44.aarch64.rpm)
    fi
    if bash uke-fedora-builder/src/image/rpm-build-cache.sh check "$top" "${dependencies[@]}"; then
        printf 'Reusing verified RPMs from %s\n' "$top"
    else
        bash uke-fedora-builder/src/image/rpm-build-cache.sh invalidate "$top"
        "${dnf[@]}" builddep "$spec"
        rpmbuild -ba --target aarch64 --define "_topdir /work/$top" "$spec"
        bash uke-fedora-builder/src/image/rpm-build-cache.sh record "$top" "${dependencies[@]}"
    fi
    if [[ $package == libssc ]]; then
        "${dnf[@]}" install \
            "$top"/RPMS/aarch64/libssc-0.4.4-*.fc44.aarch64.rpm \
            "$top"/RPMS/aarch64/libssc-devel-0.4.4-*.fc44.aarch64.rpm
    fi
    bash uke-fedora-builder/src/image/build-control.sh done
done
top=uke-linux-hardware-support/xiaomi-uke-firmware/build/fedora44-image-data/rpmbuild
bash uke-fedora-builder/src/image/build-control.sh stage 'RPM: OEM data'
oem_rpm="$top/RPMS/noarch/uke-fedora44-oem-data-3.0.304.0-2.fc44.noarch.rpm"
if bash uke-fedora-builder/src/image/rpm-build-cache.sh check "$top" && \
   bash uke-fedora-builder/src/image/verify-fedora44-oem-rpm.sh "$oem_rpm"; then
    printf 'Reusing verified RPMs from %s\n' "$top"
else
    bash uke-fedora-builder/src/image/rpm-build-cache.sh invalidate "$top"
    rpmbuild -ba --target noarch --define "_topdir /work/$top" \
        "$top/SPECS/uke-fedora44-oem-data.spec"
    bash uke-fedora-builder/src/image/verify-fedora44-oem-rpm.sh "$oem_rpm"
    bash uke-fedora-builder/src/image/rpm-build-cache.sh record "$top"
fi
bash uke-fedora-builder/src/image/build-control.sh done
BUILD_RPMS

kernel_top=$workspace/senemos-uke-kernel/build/srpm/rpmbuild
if [[ -f $kernel_top/.fedora44-cross-pending ]]; then
    # The deferred cross build completes the kernel RPM stage started above.
    build_completed=$(jq -r .completed "$output/status.json")
    build_stage='RPM: kernel (cross-compile and package)'
    build_write_status
    amd_image=$("$here/src/image/ensure-build-image.sh" "$container" linux/amd64)
    "$container" run --rm -i --network=host --platform linux/amd64 --security-opt label=disable \
        --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
        -v "$cache_dir:/build-cache" -v "$workspace:/work" -w /work \
        "$amd_image" bash -s <<'CROSS_KERNEL'
set -Eeuo pipefail
top=/work/senemos-uke-kernel/build/srpm/rpmbuild
source=$top/BUILD/senemos-uke-linux-kernel-mainline-7.2.11-build/linux-7.2.11
[[ $(cat "$top/.fedora44-cross-pending") == 7.2.11-33 ]] || exit 2
export UKE_CROSS_KERNEL=1 UKE_CCACHE=1 CCACHE_DIR=/build-cache/ccache-cross CCACHE_MAXSIZE=10G
export KBUILD_BUILD_USER=senemos KBUILD_BUILD_HOST=copr-builder KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1791725270
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')
export KBUILD_BUILD_TIMESTAMP
bash "$source/boot-recipe/src/boot/build-payload.sh" "$source" \
    "$top/native-kernel-out" "$top/boot-userspace/base" 7.2.11-33 8
CROSS_KERNEL

    "$container" run --rm -i --network=host --platform linux/arm64 --security-opt label=disable \
        --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
        "${sanitizer_env[@]}" \
        -v "$cache_dir:/build-cache" -v "$workspace:/work" -w /work \
        "$arm_image" bash -s <<'PACKAGE_KERNEL'
set -Eeuo pipefail
dnf=(dnf5 -y --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True)
top=/work/senemos-uke-kernel/build/srpm/rpmbuild
spec=$top/SPECS/senemos-uke-linux-kernel-mainline.spec
"${dnf[@]}" builddep "$spec"
UKE_PREBUILT_KERNEL=1 rpmbuild -ba --target aarch64 --define "_topdir $top" "$spec"
rpmbuild -bp --nodeps --target aarch64 --define "_topdir $top" "$spec"
bash /work/uke-fedora-builder/src/image/kernel-rpm-cache.sh record "$top"
rm -f -- "$top/.fedora44-cross-pending"
PACKAGE_KERNEL
    build_progress_done
fi

[[ -d $kernel_top/BUILD ]] || die 'Kernel RPM build did not create its BUILD directory'
kernel_rpms=$output/kernel-rpms
[[ ! -L $kernel_rpms ]] || die 'Kernel RPM staging directory is a symlink'
mkdir -p "$kernel_rpms"
find "$kernel_rpms" -maxdepth 1 -type f -name 'senemos-uke-linux-kernel-mainline*.rpm' -delete
for part in core modules dtbs; do
    rpm=$kernel_top/RPMS/aarch64/senemos-uke-linux-kernel-mainline-$part-7.2.11-33.fc44.aarch64.rpm
    [[ -s $rpm && ! -L $rpm ]] || die "Missing matched kernel RPM: $rpm"
    cp --reflink=auto -- "$rpm" "$kernel_rpms/"
done
kernel_out=$kernel_top/native-kernel-out
if [[ -s $kernel_out/cross-source.sha256 ]]; then
    amd_image=${amd_image:-$("$here/src/image/ensure-build-image.sh" "$container" linux/amd64)}
fi
arm_image_id=$("$container" image inspect "$arm_image" --format '{{.Id}}')
amd_image_id=none
[[ -z ${amd_image:-} ]] || amd_image_id=$("$container" image inspect "$amd_image" --format '{{.Id}}')
native_image=$(bash "$here/src/image/ensure-hwdb-image.sh" "$container")
native_image_id=$("$container" image inspect "$native_image" --format '{{.Id}}')
guard=$(find "$kernel_top/BUILD" -type f \
  -path '*/linux-7.2.11/boot-recipe/src/boot/dracut/root-guard.sh' -print -quit)
[[ -n $guard ]] || die 'Prepared kernel source was not found'
kernel_source=${guard%/boot-recipe/src/boot/dracut/root-guard.sh}
core_rpm=$workspace/uke-linux-hardware-support/uke-core-meta/build/srpm/rpmbuild/RPMS/aarch64/uke-core-meta-1.0.4-1.fc44.aarch64.rpm
hardware_rpms=$output/hardware-rpms
mkdir -p "$hardware_rpms"
find "$hardware_rpms" -maxdepth 1 -type f -name '*.rpm' -delete
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/rpmbuild/RPMS/aarch64/uke-touchscreen-0.1.0-17.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-console-input/build/rpmbuild/RPMS/aarch64/uke-console-input-3.6.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-platform-runtime/build/rpmbuild/RPMS/aarch64/uke-battery-observer-1.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild/RPMS/aarch64/uke-boot-integration-1.5.2-2.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/libssc/rpmbuild/RPMS/aarch64/libssc-0.4.4-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/iio-sensor-proxy/rpmbuild/RPMS/aarch64/iio-sensor-proxy-3.9-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/uke-ssc-fileservice/rpmbuild/RPMS/aarch64/uke-ssc-fileservice-2026.09.21-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/xiaomi-uke-firmware/build/fedora44-image-data/rpmbuild/RPMS/noarch/uke-fedora44-oem-data-3.0.304.0-2.fc44.noarch.rpm "$hardware_rpms/"

blobs=$workspace/uke-linux-hardware-support/xiaomi-uke-firmware/payload/oem-os3.0.304.0
input_hash=$(
  {
    printf '%s\n' "${UKE_FEDORA_MIRROR:-https://mirror.yandex.ru/fedora/linux}"
    printf '%s\n' "$arm_image_id" "$amd_image_id" "$native_image_id" "$touch_panel"
    sha256sum "$stock" "$kernel_out/.config" "$kernel_out/boot-initramfs.cpio.gz" \
        "$kernel_out/boot-manifest" "$kernel_out/arch/arm64/boot/Image" \
        "$here/build-fedora44-rootfs.sh" "$here/build-fedora44-boot-a.sh" \
        "$here/src/image/ensure-hwdb-image.sh" \
        "$here/src/image/finalize-fedora44-rootfs.sh" \
        "$here/src/image/ensure-build-image.sh" \
        "$here/src/image/prepare-tool-image.sh" \
        "$here/src/image/assemble-pair-from-tty.sh" \
        "$here/src/image/ext4-labels.cpp" "$here/src/boot-pair/android-sparse.cpp" \
        "$here/src/boot/boot-image.cpp" "$here/configs/firstboot/uke-create-user" \
        "$here/configs/firstboot/uke-create-user.service" \
        "$here/configs/images/uke-persist.fstab" "$here/configs/images/uke-ssc-fedora44.target" \
        "$blobs/touch/$touch_panel/normal.bin" "$blobs/touch/$touch_panel/config.ini" \
        "$blobs/touch/reference.bin" "$core_rpm" "$kernel_rpms"/*.rpm "$hardware_rpms"/*.rpm | \
        awk '{print $1}'
  } | sha256sum | cut -d' ' -f1
)
reuse_profiles=$resume
printf '%s\n' "$input_hash" > "$output/BUILD-INPUTS.sha256"
append_build_receipt() {
    local stage=$1 checksum_file
    [[ -d $stage && ! -L $stage && -f $stage/SHA256SUMS && ! -L $stage/SHA256SUMS ]] || die "Invalid profile stage: $stage"
    (cd "$stage" && sha256sum -c --status SHA256SUMS) || die "Invalid checksums in $stage"
    printf '%s\n' "$input_hash" > "$stage/BUILD-INPUTS.sha256"
    checksum_file=$(mktemp "$stage/.SHA256SUMS.XXXXXXXX")
    (cd "$stage" && awk '$2 != "BUILD-INPUTS.sha256"' SHA256SUMS > "$checksum_file" && \
        sha256sum BUILD-INPUTS.sha256 >> "$checksum_file")
    chmod 0644 "$checksum_file"
    mv -f -- "$checksum_file" "$stage/SHA256SUMS"
}
clear_profile_dir() {
    local path=$1 name=${1##*/}
    [[ $path == "$output/$name" && $name =~ ^\.(tty|kde|gnome|phosh|plasma-mobile)-(rootfs|pair)\.[0-9a-f-]+$ || \
       $path == "$output/$name" && $name =~ ^(tty|kde|gnome|phosh|plasma-mobile)-(rootfs|pair)$ ]] \
        || die "Unsafe profile path: $path"
    [[ ! -L $path ]] || die "Refusing symlink: $path"
    [[ -e $path ]] || return 0
    "$container" run --rm --network=none --security-opt label=disable \
        --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
        -v "$output:/build-output" registry.fedoraproject.org/fedora:44 \
        /usr/bin/rm -rf -- "/build-output/$name"
    [[ ! -e $path ]] || die "Could not clear $path"
}
for stale in "$output"/.*-rootfs.* "$output"/.*-pair.*; do
    [[ -e $stale ]] || continue
    clear_profile_dir "$stale"
done
for profile in "${build_profiles[@]}"; do
    root_mib=4096
    [[ $profile == tty ]] || root_mib=8192
    root_dir=$output/$profile-rootfs
    pair_dir=$output/$profile-pair
    build_progress "$profile rootfs"
    root_reused=0
    if ((reuse_profiles)) && profile_valid "$root_dir" "$profile" && \
       [[ $(cat "$root_dir/ROOT-MIB") == "$root_mib" ]]; then
        root_reused=1
        printf 'Reusing verified %s rootfs\n' "$profile"
    else
        clear_profile_dir "$root_dir"
        stage=$output/.$profile-rootfs.$UKE_BUILD_RUN_ID
        clear_profile_dir "$stage"
        base_args=()
        [[ $profile == tty ]] || base_args=(--base-rootfs "$output/tty-rootfs")
        "$here/build-fedora44-rootfs.sh" \
            --profile "$profile" --kernel-rpms "$kernel_rpms" \
            --core-rpm "$core_rpm" --hardware-rpms "$hardware_rpms" \
            --root-mib "$root_mib" --touch-panel "$touch_panel" "${base_args[@]}" --output "$stage"
        append_build_receipt "$stage"
        profile_valid "$stage" "$profile" || die "Incomplete $profile rootfs"
        mv -- "$stage" "$root_dir"
    fi
    build_progress_done
    build_progress "$profile boot pair"
    if ((root_reused && reuse_profiles)) && profile_valid "$pair_dir" "$profile"; then
        printf 'Reusing verified %s boot pair\n' "$profile"
    else
        clear_profile_dir "$pair_dir"
        stage=$output/.$profile-pair.$UKE_BUILD_RUN_ID
        clear_profile_dir "$stage"
        if [[ $profile == tty ]]; then
            "$here/build-fedora44-boot-a.sh" \
                --rootfs "$root_dir" --kernel-source "$kernel_source" \
                --kernel-out "$kernel_out" --stock-boot "$stock" \
                --output "$stage"
        else
            "$here/src/image/assemble-pair-from-tty.sh" "$output/tty-pair" "$root_dir" "$stage"
        fi
        append_build_receipt "$stage"
        profile_valid "$stage" "$profile" || die "Incomplete $profile pair"
        mv -- "$stage" "$pair_dir"
    fi
    build_progress_done
done
build_progress 'Audit release outputs'
audit_final
build_progress_done
printf 'Requested profiles: %s\n' "${requested_profiles[*]}"
printf 'Built or reused image pairs: %s\n' "${build_profiles[*]}"
printf 'O82-36 native display: seven fixed OEM modes by default\n'
printf 'Image pairs are in %s\n' "$output"
