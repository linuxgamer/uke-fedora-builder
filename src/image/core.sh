#!/usr/bin/env bash
# Sourced by the workspace build.sh entry. No live block devices are used.
set -Eeuo pipefail
BUILDER=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=host-lib.sh
# shellcheck disable=SC1091
source "$BUILDER/src/image/host-lib.sh"
say() { printf 'ukelinux: %s\n' "$*"; }
die() { printf 'ukelinux: ERROR: %s\n' "$*" >&2; exit 1; }
help() {
    cat <<'HELP'
Senemos Uke Fedora Core filesystem builder (host only)
Usage: ./build.sh core --distro=fedora [options]
       ./build.sh boot --distro=fedora --help
       ./build.sh boot-pair --distro=fedora --help
       ./build.sh check-device --pair DIRECTORY [--offline] [--report FILE]
  --release rawhide  Reviewed first target (default)
  --jobs N           At most two CPUs; defaults to two
  --esp-size N       ESP filesystem size in MiB (default 256; minimum 128)
  --linux-size N     Linux filesystem size in MiB (default 4096; minimum 4096)
  --fat-sector N     ESP sector bytes: 512 or 4096 (default 512)
  --offline          Require exact cached packages and container toolchain
  --dry-run          Show the profile without installing or building
  --self-test        Check CLI, profiles and host privacy fixtures
  --test             All filesystem, payload, label and byte-match checks always run
  --help, -h         Show this help

Produces separate logical EXT4 Linux and FAT32 ESP candidate files, plus a UKI.
The explicit Core debug profile opens a local root development shell on VT2;
ESP32-S3 HID input and CDC journal output still require physical validation.
No passwords, network root login, flashing or default boot activation are added.
Targets existing fastboot partitions esp and linux; no fixed disk offsets.
USB/UFS DT, firmware handoff and target capacity/visibility are release gates.
HELP
}
cleanup() {
    if [[ -n ${CID:-} ]]; then
        ((PAUSED == 0)) || "$ENGINE" unpause "$CID" >/dev/null 2>&1 || true
        "$ENGINE" rm -f "$CID" >/dev/null 2>&1 || true
    fi
}
image_job() {
    local image=$1 platform=$2 log=$3 output_owner=none; shift 3
    if [[ $ENGINE == docker ]] && ! "$ENGINE" info --format '{{json .SecurityOptions}}' | jq -e 'any(.[]; contains("rootless"))' >/dev/null; then
        output_owner=$(id -u):$(id -g)
    fi
    wait_idle
    CID=$("$ENGINE" create --network=none --security-opt label=disable --cpus="$JOBS" --memory=3g \
        --platform="$platform" -v "${RECIPE_ROOT:-$BUILDER}:/builder:ro" -v "$BUILDER/build:/builder/build" \
        "$image" bash /builder/src/image/container-stage.sh "/builder/build/images/${WORK##*/}" "$output_owner" "$@")
    "$ENGINE" start "$CID" >/dev/null
    while [[ $("$ENGINE" inspect --format '{{or .State.Running .State.Paused}}' "$CID") == true ]]; do
        if heavy_busy; then
            if ((PAUSED == 0)); then "$ENGINE" pause "$CID" >/dev/null; PAUSED=1; say 'Our image job is paused while another compiler uses the host'; fi
        elif ((PAUSED)); then "$ENGINE" unpause "$CID" >/dev/null; PAUSED=0; say 'Image job resumed'; fi
        sleep 2
    done
    "$ENGINE" logs "$CID" > "$log" 2>&1
    local result
    result=$("$ENGINE" inspect --format '{{.State.ExitCode}}' "$CID")
    "$ENGINE" rm "$CID" >/dev/null; CID=''
    ((result == 0)) || die "Container stage failed ($result); inspect ${log##*/}"
}
verify_cache() {
    local file=$1 hash=$2
    [[ -s $file && $(sha256sum "$file" | cut -d ' ' -f1) == "$hash" ]] || die "Missing or corrupt pinned input: ${file##*/}"
}
recipe_hash() {
    local dir=$1
    cat "$dir/configs/Containerfile.image" "$dir/configs/images/core-rawhide.json" \
        "$dir"/src/image/*.sh "$dir"/src/image/*.cpp "$dir"/src/audit/*.sh \
        "$dir"/src/image/dracut/91uke-bringup/* \
        "$dir"/manifests/images/core-*.json "$dir"/configs/images/transactions/*.json \
        "$dir/configs/images/selinux-namespace-policy.json" "$dir/configs/images/uke-persist.fstab" "$dir/configs/build-rules.json" \
        "$dir"/configs/keys/*.asc | sha256sum | cut -d ' ' -f1
}
image_main() {
    local boot_target=0 pair_target=0 check_target=0 prior='' argument
    for argument in "$@"; do
        [[ $argument != --check-device ]] || check_target=1
        if [[ $argument == --build=boot-pair || ($prior == --build && $argument == boot-pair) ]]; then pair_target=1; fi
        if [[ $argument == --build=boot || ($prior == --build && $argument == boot) ]]; then boot_target=1; fi
        prior=$argument
    done
    if ((check_target)); then
        # shellcheck source=../device/preflight.sh
        # shellcheck disable=SC1091
        source "$BUILDER/src/device/preflight.sh"
        device_preflight_main "$@"
        return
    fi
    if ((pair_target)); then
        # shellcheck source=../boot-pair/entry.sh
        # shellcheck disable=SC1091
        source "$BUILDER/src/boot-pair/entry.sh"
        pair_main "$@"
        return
    fi
    if ((boot_target)); then
        # shellcheck source=../boot/entry.sh
        # shellcheck disable=SC1091
        source "$BUILDER/src/boot/entry.sh"
        boot_main "$@"
        return
    fi
    local target=core distro=fedora release=rawhide self=0 profile architecture host_platform base recipe tool_image tool_id inside key hash stage file url cached name
    local esp_mib=256 root_mib=4096 sector=512 effective_profile
    JOBS=2 OFFLINE=0 DRY_RUN=0 ENGINE='' CID='' PAUSED=0
    while (($#)); do
        case $1 in
            --help|-h) help; return 0;;
            --offline) OFFLINE=1;; --dry-run) DRY_RUN=1;; --self-test) self=1;; --test) :;;
            --build=*|--distro=*|--release=*|--jobs=*|--esp-size=*|--linux-size=*|--fat-sector=*) key=${1%%=*}; value=${1#*=};;
            --build|--distro|--release|--jobs|--esp-size|--linux-size|--fat-sector) key=$1; shift; (($#)) || die "Missing value for $key"; value=$1;;
            *) die "Unknown option: $1";;
        esac
        case ${key:-} in
            --build) target=$value;; --distro) distro=$value;; --release) release=$value;; --jobs) JOBS=$value;;
            --esp-size) esp_mib=$value;; --linux-size) root_mib=$value;; --fat-sector) sector=$value;;
        esac
        key=''; shift
    done
    [[ $target == core && $distro == fedora && $release == rawhide ]] || die 'Only --build core --distro=fedora --release=rawhide is admitted'
    [[ $JOBS =~ ^[1-9][0-9]{0,2}$ ]] || die 'Jobs must be a positive integer'
    ((JOBS <= 2)) || JOBS=2
    [[ $esp_mib =~ ^[1-9][0-9]{0,6}$ && $root_mib =~ ^[1-9][0-9]{0,6}$ ]] || die 'Filesystem sizes must be positive integer MiB values'
    ((esp_mib >= 128 && esp_mib <= 65536 && root_mib >= 4096 && root_mib <= 1048576)) || die 'ESP size range: 128..65536 MiB; Linux size range: 4096..1048576 MiB'
    [[ $sector == 512 || $sector == 4096 ]] || die 'FAT sector bytes must be 512 or 4096'
    [[ $sector != 4096 || $esp_mib -ge 512 ]] || die '4096-byte FAT32 sectors require an ESP of at least 512 MiB'
    profile=$BUILDER/configs/images/core-rawhide.json
    [[ -f $profile ]] || die 'Core profile is missing'
    if ((self)); then
        bash "$BUILDER/tests/image-contract.sh"
        return 0
    fi
    effective_profile=$(jq -S --argjson esp "$esp_mib" --argjson linux "$root_mib" --argjson sector "$sector" '. + {esp_size_mib:$esp,root_size_mib:$linux,fat_sector_bytes:$sector}' "$profile")
    say "Core Rawhide AArch64 candidate; Linux 7.2.9, EXT4 $root_mib MiB, FAT32 ESP $esp_mib MiB ($sector-byte sectors); at most $JOBS CPUs"
    say 'ESP32 USB device / tablet USB host; HID VT2 shell and one CDC journal writer'
    say 'fastboot targets esp/linux; filesystem labels UKE_ESP/UKE_LINUX; target sizes and firmware visibility require verification'
    say 'Local filesystem checks only; boot, USB/UFS and firmware handoff are unverified'
    ((DRY_RUN == 0)) || return 0
    bootstrap
    ((EUID != 0)) || die 'Run the build as a normal user; elevation is limited to host prerequisite preparation'
    architecture=$(uname -m)
    case $architecture in x86_64) host_platform=linux/amd64;; aarch64) host_platform=linux/arm64;; *) die 'Supported image hosts: x86_64 and AArch64';; esac
    mkdir -p "$BUILDER/build/images/rpm-cache"
    exec 9> "$BUILDER/build/ukelinux-build.lock"
    if ! flock -n 9; then say 'Queued behind another image invocation'; flock 9; fi
    wait_idle
    local available
    available=$(df -Pk "$BUILDER/build" | awk 'NR==2 {print $4}')
    ((available >= (root_mib + esp_mib + 8192) * 1024)) || die 'Insufficient free space for the selected filesystem sizes and 8 GiB assembly allowance'
    local source_recipe
    source_recipe=$(recipe_hash "$BUILDER")
    recipe=$(printf '%s\n%s\n' "$source_recipe" "$effective_profile" | sha256sum | cut -d ' ' -f1)
    name=core-rawhide-${recipe:0:16}
    WORK=$BUILDER/build/images/$name; inside=/builder/build/images/$name
    mkdir -p "$WORK/inputs"; trap cleanup EXIT
    # Freeze public inputs before a queued container starts; concurrent source
    # edits cannot silently change the bytes identified by this recipe.
    RECIPE_ROOT=$WORK/recipe
    if [[ ! -d $RECIPE_ROOT ]]; then
        mkdir "$RECIPE_ROOT"
        cp -a "$BUILDER/src" "$BUILDER/configs" "$BUILDER/manifests" "$RECIPE_ROOT/"
    fi
    [[ $(recipe_hash "$RECIPE_ROOT") == "$source_recipe" ]] || die 'Source changed while freezing the recipe'
    printf '%s\n' "$effective_profile" > "$WORK/profile.json"
    for stage in runtime system identity; do
        mkdir -p "$WORK/inputs/$stage/packages"
        cp "$BUILDER/configs/images/transactions/$stage.json" "$WORK/inputs/$stage/transaction.json"
    done
    mkdir -p "$WORK/inputs/boot/packages"
    cp "$BUILDER/configs/keys/fedora-46.asc" "$WORK/inputs/fedora-key.asc"
    cp "$BUILDER/configs/keys/uke-copr.asc" "$WORK/inputs/copr-key.asc"
    for key in fedora copr; do
        hash=$(gpg --batch --show-keys --with-colons "$WORK/inputs/$key-key.asc" 2>/dev/null | awk -F: '$1=="fpr" {print $10;exit}')
        case $key:$hash in fedora:D924B10D3E810DABDD8B56B596E7E91491211FCE|copr:DAFC3C5A881FB49C7167EE2D6F772E3D487BD13E) :;; *) die 'Unexpected package signing key';; esac
    done
    while IFS=$'\t' read -r stage file url hash; do
        [[ $stage == runtime || $stage == system || $stage == identity || $stage == boot ]]
        [[ $file =~ ^[A-Za-z0-9+_.~-]+\.rpm$ && $hash =~ ^[a-f0-9]{64}$ ]]
        [[ $url == https://kojipkgs.fedoraproject.org/packages/* || $url == https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test/* ]]
        cached=$BUILDER/build/images/rpm-cache/$file
        if [[ ! -s $cached ]]; then
            ((OFFLINE == 0)) || die "Offline package is missing: $file"
            curl -fL --retry 3 --connect-timeout 20 "$url" -o "$cached.part" > "$WORK/download.log" 2>&1
            verify_cache "$cached.part" "$hash"; mv "$cached.part" "$cached"
        fi
        verify_cache "$cached" "$hash"
        cp --reflink=auto "$cached" "$WORK/inputs/$stage/packages/$file"
    done < <(jq -r '.packages[] | [.stage,.file,.url,.sha256] | @tsv' "$BUILDER"/manifests/images/core-*.json)
    base=$(jq -er '.runtime_base_image' "$profile")
    if ! "$ENGINE" image inspect "$base" >/dev/null 2>&1; then
        ((OFFLINE == 0)) || die 'Offline immutable Fedora runtime base is missing'
        "$ENGINE" pull --platform=linux/arm64 "$base" > "$WORK/pull-runtime.log" 2>&1
    fi
    TEST_IMAGE=$base
    prepare_aarch64
    local container_recipe
    container_recipe=$(sha256sum "$BUILDER/configs/Containerfile.image" | cut -d ' ' -f1)
    tool_image=localhost/senemos-uke-image-host:$architecture-${container_recipe:0:16}
    if ! "$ENGINE" image inspect "$tool_image" >/dev/null 2>&1; then
        ((OFFLINE == 0)) || die 'Offline image host toolchain is missing'
        base=$(jq -er --arg arch "$architecture" '.fedora_rawhide_images[$arch]' "$BUILDER/configs/build-rules.json")
        wait_idle
        "$ENGINE" build --cpu-period=100000 --cpu-quota="$((JOBS * 100000))" --memory=3g \
            --build-arg "BASE_IMAGE=$base" --build-arg "RECIPE_SHA=$container_recipe" \
            -t "$tool_image" -f "$BUILDER/configs/Containerfile.image" "$BUILDER/configs" > "$WORK/host-tools.log" 2>&1
    fi
    tool_id=$("$ENGINE" image inspect "$tool_image" --format '{{.Id}}')
    local preparation_key prepared_cache
    preparation_key=$(cat "$RECIPE_ROOT/src/image/prepare-runtime.sh" "$RECIPE_ROOT/src/image/prepare-root.sh" \
        "$RECIPE_ROOT"/src/image/dracut/91uke-bringup/* \
        "$RECIPE_ROOT/configs/images/core-rawhide.json" "$RECIPE_ROOT"/manifests/images/core-*.json \
        "$RECIPE_ROOT"/configs/images/transactions/*.json "$RECIPE_ROOT"/configs/keys/*.asc | sha256sum | cut -d ' ' -f1)
    prepared_cache=$BUILDER/build/images/prepared/$preparation_key
    if [[ ! -s $WORK/prepared-root.tar && -s $prepared_cache/prepared-root.sha256 ]]; then
        (cd "$prepared_cache"; sha256sum -c prepared-root.sha256) || die 'Shared prepared-root checkpoint is corrupt'
        cp --reflink=auto "$prepared_cache"/{prepared-root.tar,prepared-root.sha256,installed-rpms.tsv,capabilities.txt} "$WORK/"
        say 'Restored matching immutable preparation checkpoint'
    fi
    if [[ -s $WORK/prepared-root.tar && -s $WORK/prepared-root.sha256 ]]; then
        (cd "$WORK"; sha256sum -c prepared-root.sha256) || die 'Prepared root cache is corrupt'
        say 'Reusing verified prepared-root cache'
    else
        rm -f "$WORK/prepared-root.tar"
        image_job "$TEST_IMAGE" linux/arm64 "$WORK/prepare-root.log" bash /builder/src/image/prepare-runtime.sh "$inside/inputs" "$inside"
        (cd "$WORK"; sha256sum prepared-root.tar > prepared-root.sha256)
        mkdir -p "$prepared_cache"
        cp --reflink=auto "$WORK"/{prepared-root.tar,installed-rpms.tsv,capabilities.txt} "$prepared_cache/"
        cp "$WORK/prepared-root.sha256" "$prepared_cache/" # Completion marker last.
    fi
    if [[ -s $WORK/candidate/manifest.json ]]; then
        (cd "$WORK/candidate"; sha256sum -c SHA256SUMS) || die 'Existing candidate is corrupt'
        say "Verified existing candidate: $WORK/candidate"; return 0
    fi
    local partial
    for partial in candidate composition-root initramfs-root ext4-readback; do
        if [[ -e $WORK/$partial ]]; then
            mv "$WORK/$partial" "$WORK/$partial.rejected.$(date -u +%Y%m%dT%H%M%SZ).$$"
            say "Preserved rejected/interrupted $partial; resuming from verified inputs"
        fi
    done
    image_job "$tool_id" "$host_platform" "$WORK/compose.log" bash /builder/src/image/compose.sh "$inside" "$inside/profile.json" "$esp_mib" "$root_mib" "$sector"
    # $1 intentionally expands in the isolated container, not in the host shell.
    # shellcheck disable=SC2016
    image_job "$tool_id" "$host_platform" "$WORK/toolchain.log" bash -c 'rpm -qa --qf "%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\n" | sort > "$1/candidate/host-toolchain.tsv"' bash "$inside"
    cp "$RECIPE_ROOT"/manifests/images/core-*.json "$WORK/candidate/"
    jq -n --arg recipe "$recipe" --arg tools "$tool_id" --arg runtime "$TEST_IMAGE" \
        --arg prepared "$(sha256sum "$WORK/prepared-root.tar" | cut -d ' ' -f1)" \
        --arg preparation "$preparation_key" \
        '{schema_version:1,scope:"filesystem composition and emulated package execution",static_checks_passed:true,kernel_static_boot_prerequisites_passed:false,boot_tested:false,hardware_tested:false,geometry_verified:false,uefi_handoff_verified:false,esp32_firmware_protocol_verified:false,development_root_shell:true,recipe_sha256:$recipe,preparation_recipe_sha256:$preparation,host_toolchain:$tools,runtime_base:$runtime,prepared_root_sha256:$prepared}' > "$WORK/candidate/manifest.json"
    (cd "$WORK/candidate"; find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.tmp; mv SHA256SUMS.tmp SHA256SUMS)
    say "Validated local candidate: $WORK/candidate"
}
