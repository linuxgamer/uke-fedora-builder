#!/usr/bin/env bash
# Sourced by the workspace build.sh entry; no device commands are executed.
# shellcheck disable=SC2034 # OFFLINE is consumed by the shared host bootstrap.
pair_help() {
    cat <<'HELP'
Uke stock-ABL Fedora 44 pair (host-only build)
Usage: ./build.sh boot-pair --distro=fedora --device-dt FILE [options]
  --device-dt FILE    Private, read-only live bootloader FDT used for host admission tests
  --kernel-cache DIR Qualified kernel rpmbuild directory (workspace default)
  --core-candidate DIR Qualified prepared Fedora 44 root (required)
  --stock-boot FILE  Reviewed Android v4 boot template (EvolutionX default)
  --root-partlabel NAME  Root partition: userdata (default) or linux
  --jobs N          Maximum two CPUs, default one; queued behind other builds
  --release 44      Only reviewed Fedora release
  --offline         Require cached tools, sources and RPMs
  --dry-run         Explain the contract without building
  --test            All source, DT, module, filesystem and codec gates always run
  --help, -h        Show this help

Outputs fedora_boot.img and system.img (Android sparse EXT4, explicit RAW/FILL
coverage). Bootloader RAM/reservations are retained; embedded DT provider
adaptation adds UFS, USB peripheral and a simplefb screen candidate. Root is
admitted only from one physical GPT partition containing UKE_LINUX ext4.
Installing to userdata replaces Android user data; retain backups and OEM recovery.
The builder writes host files only: no GPT changes, device writes, slot changes,
flashing or init_boot/vendor_boot/
dtbo replacement. Physical ABL/UFS/display/input acceptance remains owner-tested.
HELP
}
pair_recipe_hash() {
    local dir=$1 kernel=$2
    cat "$dir"/src/boot-pair/*.sh "$dir"/src/boot-pair/*.cpp "$dir"/src/boot-pair/*.service \
        "$dir"/src/boot-pair/dracut/* "$dir"/configs/boot/uke-boot-pair*.json "$dir"/configs/boot/Containerfile.* \
        "$dir"/configs/keys/fedora-44.asc \
        "$dir"/src/boot/boot-image.cpp "$dir"/src/boot/vmlinux-exports.sh "$dir"/tests/boot-image-contract.sh "$dir"/tests/android-sparse-contract.sh \
        "$dir"/tests/boot-pair*.sh "$dir"/tests/kernel-config-contract.sh "$dir"/tests/kernel-export-contract.sh \
        "$dir"/src/image/host-lib.sh "$dir"/src/image/ext4-labels.cpp "$dir"/src/audit/*.sh \
        "$dir"/configs/images/selinux-namespace-policy.json \
        "$dir"/configs/firmware/uke-adsp-early.json \
        "$dir"/configs/images/uke-persist.fstab \
        "$kernel"/src/boot/{uke-abl.c,prepare-abl-source.sh,sm7675-uke-ufs.dtso,sm7675-uke-usb2.dtso} \
        "$kernel"/src/boot/*.dtsi "$kernel"/src/boot/vendor/* \
        "$kernel"/patches/boot/*.patch "$kernel"/patches/7.2.9/003{6,7}-*.patch \
        "$kernel"/tests/abl-dt-{check.cpp,contract.sh} \
        "$kernel"/tests/boot-supplier-contract.sh | sha256sum | cut -d ' ' -f1
}
pair_freeze_recipe() {
    local kernel=$1 recipe=$2
    if [[ -f $WORK/inputs/recipe-sha256 ]]; then
        [[ $(cat "$WORK/inputs/recipe-sha256") == "$recipe" &&
           $(pair_recipe_hash "$WORK/recipe" "$WORK/kernel-recipe") == "$recipe" ]] || die 'Frozen recipe differs on resume'
    else
        cp -a "$BUILDER/src" "$BUILDER/configs" "$BUILDER/tests" "$WORK/recipe/"
        # The separate signed source archive supplies the kernel itself.
        # Do not copy unrelated development trees or their read-only .git
        # objects into the recipe, especially during an interrupted resume.
        mkdir -p "$WORK/kernel-recipe/src" "$WORK/kernel-recipe/patches" "$WORK/kernel-recipe/tests"
        cp -a "$kernel/src/boot" "$WORK/kernel-recipe/src/"
        cp -a "$kernel/patches/boot" "$WORK/kernel-recipe/patches/"
        mkdir -p "$WORK/kernel-recipe/patches/7.2.9"
        cp "$kernel"/patches/7.2.9/003{6,7}-*.patch "$WORK/kernel-recipe/patches/7.2.9/"
        cp -a "$kernel/tests/abl-dt-check.cpp" "$kernel/tests/abl-dt-contract.sh" \
            "$kernel/tests/boot-supplier-contract.sh" "$WORK/kernel-recipe/tests/"
    fi
    [[ $(pair_recipe_hash "$WORK/recipe" "$WORK/kernel-recipe") == "$recipe" ]] || die 'Source changed during recipe freeze'
    printf '%s\n' "$recipe" > "$WORK/inputs/recipe-sha256"
}
pair_seed_cache() {
    local cache=$1 previous candidate match='' suffix=kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out
    # Reuse only Kbuild intermediates, never a phase receipt or delivered
    # Image. Make rechecks commands/dependencies; final module and linked-byte
    # checks still run. A failed build is not an accepted output.
    for previous in "$BUILDER"/build/boot-pair/pair-*; do
        [[ $previous != "$WORK" && -f $previous/source.passed && -d $previous/$suffix ]] || continue
        cmp -s "$previous/inputs/base.config" "$WORK/inputs/base.config" || continue
        cmp -s "$previous/inputs/kernel-manifest.json" "$WORK/inputs/kernel-manifest.json" || continue
        cmp -s "$previous/inputs/kernel.spec" "$WORK/inputs/kernel.spec" || continue
        cmp -s "$previous/inputs/applied-patches.txt" "$WORK/inputs/applied-patches.txt" || continue
        [[ $(jq -r .kernel_tool_image "$previous/inputs/profile.json") == $(jq -r .kernel_tool_image "$WORK/inputs/profile.json") ]] || continue
        jq -S .source "$WORK/inputs/kernel-manifest.json" | cmp -s - "$previous/prepared-source.json" || continue
        candidate=$previous/$suffix
        [[ -z $match || $candidate/.config -nt $match/.config ]] && match=$candidate
    done
    if [[ -n $match ]]; then
        say 'Reusing source-compatible Kbuild intermediates; all final gates will run'
        cache=$match
    fi
    cp -a --reflink=auto "$cache" "$WORK/kernel/build/fedora-44/7.2.9/rpmbuild/"
    sha256sum "$cache/.config" | cut -d ' ' -f1 > "$WORK/kbuild-seed-config.sha256"
}
pair_job() {
    local image=$1 stage=$2 owner=none status platform=linux/amd64
    wait_idle
    [[ $stage != root ]] || platform=linux/arm64
    if [[ $ENGINE == docker ]] && ! "$ENGINE" info --format '{{json .SecurityOptions}}' | jq -e 'any(.[]; contains("rootless"))' >/dev/null; then owner=$(id -u):$(id -g); fi
    local command=(bash /builder/src/boot-pair/container-stage.sh "$stage" "$owner")
    [[ $stage != root ]] || command=(bash /builder/src/boot-pair/prepare-root.sh "$owner")
    [[ $stage != qemu ]] || command=(bash /builder/tests/boot-pair-qemu.sh /job/qemu)
    CID=$("$ENGINE" create --network=none --security-opt label=disable --platform "$platform" --cpus="$JOBS" --memory=3g \
        -v "$WORK:/job" -v "$WORK/recipe:/builder:ro" -v "$WORK/kernel-recipe:/kernel-recipe:ro" \
        -v "$PRIVATE:/private" "$image" "${command[@]}")
    "$ENGINE" start "$CID" >/dev/null
    while [[ $("$ENGINE" inspect --format '{{or .State.Running .State.Paused}}' "$CID") == true ]]; do
        if heavy_busy; then
            if ((PAUSED == 0)); then "$ENGINE" pause "$CID" >/dev/null; PAUSED=1; say 'Our pair job paused behind another build'; fi
        elif ((PAUSED)); then "$ENGINE" unpause "$CID" >/dev/null; PAUSED=0; say 'Pair job resumed'; fi
        sleep 2
    done
    "$ENGINE" logs "$CID" > "$WORK/$stage.log" 2>&1
    status=$("$ENGINE" inspect --format '{{.State.ExitCode}}' "$CID")
    "$ENGINE" rm "$CID" >/dev/null; CID=''
    ((status == 0)) || die "Pair stage $stage failed ($status); inspect $WORK/$stage.log"
}
pair_main() {
    local target=boot-pair distro=fedora release=44 key='' value='' device_dt='' kernel_cache='' core='' stock='' root_partlabel=userdata
    local kernel=$BUILDER/../uke-mainline-linux profile=$BUILDER/configs/boot/uke-boot-pair.json
    JOBS=1 OFFLINE=0 DRY_RUN=0 ENGINE='' CID='' PAUSED=0
    while (($#)); do
        case $1 in
            --help|-h) pair_help; return;;
            --offline) OFFLINE=1;; --dry-run) DRY_RUN=1;; --test) :;;
            --build=*|--distro=*|--release=*|--jobs=*|--device-dt=*|--kernel-cache=*|--core-candidate=*|--stock-boot=*|--root-partlabel=*) key=${1%%=*}; value=${1#*=};;
            --build|--distro|--release|--jobs|--device-dt|--kernel-cache|--core-candidate|--stock-boot|--root-partlabel) key=$1; shift; (($#)) || die "Missing value for $key"; value=$1;;
            *) die "Unknown pair option: $1";;
        esac
        case $key in
            --build) target=$value;; --distro) distro=$value;; --release) release=$value;; --jobs) JOBS=$value;;
            --device-dt) device_dt=$value;; --kernel-cache) kernel_cache=$value;; --core-candidate) core=$value;; --stock-boot) stock=$value;; --root-partlabel) root_partlabel=$value;;
        esac
        key=''; shift
    done
    [[ $target == boot-pair && $distro == fedora && $release == 44 ]] || die 'Only boot-pair/Fedora 44 is admitted'
    [[ $JOBS =~ ^[1-9][0-9]{0,2}$ ]] || die 'Jobs must be a positive integer'
    ((JOBS <= 2)) || JOBS=2
    [[ $root_partlabel == userdata || $root_partlabel == linux ]] || die 'Root partition must be userdata or linux'
    say "Two-image stock-ABL candidate: boot_a and $root_partlabel; local screen TTY required"
    [[ $root_partlabel != userdata ]] || say 'Installing system.img to userdata destroys Android user data; backups and OEM recovery required'
    say 'Host-only build; init_boot, vendor_boot, dtbo, GPT and device storage remain untouched'
    ((DRY_RUN == 0)) || return 0
    bootstrap
    ((EUID != 0)) || die 'Run as a normal user'
    [[ $(uname -m) == x86_64 ]] || die 'This profile currently pins x86_64 host images'
    [[ -f $device_dt && ! -L $device_dt ]] || die '--device-dt must name a private bounded live FDT capture'
    [[ $(stat -c %s "$device_dt") -ge 40 && $(stat -c %s "$device_dt") -le 2097152 ]] || die 'Live FDT is outside ARM64 bounds'
    kernel_cache=${kernel_cache:-$kernel/build/fedora-44/7.2.9/rpmbuild}
    [[ -n $core ]] || die '--core-candidate must name the verified Fedora 44 Core assembly'
    stock=${stock:-$BUILDER/private/firmware/android17-evolutionx-12.1/boot.img}
    kernel_cache=$(realpath -e "$kernel_cache"); core=$(realpath -e "$core"); kernel=$(realpath -e "$kernel")
    local artifact=$kernel/artifacts/fedora-44/7.2.9 recipe effective uuid hash name file tool
    verify_cache "$artifact/build-manifest.json" "$(jq -r .kernel_manifest_sha256 "$profile")"
    verify_cache "$core/prepared-root.tar" "$(jq -r .core_prepared_root_sha256 "$profile")"
    verify_cache "$kernel_cache/kernel-out/.config" "$(jq -r .kernel_config_sha256 "$profile")"
    verify_cache "$kernel_cache/kernel-out/arch/arm64/boot/Image" "$(jq -r .base_kernel_image_sha256 "$profile")"
    verify_cache "$kernel_cache/kernel-out/Module.symvers" "$(jq -r .base_module_symvers_sha256 "$profile")"
    verify_cache "$kernel/packaging/senemos-uke-linux-kernel-mainline.spec" "$(jq -r .kernel_rpm_spec_sha256 "$profile")"
    hash=$(sha256sum "$stock" | cut -d ' ' -f1)
    jq -e --arg hash "$hash" 'any(.boot_templates[];.sha256==$hash)' "$profile" >/dev/null || die 'Unreviewed boot template'
    for tool in host_tool_image kernel_tool_image root_tool_image qemu_tool_image; do
        "$ENGINE" image inspect "$(jq -r ".$tool" "$profile")" >/dev/null 2>&1 || die "Missing pinned $tool"
    done
    mkdir -p "$BUILDER/build/boot-pair"
    exec 9> "$BUILDER/build/ukelinux-build.lock"
    if ! flock -n 9; then say 'Queued behind another image invocation'; flock 9; fi
    [[ $(df -Pk "$BUILDER/build" | awk 'NR==2 {print $4}') -ge $((14*1024*1024)) ]] || die 'At least 14 GiB free disk space is required'
    recipe=$(pair_recipe_hash "$BUILDER" "$kernel")
    hash=$(printf '%s\n%s\n%s\n' "$recipe" "$root_partlabel" "$(sha256sum "$stock" "$device_dt" | cut -d ' ' -f1)" | sha256sum | cut -d ' ' -f1)
    uuid=${hash:0:8}-${hash:8:4}-${hash:12:4}-${hash:16:4}-${hash:20:12}
    effective=$(jq -S --arg label "$root_partlabel" --arg uuid "$uuid" \
        --arg stock "$(sha256sum "$stock" | cut -d ' ' -f1)" \
        '.root_uuid=$uuid | .stock_boot_sha256=$stock |
         .kernel_command_line="rdinit=/usr/lib/systemd/systemd root=PARTLABEL=linux rw rootfstype=ext4 rootwait rd.retry=60 rd.timeout=65 rd.fstab=no rd.gpt-auto=no systemd.gpt_auto=no systemd.unit=multi-user.target senemos.debug=cdc-acm console=tty0 console=ttyAMA0 fbcon=map:0 fbcon=font:TER16x32 consoleblank=0 loglevel=7 panic=0 regulator_ignore_unused clk_ignore_unused pd_ignore_unused" |
         .kernel_command_line |= sub("root=PARTLABEL=linux"; "root=PARTLABEL="+$label) |
         .root_partlabel=$label | .root_selector=("PARTNAME-"+$label) |
         .partition_changes=[.boot_partition,$label]' "$profile")
    WORK=$BUILDER/build/boot-pair/pair-${hash:0:16}
    if [[ -f $WORK/manifest.json ]]; then
        (cd "$WORK" || exit; sha256sum -c SHA256SUMS)
        if [[ -f $WORK/qemu/result.json ]]; then
            jq -e --arg image "$(sha256sum "$WORK/Image" | cut -d ' ' -f1)" \
                --arg script "$(sha256sum "$WORK/recipe/tests/boot-pair-qemu.sh" | cut -d ' ' -f1)" \
                '.kernel_sha256==$image and .test_script_sha256==$script and
                 .real_ext4_root_transition and .root_pid1_systemd and .selinux_enforcing and
                 .local_tty_keyboard_command and .wrong_partition_name_rejected and
                 .changed_filesystem_uuid_accepted and .wrong_filesystem_type_rejected and
                 .duplicate_partition_name_rejected and .boot_tested==false and .hardware_tested==false' \
                "$WORK/qemu/result.json" >/dev/null || die 'Cached VM result is incomplete or belongs to different inputs'
            # The observer may have completed just before the host process
            # lost its receipt/final-manifest write. Its checked result is
            # enough to resume sealing without rerunning into existing files.
            touch "$WORK/qemu.passed"
            if jq -e --slurpfile vm "$WORK/qemu/result.json" \
                --arg hash "$(sha256sum "$WORK/qemu/result.json" | cut -d ' ' -f1)" \
                '.qemu_tested==true and .qemu_evidence.sha256==$hash and .qemu_evidence.result==$vm[0]' \
                "$WORK/manifest.json" >/dev/null &&
                grep -F '  qemu/result.json' "$WORK/SHA256SUMS" >/dev/null; then
                say "Verified pair cache and generic VM tests: $WORK"; return
            fi
        fi
    fi
    mkdir -p "$WORK/recipe" "$WORK/kernel-recipe" "$WORK/inputs/kernel"
    pair_freeze_recipe "$kernel" "$recipe"
    printf '%s\n' "$effective" > "$WORK/inputs/profile.json"
    jq -er .kernel_command_line "$WORK/inputs/profile.json" > "$WORK/inputs/kernel-cmdline"
    cp "$stock" "$WORK/inputs/stock-boot.img"
    cp "$artifact/build-manifest.json" "$WORK/inputs/kernel-manifest.json"
    cp "$artifact/output/applied-patches.txt" "$WORK/inputs/applied-patches.txt"
    jq -r '.source.patches[].path|split("/")|last' "$artifact/build-manifest.json" | cmp - "$WORK/inputs/applied-patches.txt" || die 'Applied-patch receipt differs from the accepted manifest'
    cp "$kernel_cache/kernel-out/.config" "$WORK/inputs/base.config"
    bash "$BUILDER/src/boot/vmlinux-exports.sh" "$kernel_cache/kernel-out/Module.symvers" > "$WORK/inputs/base-vmlinux.symvers"
    cp "$kernel/packaging/senemos-uke-linux-kernel-mainline.spec" "$WORK/inputs/kernel.spec"
    cp -a "$kernel_cache/SOURCES" "$WORK/inputs/"
    if jq -e '.early_adsp_firmware==true' "$WORK/inputs/profile.json" >/dev/null; then
        local firmware=$kernel/private/firmware/uke-os3.0.304.0-adsp-20261012.tar
        verify_cache "$firmware" "$(jq -er .archive_sha256 "$BUILDER/configs/firmware/uke-adsp-early.json")"
        cp --reflink=auto "$firmware" "$WORK/inputs/early-firmware.tar"
    fi
    # Reflinks preserve existing accepted artifacts without another full copy.
    cp --reflink=auto "$core/prepared-root.tar" "$WORK/inputs/prepared-root.tar"
    while IFS=$'\t' read -r name hash; do
        [[ $name == *.aarch64.rpm ]] || continue
        verify_cache "$artifact/$name" "$hash"
        cp "$artifact/$name" "$WORK/inputs/kernel/$name"
    done < <(jq -r '.[]|[.file,.sha256]|@tsv' "$BUILDER/configs/boot/uke-boot-pair-rpms.json")
    mkdir -p "$WORK/inputs/support"
    while IFS=$'\t' read -r name hash; do
        local package=$BUILDER/../artifacts/rpms/fedora-44/uke-boot-integration-0.1.0-13/$name
        verify_cache "$package" "$hash"
        cp "$package" "$WORK/inputs/support/$name"
    done < <(jq -r '.[]|[.file,.sha256]|@tsv' "$BUILDER/configs/boot/uke-boot-pair-support-rpms.json")
    mkdir -p "$WORK/inputs/host-rpms"
    while IFS=$'\t' read -r name hash; do
        verify_cache "$core/inputs/runtime/packages/$name" "$hash"
        cp "$core/inputs/runtime/packages/$name" "$WORK/inputs/host-rpms/$name"
    done < <(jq -r '.[]|[.file,.sha256]|@tsv' "$BUILDER/configs/boot/uke-boot-pair-host-rpms.json")
    printf '%s\n' "$JOBS" > "$WORK/inputs/jobs"
    (cd "$WORK/inputs" || exit; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) > "$WORK/input-checksums.part"
    mv "$WORK/input-checksums.part" "$WORK/inputs/SHA256SUMS"
    # Keep live DT and transformed unit data in a private sibling of its
    # capture, never in the public build output or source tree.
    PRIVATE=$(dirname "$(realpath -e "$device_dt")")/pair-${uuid}
    [[ -d $PRIVATE ]] || mkdir -m700 "$PRIVATE"
    install -m600 "$device_dt" "$PRIVATE/live-fdt.dtb"
    (cd "$PRIVATE" || exit; sha256sum live-fdt.dtb > live-fdt.sha256)
    trap cleanup EXIT
    wait_idle
    local architecture=x86_64
    TEST_IMAGE=$(jq -r .root_tool_image "$profile")
    prepare_aarch64
    [[ $(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo) -ge $((4*1024*1024)) ]] || die 'At least 4 GiB available RAM is required'
    mkdir -p "$WORK/kernel/build/fedora-44/7.2.9/rpmbuild"
    if [[ ! -d $WORK/kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out ]]; then
        pair_seed_cache "$kernel_cache/kernel-out"
    fi
    for file in source dt-test root audit-initramfs kernel compose qemu-prepare qemu; do
        [[ ! -e $WORK/$file.passed ]] || continue
        tool=$(jq -r .host_tool_image "$profile")
        case $file in source|kernel) tool=$(jq -r .kernel_tool_image "$profile");; root) tool=$(jq -r .root_tool_image "$profile");; qemu) tool=$(jq -r .qemu_tool_image "$profile");; esac
        say "Pair stage: $file"
        pair_job "$tool" "$file"
        touch "$WORK/$file.passed"
    done
    jq --slurpfile vm "$WORK/qemu/result.json" \
        --arg hash "$(sha256sum "$WORK/qemu/result.json" | cut -d ' ' -f1)" \
        '.qemu_tested=true | .qemu_evidence={path:"qemu/result.json",sha256:$hash,result:$vm[0]}' \
        "$WORK/manifest.json" > "$WORK/manifest.json.part"
    mv "$WORK/manifest.json.part" "$WORK/manifest.json"
    # Replace the pre-VM manifest entry; cover the final VM record as well.
    sed -i '/  manifest.json$/d; /  qemu\/result.json$/d' "$WORK/SHA256SUMS"
    (cd "$WORK" || exit; sha256sum manifest.json qemu/result.json >> SHA256SUMS; sha256sum -c SHA256SUMS)
    say "Pair composed: $WORK/fedora_boot.img and $WORK/system.img"
    say 'QEMU, physical tablet screen and UFS acceptance are separate evidence gates'
}
