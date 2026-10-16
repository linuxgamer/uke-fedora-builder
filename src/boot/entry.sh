#!/usr/bin/env bash
# Sourced by build.sh through the Core dispatcher; host only.
# shellcheck disable=SC2034 # OFFLINE is consumed by the shared host bootstrap.
boot_help() {
    cat <<'HELP'
Uke Fedora boot_b debug image (host only; no flashing)
Usage: ./build.sh boot --distro=fedora [options]
  --stock-boot FILE       Exact reviewed OEM/ROM boot.img template
  --boot-template ID     android17-evolutionx-12.1 (default), global-os3.0.304.0,
                         or global-os3.0.303.0; physical slot contents stay unverified
  --kernel-component DIR Qualified 44-patch kernel component (workspace default)
  --core-candidate DIR   Qualified Fedora 44 Core assembly (required)
  --reuse-boot-cache DIR Reuse a verified earlier local boot build, preserving its paths
  --jobs N               Maximum two CPUs, default one; queue behind other builds
  --release 44           Only reviewed distribution release
  --offline              No host dependency installation; exact cached inputs
  --dry-run              Explain the profile without building
  --test                 Always validate header, kernel bytes, ABI and payload
  --self-test            CLI and profile fixtures; codec fixtures run in preparation
  --help, -h             Show this help

Produces fedora_boot.img: raw ARM64 kernel in Android boot v4, with a built-in
Fedora initramfs and forced development command line. External init_boot
ramdisks are ignored. No root partition is mounted or switched to by the debug
target. Matching stock vendor_boot_b/dtbo_b still supply DT; physical DT handoff,
unlocked ABL acceptance, actual boot_b capacity and ESP32 USB remain unverified.
The recipe never runs fastboot, changes slots, or writes devices.
HELP
}
boot_job() {
    local image=$1 stage=$2 owner=none status
    wait_idle
    if [[ $ENGINE == docker ]] && ! "$ENGINE" info --format '{{json .SecurityOptions}}' | jq -e 'any(.[]; contains("rootless"))' >/dev/null; then owner=$(id -u):$(id -g); fi
    CID=$("$ENGINE" create --network=none --security-opt label=disable --cpus="$JOBS" --memory=3g \
        -v "$WORK:/job" -v "$WORK/recipe:/builder:ro" \
        -v "$WORK/kernel:/work/kernel" \
        "$image" bash /builder/src/boot/container-stage.sh "$stage" "$owner")
    "$ENGINE" start "$CID" >/dev/null
    while [[ $("$ENGINE" inspect --format '{{or .State.Running .State.Paused}}' "$CID") == true ]]; do
        if heavy_busy; then
            if ((PAUSED == 0)); then "$ENGINE" pause "$CID" >/dev/null; PAUSED=1; say 'Boot image job paused behind another compiler'; fi
        elif ((PAUSED)); then "$ENGINE" unpause "$CID" >/dev/null; PAUSED=0; say 'Boot image job resumed'; fi
        sleep 2
    done
    "$ENGINE" logs "$CID" > "$WORK/$stage.log" 2>&1
    status=$("$ENGINE" inspect --format '{{.State.ExitCode}}' "$CID")
    "$ENGINE" rm "$CID" >/dev/null; CID=''
    ((status == 0)) || die "Boot stage $stage failed ($status); inspect $WORK/$stage.log"
}
boot_recipe_hash() {
    local dir=$1
    # QEMU observes the finished bytes separately and must not invalidate the
    # kernel cache when only its console parser changes.
    cat "$dir"/src/boot/* "$dir"/configs/boot/*.json "$dir"/configs/boot/Containerfile.* "$dir"/tests/boot-contract.sh \
        "$dir"/tests/boot-image-contract.sh "$dir"/tests/kernel-export-contract.sh \
        "$dir"/src/image/host-lib.sh "$dir"/src/image/dracut/91uke-bringup/*.service \
        "$dir"/src/audit/*.sh | sha256sum | cut -d ' ' -f1
}
boot_main() {
    local target=boot distro=fedora release=44 self=0 key='' value='' stock='' reuse='' template='' kernel core profile recipe recipe_source effective_profile host_image kernel_image input module_rpm
    JOBS=1 OFFLINE=0 DRY_RUN=0 ENGINE='' CID='' PAUSED=0
    kernel=$BUILDER/../uke-mainline-linux
    core=''
    profile=$BUILDER/configs/boot/uke-boot-b.json
    while (($#)); do
        case $1 in
            --help|-h) boot_help; return 0;;
            --offline) OFFLINE=1;; --dry-run) DRY_RUN=1;; --test) :;; --self-test) self=1;;
            --build=*|--distro=*|--release=*|--jobs=*|--stock-boot=*|--kernel-component=*|--core-candidate=*|--reuse-boot-cache=*|--boot-template=*) key=${1%%=*}; value=${1#*=};;
            --build|--distro|--release|--jobs|--stock-boot|--kernel-component|--core-candidate|--reuse-boot-cache|--boot-template) key=$1; shift; (($#)) || die "Missing value for $key"; value=$1;;
            *) die "Unknown boot option: $1";;
        esac
        case $key in
            --build) target=$value;; --distro) distro=$value;; --release) release=$value;; --jobs) JOBS=$value;;
            --stock-boot) stock=$value;; --kernel-component) kernel=$value;; --core-candidate) core=$value;;
            --reuse-boot-cache) reuse=$value;;
            --boot-template) template=$value;;
        esac
        key=''; shift
    done
    [[ $target == boot && $distro == fedora && $release == 44 ]] || die 'Only boot/Fedora 44 is admitted'
    [[ $JOBS =~ ^[1-9][0-9]{0,2}$ ]] || die 'Jobs must be a positive integer'
    ((JOBS <= 2)) || JOBS=2
    [[ -f $profile ]] || die 'Boot profile is missing'
    if ((DRY_RUN || self)); then
        command -v jq >/dev/null 2>&1 || die 'jq is required for inspection; run an online build to install host prerequisites'
    else
        # The JSON reader may itself be missing on a fresh host.
        bootstrap
    fi
    template=${template:-$(jq -r .default_boot_template "$profile")}
    jq -e --arg template "$template" 'any(.boot_templates[];.id==$template)' "$profile" >/dev/null || die 'Unsupported boot template'
    if ((self)); then bash "$BUILDER/tests/boot-contract.sh"; return; fi
    say 'Android boot v4 / boot_b; built-in Fedora debug initramfs; no Aloha required'
    say 'No automatic root mount; stock DT transfer and physical USB/boot are unverified'
    ((DRY_RUN == 0)) || return 0
    ((EUID != 0)) || die 'Run as a normal user; elevation is limited to host dependencies'
    [[ $(uname -m) == x86_64 ]] || die 'This first boot profile pins x86_64 host tool images; an AArch64 host pin is not yet admitted'
    local processors available_memory
    processors=$(getconf _NPROCESSORS_ONLN)
    ((JOBS <= processors)) || JOBS=$processors
    available_memory=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
    if [[ ! $available_memory =~ ^[0-9]+$ ]] || ((available_memory < 4*1024*1024)); then
        die 'At least 4 GiB available RAM is required before starting the 3 GiB build container'
    fi
    if [[ -z $stock ]]; then
        stock=$BUILDER/private/firmware/$template/extracted/boot.img
        [[ -f $stock ]] || stock=$BUILDER/private/firmware/$template/boot.img
    fi
    [[ -f $stock && ! -L $stock ]] || die 'Provide --stock-boot with the reviewed stock template; firmware is not downloaded automatically'
    [[ -n $core ]] || die '--core-candidate must name the verified Fedora 44 Core assembly'
    kernel=$(realpath -e "$kernel"); core=$(realpath -e "$core")
    local artifact=$kernel/artifacts/fedora-44/7.2.9
    local stock_hash selected_template
    stock_hash=$(sha256sum "$stock" | cut -d ' ' -f1)
    selected_template=$(jq -er --arg hash "$stock_hash" '.boot_templates[]|select(.sha256==$hash)|.id' "$profile") || die 'Unreviewed boot template hash'
    # An explicit file is identified by its exact hash; the CLI id is only
    # a default file locator and never relabels incompatible template bytes.
    effective_profile=$(jq -S --arg hash "$stock_hash" --arg selected "$selected_template" \
        '.stock_boot_sha256=$hash | .stock_profile=$selected | .boot_partition_bytes=(.boot_templates[]|select(.id==$selected)|.bytes)' "$profile")
    verify_cache "$artifact/build-manifest.json" "$(jq -r .kernel_manifest_sha256 "$profile")"
    jq -e '.compile_validation=="passed" and .payload_validation=="passed" and .source_rpm_preparation=="passed" and .package_lifecycle_tested and (.source.patches|length)==44' "$artifact/build-manifest.json" >/dev/null || die 'Qualified 44-patch kernel receipt required'
    # Rootful composition preserves dracut's root-only file permissions. Read
    # the same bytes from the host-readable prepared archive.
    [[ $(tar -xOf "$core/prepared-root.tar" ./boot/initramfs-7.2.9-senemos-uke.img | sha256sum | cut -d ' ' -f1) == "$(jq -r .initramfs_sha256 "$profile")" ]] || die 'Core initramfs hash mismatch'
    verify_cache "$kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out/.config" "$(jq -r .kernel_config_sha256 "$profile")"
    verify_cache "$kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out/arch/arm64/boot/Image" "$(jq -r .base_kernel_image_sha256 "$profile")"
    verify_cache "$kernel/packaging/senemos-uke-linux-kernel-mainline.spec" "$(jq -r .kernel_rpm_spec_sha256 "$profile")"
    verify_cache "$kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out/Module.symvers" "$(jq -r .base_module_symvers_sha256 "$profile")"
    jq -r '.source.patches[].path|split("/")|last' "$artifact/build-manifest.json" | cmp - "$artifact/output/applied-patches.txt" || die 'Applied-patch receipt mismatch'
    module_rpm=$(jq -er '.packages[]|select(.file|contains("-modules-"))|.file' "$artifact/build-manifest.json")
    verify_cache "$artifact/$module_rpm" "$(jq -r --arg file "$module_rpm" '.packages[]|select(.file==$file)|.sha256' "$artifact/build-manifest.json")"
    host_image=$(jq -r .host_tool_image "$profile"); kernel_image=$(jq -r .kernel_tool_image "$profile")
    for input in "$host_image" "$kernel_image"; do "$ENGINE" image inspect "$input" >/dev/null 2>&1 || die 'Pinned build image missing; prepare the qualified Core/kernel environment first'; done
    mkdir -p "$BUILDER/build/boot" "$BUILDER/private/firmware/global-os3.0.303.0"
    exec 9> "$BUILDER/build/ukelinux-build.lock"
    if ! flock -n 9; then say 'Queued behind another image invocation'; flock 9; fi
    [[ $(df -Pk "$BUILDER/build" | awk 'NR==2 {print $4}') -ge $((8*1024*1024)) ]] || die 'At least 8 GiB free space is required'
    recipe_source=$(boot_recipe_hash "$BUILDER")
    recipe=$(printf '%s\n%s\n' "$recipe_source" "$effective_profile" | sha256sum | cut -d ' ' -f1)
    WORK=$BUILDER/build/boot/boot-b-${recipe:0:16}
    if [[ -e $WORK/manifest.json ]]; then
        say "Verifying cached candidate: $WORK/fedora_boot.img"
        [[ $(boot_recipe_hash "$WORK/recipe") == "$recipe_source" ]] || die 'Cached source recipe mismatch'
        cmp <(printf '%s\n' "$effective_profile") "$WORK/profile.json" || die 'Cached profile mismatch'
        verify_cache "$WORK/inputs/kernel-manifest.json" "$(jq -r .kernel_manifest_sha256 "$profile")"
        verify_cache "$WORK/inputs/stock-boot.img" "$stock_hash"
        jq -e '.checks.applied_patch_count==44 and .checks.embedded_initramfs_byte_match and .checks.android_v4_roundtrip and .flash_executed==false' "$WORK/manifest.json" >/dev/null || die 'Cached result is not a qualified candidate'
        (cd "$WORK" || exit; sha256sum -c SHA256SUMS)
        return
    fi
    mkdir -p "$WORK/recipe" "$WORK/inputs"
    cp -a "$BUILDER/src" "$BUILDER/configs" "$BUILDER/tests" "$BUILDER/manifests" "$WORK/recipe/"
    [[ $(boot_recipe_hash "$WORK/recipe") == "$recipe_source" ]] || die 'Boot source changed while freezing the recipe'
    printf '%s\n' "$recipe" > "$WORK/inputs/recipe-sha256"
    printf '%s\n' "$effective_profile" > "$WORK/inputs/profile.json"
    mkdir -p "$BUILDER/private/firmware/$selected_template"
    cp "$stock" "$BUILDER/private/firmware/$selected_template/boot.img.part"
    verify_cache "$BUILDER/private/firmware/$selected_template/boot.img.part" "$stock_hash"
    mv "$BUILDER/private/firmware/$selected_template/boot.img.part" "$BUILDER/private/firmware/$selected_template/boot.img"
    cp "$BUILDER/private/firmware/$selected_template/boot.img" "$WORK/inputs/stock-boot.img"
    cp "$artifact/build-manifest.json" "$WORK/inputs/kernel-manifest.json"
    cp "$artifact/output/applied-patches.txt" "$WORK/inputs/applied-patches.txt"
    cp "$artifact/$module_rpm" "$WORK/inputs/modules.rpm"
    local core_rpm
    core_rpm=$(jq -er '.packages[]|select(.file|contains("-core-"))|.file' "$artifact/build-manifest.json")
    verify_cache "$artifact/$core_rpm" "$(jq -r --arg file "$core_rpm" '.packages[]|select(.file==$file)|.sha256' "$artifact/build-manifest.json")"
    cp "$artifact/$core_rpm" "$WORK/inputs/core.rpm"
    tar -xOf "$core/prepared-root.tar" ./boot/initramfs-7.2.9-senemos-uke.img > "$WORK/inputs/core-initramfs.img"
    cp -a "$kernel/build/fedora-44/7.2.9/rpmbuild/SOURCES" "$WORK/inputs/"
    cp "$kernel/packaging/senemos-uke-linux-kernel-mainline.spec" "$WORK/inputs/kernel.spec"
    printf '%s\n' "$JOBS" > "$WORK/inputs/jobs"
    trap cleanup EXIT
    wait_idle
    # Preserve the accepted build; reproduce its container paths in a private
    # copy so completed objects can be reused without altering RPM evidence.
    mkdir -p "$WORK/kernel/build/fedora-44/7.2.9/rpmbuild"
    if [[ ! -d $WORK/kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out ]]; then
        local cache_out=$kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out
        if [[ -n $reuse ]]; then
            reuse=$(realpath -e "$reuse")
            [[ $reuse == "$BUILDER/build/boot/"boot-b-* && -s $reuse/manifest.json ]] || die 'Reuse requires a verified local boot candidate'
            (cd "$reuse" || exit; sha256sum -c SHA256SUMS) || die 'Boot cache checksum mismatch'
            verify_cache "$reuse/inputs/kernel-manifest.json" "$(jq -r .kernel_manifest_sha256 "$profile")"
            verify_cache "$reuse/base.config" "$(jq -r .kernel_config_sha256 "$profile")"
            cmp "$reuse/base-vmlinux.symvers" <(bash "$BUILDER/src/boot/vmlinux-exports.sh" "$kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out/Module.symvers") || die 'Reused base export table differs from the qualified kernel'
            cmp "$reuse/inputs/applied-patches.txt" "$WORK/inputs/applied-patches.txt"
            jq -e '.checks.embedded_initramfs_byte_match and .checks.core_export_abi_match and .checks.applied_patch_count==44' "$reuse/manifest.json" >/dev/null || die 'Boot cache validation missing'
            cache_out=$reuse/kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out
            cp "$reuse/base.config" "$reuse/base-vmlinux.symvers" "$WORK/"
            sha256sum "$reuse/manifest.json" | cut -d ' ' -f1 > "$WORK/inputs/reused-build-manifest-sha256"
        fi
        cp -a --reflink=auto "$cache_out" "$WORK/kernel/build/fedora-44/7.2.9/rpmbuild/"
    fi
    boot_job "$host_image" prepare
    boot_job "$kernel_image" kernel
    boot_job "$host_image" pack
    say "Boot-format and payload candidate verified: $WORK/fedora_boot.img"
    say 'QEMU and own-device admission are recorded separately; no fastboot command was executed'
}
