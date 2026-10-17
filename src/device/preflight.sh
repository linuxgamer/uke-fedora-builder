#!/usr/bin/env bash
# Sourced by build.sh. This helper never contacts a device.
device_preflight_help() {
    cat <<'HELP'
Usage: ./build.sh check-device --pair DIRECTORY [--offline] [--report FILE]
Verify a built or delivered stock-ABL pair using local files only.
--offline is accepted for compatibility; local-only mode is always used.
--report writes a new JSON report; existing files are never overwritten.
Exit 0: local checks passed. Exit 1: invalid options or pair.
No ADB, fastboot, flash, slot selection, reboot or device access.
Device identity, partition geometry and the Android return route are not checked.
HELP
}

device_pair_verify() {
    local pair=$1 file hash line count=0
    local -A seen=()
    [[ -d $pair && ! -L $pair && -f $pair/SHA256SUMS && ! -L $pair/SHA256SUMS ]] || die 'Missing regular pair directory or checksums'
    while IFS= read -r line; do
        [[ $line =~ ^([a-f0-9]{64})\ \ ([A-Za-z0-9./_-]+)$ ]] || die 'Invalid checksum record'
        hash=${BASH_REMATCH[1]}; file=${BASH_REMATCH[2]}
        case $file in
            fedora_boot.img|system.img|manifest.json|qemu/result.json|packages.tsv|kernel.config|validation.json|INSTALL.md|README.txt|system.raw.img|Image|boot.config|initramfs.cpio.gz|Module.symvers|boot-header.json|inputs/profile.json|installed-rpms.tsv|toolchain.txt) :;;
            *) die 'Unexpected checksum path';;
        esac
        [[ ! -v seen[$file] ]] || die 'Duplicate checksum record'
        seen[$file]=1; ((count+=1))
        [[ -f $pair/$file && ! -L $pair/$file ]] || die 'Missing regular delivery file'
        [[ $file != qemu/result.json || ! -L $pair/qemu ]] || die 'Symlinked VM result directory'
        [[ $(sha256sum "$pair/$file" | cut -d ' ' -f1) == "$hash" ]] || die "Delivery checksum failed: $file"
    done < "$pair/SHA256SUMS"
    if [[ $count == 13 ]]; then
        local expected
        for expected in fedora_boot.img system.img system.raw.img Image boot.config initramfs.cpio.gz Module.symvers boot-header.json inputs/profile.json installed-rpms.tsv toolchain.txt manifest.json qemu/result.json; do
            [[ -v seen[$expected] ]] || die "Incomplete build checksum set: $expected"
        done
    else
        [[ $count == 9 ]] || die 'Incomplete delivery checksum set'
    fi
    local boot system vm
    boot=$(sha256sum "$pair/fedora_boot.img" | cut -d ' ' -f1)
    system=$(sha256sum "$pair/system.img" | cut -d ' ' -f1)
    vm=$(sha256sum "$pair/qemu/result.json" | cut -d ' ' -f1)
    jq -e --arg boot "$boot" --arg system "$system" --arg vm "$vm" \
        --argjson boot_bytes "$(stat -c %s "$pair/fedora_boot.img")" \
        --slurpfile result "$pair/qemu/result.json" '
        .profile.root_uuid as $uuid |
        .schema_version==1 and .profile.device=="uke" and
        .profile.mode=="stock-abl-ext4-root" and .profile.distribution=="fedora" and
        .profile.avb_state=="unsigned-hash-footer" and
        .profile.release=="44" and .profile.root_size_mib==3072 and
        .profile.boot_partition_bytes==$boot_bytes and $boot_bytes==100663296 and
        (.profile.root_uuid|test("^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$")) and
        (if (.profile.root_selector=="PARTNAME-linux" or .profile.root_selector=="PARTNAME-userdata") then
            (.profile.root_partlabel // "linux") as $partlabel |
            ($partlabel=="linux" or $partlabel=="userdata") and
            .profile.root_selector==("PARTNAME-"+$partlabel) and
            (.profile.kernel_command_line|contains("root=PARTLABEL="+$partlabel+" ")) and
            (if $partlabel=="userdata" then
                .profile.boot_partition=="boot_a" and .profile.partition_changes==["boot_a","userdata"] and
                .qemu_evidence.result.root_partition_label=="userdata" and .qemu_evidence.result.root_filesystem_growth==true
             else true end) and
            (.profile.kernel_command_line|contains("root=UUID=")|not) and
            .qemu_evidence.result.changed_filesystem_uuid_accepted==true and
            .qemu_evidence.result.wrong_filesystem_type_rejected==true and
            .qemu_evidence.result.duplicate_partition_name_rejected==true
         elif (.profile.root_selector // "UUID-and-PARTNAME-linux")=="UUID-and-PARTNAME-linux" then
            (.profile.kernel_command_line|contains("root=UUID="+$uuid+" ")) and
            .qemu_evidence.result.wrong_filesystem_uuid_rejected==true
         else false end) and
        .sha256.boot==$boot and .sha256.system==$system and
        .checks.module_byte_match==1144 and .checks.privacy==true and
        .checks.sparse_roundtrip==true and .checks.full_sparse_logical_coverage==true and
        .qemu_tested==true and .qemu_evidence.sha256==$vm and .qemu_evidence.result==$result[0] and
        .qemu_evidence.result.real_ext4_root_transition==true and
        .qemu_evidence.result.root_pid1_systemd==true and .qemu_evidence.result.selinux_enforcing==true and
        .qemu_evidence.result.local_tty_keyboard_command==true and
        .qemu_evidence.result.wrong_partition_name_rejected==true and
        .boot_tested==false and .hardware_tested==false and .flash_executed==false
        ' "$pair/manifest.json" >/dev/null || die 'Pair manifest or VM result is incompatible'
    if [[ -f $pair/boot-header.json ]]; then
        jq -e '.header_version==4 and .avb_footer_present==true and .image_bytes==100663296' \
            "$pair/boot-header.json" >/dev/null || die 'Boot image has no reviewed AVB footer'
    fi
    [[ $(od -An -tx1 -j $((100663296-64)) -N4 "$pair/fedora_boot.img" | tr -d ' \n') == 41564266 ]] ||
        die 'Boot image AVB footer magic is missing'
    local avb_info footer_os_version
    avb_info=$(avbtool info_image --image "$pair/fedora_boot.img") || die 'Boot AVB metadata is invalid'
    footer_os_version=$(printf '%s\n' "$avb_info" | sed -n "s/^[[:space:]]*Prop: com\.android\.build\.boot\.os_version -> '\([0-9][0-9]*\)'$/\1/p")
    [[ $footer_os_version =~ ^[0-9]+$ ]] || die 'Boot AVB footer lacks the OS version required by ABL'
    # Read only the sparse header; the checksums bind the previously decoded
    # complete payload. The logical size, not the compressed file size, matters.
    local -a header
    read -r -a header <<< "$(od -An -tu4 -N28 -v "$pair/system.img" | tr '\n' ' ')"
    [[ ${#header[@]} == 7 && ${header[0]} == 3978755898 && ${header[1]} == 1 &&
       ${header[2]} == 786460 && ${header[3]} == 4096 && ${header[4]} == 786432 ]] || die 'Sparse header does not describe the reviewed 3 GiB filesystem'
}

device_preflight_main() {
    local pair='' report='' key='' value='' command
    while (($#)); do
        case $1 in
            --check-device|--offline) :;;
            --help|-h) device_preflight_help; return 0;;
            --pair=*|--report=*) key=${1%%=*}; value=${1#*=};;
            --pair|--report) key=$1; shift; (($#)) || die "Missing value for $key"; value=$1;;
            *) die "Unknown device-check option: $1";;
        esac
        case $key in --pair) pair=$value;; --report) report=$value;; esac
        key=''; shift
    done
    for command in jq sha256sum stat od tr cut sed avbtool; do
        command -v "$command" >/dev/null 2>&1 || die "Missing host check tool: $command"
    done
    [[ -n $pair ]] || die '--pair must identify the coordinated delivery directory'
    [[ -z $report || (! -e $report && ! -L $report) ]] || die 'Report must name a new file'
    device_pair_verify "$pair"
    local root_partition boot_partition rollback_slot result
    root_partition=$(jq -r '.profile.root_partlabel // "linux"' "$pair/manifest.json")
    boot_partition=$(jq -r '.profile.boot_partition // "boot_b"' "$pair/manifest.json")
    [[ $root_partition == linux || $root_partition == userdata ]] || die 'Unsupported root partition'
    [[ $boot_partition == boot_a || $boot_partition == boot_b ]] || die 'Unsupported boot partition'
    rollback_slot=b
    [[ $boot_partition != boot_b ]] || rollback_slot=a
    result=$(jq -n --arg target_root "$root_partition" --arg target_boot "$boot_partition" --arg rollback "$rollback_slot" \
        --arg manifest "$(sha256sum "$pair/manifest.json" | cut -d ' ' -f1)" '
        {schema_version:1,status:"local-pair-verified",local_pair_verified:true,manifest_sha256:$manifest,
          transport:"offline",device:"unknown",current_slot:"unknown",unlocked:"unknown",
          fastboot_userspace:"unknown",boot_partition:$target_boot,root_partition:$target_root,
          boot_bytes:null,root_bytes:null,root_physical_partition:"unknown",blockers:[],
          live_device_checked:false,
          owner_checks:[("Original "+$target_boot+" backup retained"),
            ("Android slot "+$rollback+" boot images preserved; OEM restore and data backups available"),
            (if $target_root=="userdata" then "Replacing userdata destroys shared Android data; Android rollback requires userdata restoration" else "linux target exclusively available for Fedora" end)],
          boot_tested:false,hardware_tested:false,device_write_executed:false} +
          {($target_boot+"_bytes"):null,($target_root+"_bytes"):null} +
          (if $target_root=="linux" then {linux_physical_partition:"unknown"} else {} end)')
    if [[ -n $report ]]; then
        (umask 077; set -o noclobber; printf '%s\n' "$result" > "$report") || die 'Cannot create a new private report'
    fi
    printf '%s\n' "$result"
}
