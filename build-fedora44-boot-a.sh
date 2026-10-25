#!/usr/bin/env bash
# Fedora 44 boot_a composition. This script never accesses a device.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'fedora44-boot-a: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: ./build-fedora44-boot-a.sh --rootfs DIR --kernel-source DIR \
       --kernel-out DIR --stock-boot FILE --output NEW_DIR [--jobs N]
       [--native-o82-36 | --native-o82-36-rates]

Rebuild the RPM kernel Image with a userdata initramfs, then pack an OEM-derived
Android v4 boot_a image with an unsigned AVB hash footer. Requires the prepared
Linux 7.2.11 RPM source/output and a reviewed OEM boot.img. Uses Docker or
Podman for the AArch64 kernel build; neither mode writes a device.
--native-o82-36 enables an experimental 60 Hz DPU/DSI path for O82-36 panels.
--native-o82-36-rates adds the separate fixed 60/120 Hz O82-36 trial graph.
HELP
}

if [[ ${1:-} == --inside ]]; then
    [[ $# == 1 && -d /kernel-source && -d /kernel-out && -d /workspace ]] || die 'Invalid container invocation'
    case $(cat /workspace/BUILD-PLATFORM) in
        linux/arm64) ccache_cache=ccache;;
        linux/amd64) ccache_cache=ccache-cross;;
        *) die 'Unknown kernel build platform';;
    esac
    original=/kernel-out
    output=/workspace/kernel-out
    [[ -s $original/.config && -s $original/boot-initramfs.cpio.gz && -s $original/Module.symvers ]] || die 'Incomplete native kernel output'
    [[ -f /kernel-source/boot-recipe/src/boot/dracut/root-guard.sh ]] || die 'Prepared kernel boot recipe missing'
    release=$(cat /workspace/KERNEL-RELEASE)
    [[ $release =~ ^7\.2\.11-[1-9][0-9]*$ ]] || die 'Expected Linux 7.2.11 kernel release'
    mkdir "$output" /workspace/initramfs-root
    cp -a "$original/." "$output/"
    [[ -L $output/source ]] || die 'Native kernel output source link missing'
    ln -sfnT /kernel-source "$output/source"
    (cd /workspace/initramfs-root; gzip -cd "$original/boot-initramfs.cpio.gz" | cpio -idm --quiet --no-absolute-filenames)
    guard=/workspace/initramfs-root/usr/libexec/uke-root-guard
    [[ -f $guard && ! -L $guard ]] || die 'Initramfs root guard missing'
    cmp "$guard" /kernel-source/boot-recipe/src/boot/dracut/root-guard.sh || die 'Unrecognized initramfs root guard'
    sed -i \
        -e 's|selected=/dev/disk/by-partlabel/linux|selected=/dev/disk/by-partlabel/userdata|' \
        -e 's/\[ "$name" = linux \]/[ "$name" = userdata ]/' \
        -e 's/physical linux partition/physical userdata partition/g' \
        -e 's/multiple linux partitions/multiple userdata partitions/g' \
        -e 's/matching linux partition/matching userdata partition/g' "$guard"
    grep -F 'selected=/dev/disk/by-partlabel/userdata' "$guard" >/dev/null || die 'Root guard selector unchanged'
    grep -F '[ "$name" = userdata ]' "$guard" >/dev/null || die 'Root guard partition check unchanged'
    if grep -E 'by-partlabel/linux|"\$name" = linux' "$guard"; then die 'Old root guard selector survived'; fi
    cmdline_dir=/workspace/initramfs-root/etc/cmdline.d
    [[ -d $cmdline_dir ]] || die 'Initramfs command-line directory missing'
    mapfile -d '' -t cmdline_files < <(find "$cmdline_dir" -type f -print0)
    ((${#cmdline_files[@]} > 0)) || die 'No initramfs command-line files'
    grep -lF 'root=PARTLABEL=linux' "${cmdline_files[@]}" >/dev/null || die 'Original initramfs root selector missing'
    sed -i -e 's/root=PARTLABEL=linux/root=PARTLABEL=userdata/g' \
        -e 's/ systemd\.unit=multi-user\.target//g' "${cmdline_files[@]}"
    if grep -rF 'root=PARTLABEL=linux' "$cmdline_dir"; then die 'Old initramfs selector survived'; fi
    if grep -rF 'systemd.unit=multi-user.target' "$cmdline_dir"; then die 'Forced console target survived in initramfs'; fi
    find /workspace/initramfs-root -exec touch -h -d '@1791725270' {} +
    (cd /workspace/initramfs-root; find . -print0 | LC_ALL=C sort -z | cpio --null --quiet --reproducible --owner=0:0 -o -H newc) | gzip -n -9 > /workspace/boot-initramfs.cpio.gz
    original_cmdline=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$original/.config")
    [[ $original_cmdline == *'root=PARTLABEL=linux '* ]] || die 'Unexpected original kernel command line'
    new_cmdline=${original_cmdline/root=PARTLABEL=linux/root=PARTLABEL=userdata}
    # A shared boot image must honor each rootfs default.target. Otherwise GUI
    # images stay at multi-user.target without a display manager or tty1 getty.
    new_cmdline=${new_cmdline/ systemd.unit=multi-user.target/}
    if [[ $(cat /workspace/NATIVE-O82-36) == 1 ]]; then
        new_cmdline+=' uke.native_o82_36=1'
    fi
    if [[ $(cat /workspace/NATIVE-O82-36-RATES) == 1 ]]; then
        [[ $(cat /workspace/NATIVE-O82-36) == 1 ]] || die 'Refresh trial needs native O82-36'
        new_cmdline+=' uke.native_o82_36_rates=1'
    fi
    [[ " $new_cmdline " != *' systemd.unit='* ]] || die 'Forced host target survived in boot command line'
    cp "$original/.config" "$output/.config"
    /kernel-source/scripts/config --file "$output/.config" \
        --set-str CMDLINE "$new_cmdline" \
        --set-str INITRAMFS_SOURCE /workspace/boot-initramfs.cpio.gz
    export ARCH=arm64 LLVM=1 LLVM_IAS=1 KBUILD_BUILD_USER=senemos KBUILD_BUILD_HOST=copr-builder KBUILD_BUILD_VERSION=1
    export CCACHE_DIR=/build-cache/$ccache_cache CCACHE_MAXSIZE=10G
    compiler_args=(CC='ccache clang' HOSTCC='ccache gcc' HOSTCXX='ccache g++')
    export SOURCE_DATE_EPOCH=1791725270
    KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')
    export KBUILD_BUILD_TIMESTAMP
    localversion=-${release#*-}
    make -C /kernel-source O="$output" LOCALVERSION="$localversion" "${compiler_args[@]}" olddefconfig
    [[ $(make -s -C /kernel-source O="$output" LOCALVERSION="$localversion" "${compiler_args[@]}" kernelrelease) == "$release" ]] || die 'Kernel release changed'
    grep -Fx 'CONFIG_INITRAMFS_FORCE=y' "$output/.config" >/dev/null
    grep -Fx 'CONFIG_CMDLINE_FORCE=y' "$output/.config" >/dev/null
    grep -Fx "CONFIG_CMDLINE=\"$new_cmdline\"" "$output/.config" >/dev/null
    jobs=$(cat /workspace/JOBS)
    make -C /kernel-source O="$output" LOCALVERSION="$localversion" "${compiler_args[@]}" -j"$jobs" Image
    cmp "$original/Module.symvers" "$output/Module.symvers" || die 'Kernel module export ABI changed'
    install -m644 "$output/arch/arm64/boot/Image" /workspace/Image
    install -m644 "$output/.config" /workspace/boot.config
    install -m644 "$output/Module.symvers" /workspace/Module.symvers
    exit 0
fi

rootfs='' source='' kernel_out='' stock='' output='' jobs=4 native_o82_36=0 native_o82_36_rates=0
while (($#)); do
    case $1 in
        --rootfs|--kernel-source|--kernel-out|--stock-boot|--output|--jobs)
            (($# >= 2)) || die "Missing value for $1"
            case $1 in
                --rootfs) rootfs=$2;; --kernel-source) source=$2;; --kernel-out) kernel_out=$2;;
                --stock-boot) stock=$2;; --output) output=$2;; --jobs) jobs=$2;;
            esac
            shift 2;;
        --help|-h) usage; exit 0;;
        --native-o82-36) native_o82_36=1; shift;;
        --native-o82-36-rates) native_o82_36=1; native_o82_36_rates=1; shift;;
        *) die "Unknown argument: $1";;
    esac
done
[[ -d $rootfs && -d $source && -d $kernel_out && -f $stock && -n $output ]] || die 'Provide all input paths and an output directory'
[[ $jobs =~ ^[1-9][0-9]*$ && $jobs -le 16 ]] || die 'Jobs must be 1..16'
rootfs=$(realpath -- "$rootfs")
source=$(realpath -- "$source")
kernel_out=$(realpath -- "$kernel_out")
stock=$(realpath -- "$stock")
output=$(realpath -m -- "$output")
[[ ! -e $output && ! -L $output ]] || die 'Output directory already exists'
[[ -s $rootfs/userdata.img && -s $rootfs/userdata.raw.img && -s $rootfs/SHA256SUMS ]] || die 'Incomplete Fedora 44 rootfs'
(cd "$rootfs"; sha256sum -c SHA256SUMS) || die 'Rootfs checksums failed'
[[ -s $source/boot-recipe/src/boot/dracut/root-guard.sh && -s $kernel_out/.config && -s $kernel_out/boot-initramfs.cpio.gz ]] || die 'Incomplete prepared Linux 7.2.11 build'
release=$(sed -n 's/^kernel_release=//p' "$kernel_out/boot-manifest")
[[ $release =~ ^7\.2\.11-[1-9][0-9]*$ ]] || die 'Cannot derive native kernel release'
[[ $(cat "$kernel_out/include/config/kernel.release") == "$release" ]] || die 'Native output release mismatch'
expected_image=$(sed -n 's/^linux_kernel_sha256=//p' "$kernel_out/boot-manifest")
[[ $expected_image =~ ^[a-f0-9]{64}$ ]] || die 'Native Image digest missing'
[[ $(sha256sum "$kernel_out/arch/arm64/boot/Image" | cut -d ' ' -f1) == "$expected_image" ]] || die 'Native Image does not match boot manifest'
[[ $(stat -c %s "$stock") == 100663296 ]] || die 'Unexpected OEM boot partition size'
stock_hash=$(sha256sum "$stock" | cut -d ' ' -f1)
[[ $stock_hash == 1eaf4858a7c70bee9b663b485f3192b164738bbdae3edbb986a5419621c8ef30 ]] || die 'Use the reviewed OS3.0.304.0.WOZMIXM OEM boot.img'
stock_avb=$(avbtool info_image --image "$stock") || die 'OEM boot AVB metadata is invalid'
rollback=$(sed -n 's/^Rollback Index:[[:space:]]*//p' <<< "$stock_avb")
[[ $rollback =~ ^[0-9]+$ ]] || die 'OEM rollback index missing'
stock_props=()
while IFS= read -r property; do stock_props+=(--prop "$property"); done < <(
    sed -nE "s/^[[:space:]]*Prop: ([A-Za-z0-9_.-]+) -> '(.*)'$/\1:\2/p" <<< "$stock_avb"
)
[[ " ${stock_props[*]} " == *'com.android.build.boot.os_version:'* ]] || die 'OEM boot version property missing'
if command -v podman >/dev/null; then container=podman
elif command -v docker >/dev/null; then container=docker
else die 'Docker or Podman is required for the AArch64 kernel build'; fi
for command in avbtool g++ jq sha256sum; do
    command -v "$command" >/dev/null || die "Missing host command: $command"
done
mkdir -p "$output"
cache_dir=$here/build/cache
mkdir -p "$cache_dir/dnf" "$cache_dir/dnf-x86_64" "$cache_dir/ccache" "$cache_dir/ccache-cross"
build_platform=linux/arm64
if [[ -s $kernel_out/cross-source.sha256 ]]; then
    (cd "$source"; sha256sum -c "$kernel_out/cross-source.sha256") || die 'Cross kernel source receipt failed'
    build_platform=linux/amd64
fi
trap 'printf "fedora44-boot-a: incomplete output retained at %s\n" "$output" >&2' ERR
printf '%s\n' "$release" > "$output/KERNEL-RELEASE"
printf '%s\n' "$jobs" > "$output/JOBS"
printf '%s\n' "$native_o82_36" > "$output/NATIVE-O82-36"
printf '%s\n' "$native_o82_36_rates" > "$output/NATIVE-O82-36-RATES"
printf '%s\n' "$build_platform" > "$output/BUILD-PLATFORM"
run_label=()
[[ -z ${UKE_BUILD_RUN_ID:-} ]] || run_label=(--label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID")
build_image=$("$here/src/image/ensure-build-image.sh" "$container" "$build_platform")
"$container" run --rm --network=host --platform "$build_platform" --security-opt label=disable \
    "${run_label[@]}" \
    -v "$source:/kernel-source:ro" -v "$kernel_out:/kernel-out:ro" -v "$output:/workspace" \
    -v "$cache_dir:/build-cache" \
    -v "$here/build-fedora44-boot-a.sh:/builder.sh:ro" \
    "$build_image" bash /builder.sh --inside
g++ -std=c++20 -O2 -Wall -Wextra -Werror "$here/src/boot/boot-image.cpp" -o "$output/boot-image"
"$output/boot-image" inspect "$stock" > "$output/stock-header.json"
jq -e '.header_version==4 and .ramdisk_bytes==0 and .signature_bytes==0 and .image_bytes==100663296' "$output/stock-header.json" >/dev/null || die 'Unexpected OEM boot v4 template'
"$output/boot-image" pack "$stock" "$output/Image" "$output/fedora_boot.img.part" 100663296
"$output/boot-image" inspect "$output/fedora_boot.img.part" > "$output/boot-header.json"
"$output/boot-image" extract "$output/fedora_boot.img.part" "$output/readback-Image"
cmp "$output/Image" "$output/readback-Image" || die 'Android boot kernel roundtrip failed'
truncate -s "$(jq -er .payload_end "$output/boot-header.json")" "$output/fedora_boot.img.part"
avbtool add_hash_footer --image "$output/fedora_boot.img.part" --partition_name boot \
    --partition_size 100663296 --algorithm NONE --salt "$stock_hash" \
    --rollback_index "$rollback" "${stock_props[@]}"
# avbtool resolves the boot descriptor against boot.img next to the image.
mv "$output/fedora_boot.img.part" "$output/boot.img"
avbtool verify_image --image "$output/boot.img" || die 'AVB footer verification failed'
"$output/boot-image" inspect "$output/boot.img" > "$output/boot-header.json"
jq -e '.avb_footer_present==true and .image_bytes==100663296 and .payload_end<.image_bytes' "$output/boot-header.json" >/dev/null || die 'Final boot image lacks a bounded AVB footer'
mv "$output/boot.img" "$output/fedora_boot.img"
cp --reflink=auto "$rootfs/userdata.img" "$output/userdata.img"
cp "$rootfs/PROFILE-ID" "$rootfs/TOUCH-PANEL" "$rootfs/LOCAL-BLOBS.sha256" "$output/"
jq -n --arg profile "$(cat "$rootfs/PROFILE-ID")" --arg release "$release" \
    --arg build_platform "$build_platform" \
    --argjson native_o82_36 "$native_o82_36" \
    --argjson native_o82_36_rates "$native_o82_36_rates" \
    --arg panel "$(cat "$rootfs/TOUCH-PANEL")" \
    --arg boot "$(sha256sum "$output/fedora_boot.img" | cut -d ' ' -f1)" \
    --arg userdata "$(sha256sum "$output/userdata.img" | cut -d ' ' -f1)" \
    --arg stock "$stock_hash" --argjson root_bytes "$(stat -c %s "$rootfs/userdata.raw.img")" \
    --slurpfile header "$output/boot-header.json" \
    '{schema_version:1,device:"uke",distribution:"fedora",release:"44",kernel_release:$release,
      kernel_build_platform:$build_platform,
      experimental_native_o82_36:($native_o82_36 == 1),
      experimental_native_o82_36_rates:($native_o82_36_rates == 1),
      profile:$profile,experimental_desktop:($profile=="phosh" or $profile=="plasma-mobile"),
      touch_panel:$panel,boot_partition:"boot_a",root_partition:"userdata",
      root_image_logical_bytes:$root_bytes,stock_boot_sha256:$stock,
      sha256:{boot:$boot,userdata:$userdata},header:$header[0],
      boot_tested:false,hardware_tested:false,device_write_executed:false}' > "$output/manifest.json"
(cd "$output"; sha256sum fedora_boot.img userdata.img Image boot.config Module.symvers \
    boot-initramfs.cpio.gz stock-header.json boot-header.json manifest.json PROFILE-ID \
    TOUCH-PANEL LOCAL-BLOBS.sha256 BUILD-PLATFORM NATIVE-O82-36 \
    NATIVE-O82-36-RATES > SHA256SUMS)
printf 'Image pair: %s/fedora_boot.img and %s/userdata.img\n' "$output" "$output"
