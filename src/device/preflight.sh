#!/usr/bin/env bash
# Sourced by build.sh. Device commands are bounded, read-only inventory.
device_preflight_help() {
    cat <<'HELP'
Usage: ./build.sh check-device --pair DIRECTORY [--offline] [--report FILE]
Verify a delivered stock-ABL pair and inspect one connected Uke transport.
--offline verifies local files without contacting ADB or fastboot.
--report writes a new JSON report; existing files are never overwritten.
Exit 0: local checks passed (offline), or bootloader geometry checks passed.
Exit 1: invalid options or pair. Exit 2: device prerequisites unavailable.
No flash, slot selection, reboot, unlock, root escalation or partition writes.
The report omits serial numbers, captured DT, private paths and raw output.
Bootloader checks do not establish tablet boot or the Android return route.
HELP
}

device_size_number() {
    local value=$1
    if [[ $value =~ ^0x[0-9a-fA-F]{1,12}$ ]]; then printf '%s\n' "$((value))";
    elif [[ $value =~ ^[0-9]{1,15}$ ]]; then printf '%s\n' "$((10#$value))";
    else return 1; fi
}

device_fastboot_value() {
    local serial=$1 key=$2 raw line value='' count=0
    raw=$(timeout 8 fastboot -s "$serial" getvar "$key" 2>&1) || return 1
    while IFS= read -r line; do
        line=${line//$'\r'/}
        line=${line#'(bootloader) '}
        if [[ $line == "$key: "* ]]; then
            read -r value <<< "${line#"$key:"}"; ((count+=1))
        fi
    done <<< "$raw"
    [[ $count == 1 ]] || return 1
    printf '%s\n' "$value"
}

device_pair_verify() {
    local pair=$1 file hash line count=0
    local -A seen=()
    [[ -d $pair && ! -L $pair && -f $pair/SHA256SUMS && ! -L $pair/SHA256SUMS ]] || die 'Missing regular pair directory or checksums'
    while IFS= read -r line; do
        [[ $line =~ ^([a-f0-9]{64})\ \ ([A-Za-z0-9./_-]+)$ ]] || die 'Invalid checksum record'
        hash=${BASH_REMATCH[1]}; file=${BASH_REMATCH[2]}
        case $file in
            fedora_boot.img|system.img|manifest.json|qemu/result.json|packages.tsv|kernel.config|validation.json|INSTALL.md|README.txt) :;;
            *) die 'Unexpected checksum path';;
        esac
        [[ ! -v seen[$file] ]] || die 'Duplicate checksum record'
        seen[$file]=1; ((count+=1))
        [[ -f $pair/$file && ! -L $pair/$file ]] || die 'Missing regular delivery file'
        [[ $file != qemu/result.json || ! -L $pair/qemu ]] || die 'Symlinked VM result directory'
        [[ $(sha256sum "$pair/$file" | cut -d ' ' -f1) == "$hash" ]] || die "Delivery checksum failed: $file"
    done < "$pair/SHA256SUMS"
    [[ $count == 9 ]] || die 'Incomplete delivery checksum set'
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
        .profile.release=="rawhide" and .profile.root_size_mib==3072 and
        .profile.boot_partition_bytes==$boot_bytes and $boot_bytes==100663296 and
        (.profile.root_uuid|test("^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$")) and
        (if .profile.root_selector=="PARTNAME-linux" then
            (.profile.kernel_command_line|contains("root=PARTLABEL=linux ")) and
            (.profile.kernel_command_line|contains("root=UUID=")|not) and
            .qemu_evidence.result.changed_filesystem_uuid_accepted==true and
            .qemu_evidence.result.wrong_filesystem_type_rejected==true and
            .qemu_evidence.result.duplicate_partition_name_rejected==true
         elif (.profile.root_selector // "UUID-and-PARTNAME-linux")=="UUID-and-PARTNAME-linux" then
            (.profile.kernel_command_line|contains("root=UUID="+$uuid+" ")) and
            .qemu_evidence.result.wrong_filesystem_uuid_rejected==true
         else false end) and
        .sha256.boot==$boot and .sha256.system==$system and
        .checks.module_byte_match==1146 and .checks.privacy==true and
        .checks.sparse_roundtrip==true and .checks.full_sparse_logical_coverage==true and
        .qemu_tested==true and .qemu_evidence.sha256==$vm and .qemu_evidence.result==$result[0] and
        .qemu_evidence.result.real_ext4_root_transition==true and
        .qemu_evidence.result.root_pid1_systemd==true and .qemu_evidence.result.selinux_enforcing==true and
        .qemu_evidence.result.local_tty_keyboard_command==true and
        .qemu_evidence.result.wrong_partition_name_rejected==true and
        .boot_tested==false and .hardware_tested==false and .flash_executed==false
        ' "$pair/manifest.json" >/dev/null || die 'Pair manifest or VM result is incompatible'
    # Read only the sparse header; the checksums bind the previously decoded
    # complete payload. The logical size, not the compressed file size, matters.
    local -a header
    read -r -a header <<< "$(od -An -tu4 -N28 -v "$pair/system.img" | tr '\n' ' ')"
    [[ ${#header[@]} == 7 && ${header[0]} == 3978755898 && ${header[1]} == 1 &&
       ${header[2]} == 786460 && ${header[3]} == 4096 && ${header[4]} == 786432 ]] || die 'Sparse header does not describe the reviewed 3 GiB filesystem'
}

device_preflight_main() {
    local pair='' report='' offline=0 key='' value='' command
    while (($#)); do
        case $1 in
            --check-device) :;; --offline) offline=1;;
            --help|-h) device_preflight_help; return 0;;
            --pair=*|--report=*) key=${1%%=*}; value=${1#*=};;
            --pair|--report) key=$1; shift; (($#)) || die "Missing value for $key"; value=$1;;
            *) die "Unknown device-check option: $1";;
        esac
        case $key in --pair) pair=$value;; --report) report=$value;; esac
        key=''; shift
    done
    for command in jq sha256sum stat od tr cut timeout; do
        command -v "$command" >/dev/null 2>&1 || die "Missing host check tool: $command"
    done
    [[ -n $pair ]] || die '--pair must identify the coordinated delivery directory'
    [[ -z $report || (! -e $report && ! -L $report) ]] || die 'Report must name a new file'
    device_pair_verify "$pair"
    local mode=offline status=local-pair-verified code=0 product=unknown slot=unknown unlocked=unknown
    local boot_bytes=null linux_bytes=null physical=unknown userspace=unknown
    local serial='' listing='' adb_count=0 fastboot_count=0 row token transport=''
    local -a blockers=()
    if ((offline == 0)); then
        if command -v adb >/dev/null 2>&1; then
            listing=$(timeout 8 adb devices -l 2>/dev/null) || listing=''
            while read -r serial row token; do
                if [[ $row == device || $row == recovery ]]; then
                    ((adb_count+=1))
                    [[ $token =~ transport_id:([0-9]+) ]] && transport=${BASH_REMATCH[1]}
                fi
            done <<< "$listing"
        fi
        if command -v fastboot >/dev/null 2>&1; then
            listing=$(timeout 8 fastboot devices 2>/dev/null) || listing=''
            while read -r row token; do
                if [[ -n $row && $token == fastboot ]]; then serial=$row; ((fastboot_count+=1)); fi
            done <<< "$listing"
        fi
        mode=unavailable; status=device-prerequisites-unavailable; code=2
        if ((adb_count + fastboot_count != 1)); then
            blockers+=(exactly-one-ready-Uke-transport-required)
        elif ((fastboot_count == 1)); then
            mode=fastboot
            value=$(device_fastboot_value "$serial" product) || value=''
            [[ $value != uke ]] || product=uke
            value=$(device_fastboot_value "$serial" current-slot) || value=''
            [[ $value != a && $value != b ]] || slot=$value
            value=$(device_fastboot_value "$serial" unlocked) || value=''
            case $value in yes|no) unlocked=$value;; esac
            value=$(device_fastboot_value "$serial" is-userspace) || value=''
            case $value in yes|no) userspace=$value;; esac
            value=$(device_fastboot_value "$serial" is-logical:linux) || value=''
            case $value in no) physical=yes;; yes) physical=no;; esac
            value=$(device_fastboot_value "$serial" partition-size:boot_b) || value=''
            boot_bytes=$(device_size_number "$value") || boot_bytes=null
            value=$(device_fastboot_value "$serial" partition-size:linux) || value=''
            linux_bytes=$(device_size_number "$value") || linux_bytes=null
        else
            mode=adb
            # Fixed command: properties and sysfs only. No su/adb root, block
            # writes, captured FDT or unit identifiers enter this probe.
            # Expansion happens in the device shell, never on the host.
            # shellcheck disable=SC2016
            local probe='printf "product=%s\nslot=%s\nlocked=%s\n" "$(getprop ro.product.device)" "$(getprop ro.boot.slot_suffix)" "$(getprop ro.boot.flash.locked)"; for p in boot_b linux; do n=$(readlink -f /dev/block/by-name/$p 2>/dev/null); n=${n##*/}; case "$n" in ""|*[!A-Za-z0-9_-]*) continue;; esac; if [ -r /sys/class/block/$n/size ]; then printf "%s_sectors=" "$p"; cat /sys/class/block/$n/size; fi; if [ "$p" = linux ] && [ -f /sys/class/block/$n/partition ]; then while IFS= read -r line; do [ "$line" != PARTNAME=linux ] || printf "linux_physical=yes\n"; done < /sys/class/block/$n/uevent; fi; done'
            listing=''
            if [[ $transport =~ ^[0-9]+$ ]]; then listing=$(timeout 10 adb -t "$transport" shell -T "$probe" 2>/dev/null) || listing=''; fi
            while IFS='=' read -r key value; do
                value=${value//$'\r'/}
                case $key:$value in
                    product:uke) product=uke;; slot:_a) slot=a;; slot:_b) slot=b;;
                    locked:0) unlocked=yes;; locked:1) unlocked=no;; linux_physical:yes) physical=yes;;
                    boot_b_sectors:*|linux_sectors:*)
                        if [[ $value =~ ^[0-9]{1,12}$ ]]; then
                            value=$((10#$value * 512))
                            [[ $key != boot_b_sectors ]] || boot_bytes=$value
                            [[ $key != linux_sectors ]] || linux_bytes=$value
                        fi;;
                esac
            done <<< "$listing"
            blockers+=(bootloader-fastboot-check-required)
        fi
        [[ $mode == unavailable || $product == uke ]] || blockers+=(device-identity-unconfirmed)
        [[ $mode == unavailable || $slot == a ]] || blockers+=(preserved-Android-A-slot-not-current)
        [[ $mode == unavailable || $unlocked == yes ]] || blockers+=(bootloader-unlock-unconfirmed)
        [[ $mode == unavailable || ($boot_bytes != null && $boot_bytes -ge 100663296) ]] || blockers+=(boot_b-capacity-unconfirmed)
        [[ $mode == unavailable || ($linux_bytes != null && $linux_bytes -ge 3221225472) ]] || blockers+=(linux-capacity-unconfirmed)
        [[ $mode == unavailable || $physical == yes ]] || blockers+=(physical-linux-partition-unconfirmed)
        [[ $mode != fastboot || $userspace == no ]] || blockers+=(bootloader-fastboot-required)
        if ((${#blockers[@]} == 0)); then status=bootloader-geometry-compatible-owner-checks-required; code=0; fi
    fi
    local result blockers_json
    blockers_json=$(printf '%s\n' "${blockers[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')
    result=$(jq -n --arg status "$status" --arg mode "$mode" --arg product "$product" --arg slot "$slot" \
        --arg unlocked "$unlocked" --arg physical "$physical" --arg userspace "$userspace" \
        --argjson boot "$boot_bytes" --argjson linux "$linux_bytes" --argjson blockers "$blockers_json" \
        --arg manifest "$(sha256sum "$pair/manifest.json" | cut -d ' ' -f1)" \
        '{schema_version:1,status:$status,local_pair_verified:true,manifest_sha256:$manifest,
          transport:$mode,device:$product,current_slot:$slot,unlocked:$unlocked,
          fastboot_userspace:$userspace,boot_b_bytes:$boot,linux_bytes:$linux,
          linux_physical_partition:$physical,blockers:$blockers,
          owner_checks:["Actual pre-test B backups retained","Working Android A and recovery return route","linux target exclusively available for Fedora"],
          boot_tested:false,hardware_tested:false,device_write_executed:false}')
    if [[ -n $report ]]; then
        (umask 077; set -o noclobber; printf '%s\n' "$result" > "$report") || die 'Cannot create a new private report'
    fi
    printf '%s\n' "$result"
    return "$code"
}
