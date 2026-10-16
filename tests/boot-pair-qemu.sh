#!/usr/bin/env bash
# Generic ARM64 machine: proves real EXT4 root transition and guard behavior,
# never Qualcomm ABL/UFS/display acceptance. Root writes use disposable snapshots.
set -Eeuo pipefail
[[ $# == 1 && -s $1/correct.disk && -s $1/Image && ! -e $1/result.json ]] || exit 2
out=$(realpath "$1")
qemu-system-aarch64 --version > "$out/qemu-version.txt"
qemu-system-aarch64 -machine "virt,gic-version=3,dumpdtb=$out/virt-dump.dtb" -cpu max -m 1536 -smp 1 -display none -kernel "$out/Image"
dtc -q -I dtb -O dtb -o "$out/virt.dtb" "$out/virt-dump.dtb"
fdtput -t s "$out/virt.dtb" / compatible linux,dummy-virt xiaomi,uke qcom,sm7675
vm_pid=''
trap '[[ -z $vm_pid ]] || kill "$vm_pid" 2>/dev/null || true' EXIT
# shellcheck source=../src/boot-pair/serial-normalize.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/../src/boot-pair/serial-normalize.sh"
qmp() {
    printf '%s\n' "$1" >&3
    local response
    IFS= read -r -t 5 response <&3
    while [[ $response == *'"event"'* ]]; do IFS= read -r -t 5 response <&3; done
    [[ $response == *'"return"'* ]]
}
for name in correct changed-uuid wrong-partname wrong-fstype duplicate-partname; do
    log=$out/$name.serial.log
    timeout --signal=TERM --kill-after=5s 240 qemu-system-aarch64 \
        -machine virt,gic-version=3 -cpu max -accel tcg,thread=single -m 1536 -smp 1 \
        -display none -nic none -monitor none -serial "file:$log" \
        -qmp tcp:127.0.0.1:4444,server=on,wait=off \
        -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 \
        -drive "if=none,file=$out/$name.disk,format=raw,id=root,snapshot=on" \
        -device virtio-blk-pci,drive=root -kernel "$out/Image" -dtb "$out/virt.dtb" \
        -append 'EXTERNAL_CMDLINE_WAS_USED=1' > "$out/$name.qemu.log" 2>&1 &
    vm_pid=$!
    observed=0
    for ((i=0;i<210;++i)); do
        if [[ -s $log ]]; then
            if [[ $name == correct || $name == changed-uuid ]] && grep -F UKE_FEDORA_EXT4_ROOT_READY "$log" >/dev/null &&
               grep -F 'pid1=/usr/lib/systemd/systemd' "$log" >/dev/null &&
               grep -F selinux=1 "$log" >/dev/null &&
               grep -F 'unit=uke-screen-shell ' "$log" | grep -F 'res=success' >/dev/null; then observed=1; break; fi
            if [[ $name != correct && $name != changed-uuid ]] && grep -F UKE_ROOT_REJECTED "$log" >/dev/null; then observed=1; break; fi
        fi
        kill -0 "$vm_pid" 2>/dev/null || break
        sleep 1
    done
    normalize "$log" > "$out/$name.status.txt"
    ((observed)) || { echo "Expected root result not observed: $name" >&2; exit 1; }
    if [[ $name == correct || $name == changed-uuid ]]; then
        grep -F UKE_ROOT_ADMITTED "$out/$name.status.txt" >/dev/null
        grep -F '/dev/vda1 ext4' "$out/$name.status.txt" >/dev/null
        grep -F 'pid1=/usr/lib/systemd/systemd' "$out/$name.status.txt" >/dev/null
        grep -F selinux=1 "$out/$name.status.txt" >/dev/null
        if [[ $(jq -r '.root_partlabel // "linux"' "$out/profile.json") == userdata ]]; then
            grep -F 'EXT4-fs (vda1): resized filesystem to 819200' "$log" >/dev/null || {
                echo 'Userdata root did not grow to the larger partition' >&2; exit 1;
            }
        fi
        exec 3<>/dev/tcp/127.0.0.1/4444
        IFS= read -r -t 5 greeting <&3
        [[ $greeting == *'"QMP"'* ]]
        qmp '{"execute":"qmp_capabilities"}'
        qmp '{"execute":"human-monitor-command","arguments":{"command-line":"sendkey ctrl-alt-f1"}}'
        sleep 5
        qmp '{"execute":"human-monitor-command","arguments":{"command-line":"sendkey ctrl-u"}}'
        # echo realrootok > /dev/ttyAMA0 through the VM's actual USB keyboard.
        for key in e c h o spc r e a l r o o t o k spc shift-dot spc slash d e v slash t t y shift-a shift-m shift-a 0 ret; do
            qmp "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"sendkey $key\"}}"
            sleep 0.15
        done
        entered=0
        for ((i=0;i<15;++i)); do
            if tty_command_observed "$log"; then entered=1; break; fi
            sleep 1
        done
        ((entered)) || { echo 'Real-root local TTY keyboard command not observed' >&2; exit 1; }
        printf '%s\n' '{"execute":"quit"}' >&3
        exec 3>&-
        wait "$vm_pid"; vm_pid=''
    else
        sleep 5
        normalize "$log" > "$out/$name.status.txt"
        if grep -F UKE_FEDORA_EXT4_ROOT_READY "$out/$name.status.txt"; then echo 'Wrong root was admitted' >&2; exit 1; fi
        grep -F UKE_PROBE_SNAPSHOT_BEGIN "$out/$name.status.txt" >/dev/null
        grep -F 'UKE_PROBE_BUILD: boot-gunyah-wdt-v5' "$out/$name.status.txt" >/dev/null
        grep -F 'UKE_PROBE_CMDLINE:' "$out/$name.status.txt" >/dev/null
        grep -F UKE_PROBE_PROVIDER_ERRORS "$out/$name.status.txt" >/dev/null
        grep -F UKE_PROBE_SNAPSHOT_END "$out/$name.status.txt" >/dev/null
        if grep -Ei 'uke-root-guard.*(command not found|: not found)' "$out/$name.status.txt"; then
            echo 'Root failure diagnostics require an absent command' >&2; exit 1
        fi
        kill "$vm_pid" 2>/dev/null || true
        wait "$vm_pid" || true
        vm_pid=''
    fi
    normalize "$log" > "$out/$name.status.txt"
done
cat > "$out/result.json" <<JSON
{
  "schema_version": 1,
  "evidence_class": "generic-arm64-qemu-root-fixture",
  "kernel_sha256": "$(sha256sum "$out/Image" | cut -d ' ' -f1)",
  "test_script_sha256": "$(sha256sum "$0" | cut -d ' ' -f1)",
  "root_filesystem_growth": $(if [[ $(jq -r '.root_partlabel // "linux"' "$out/profile.json") == userdata ]]; then echo true; else echo false; fi),
  "root_partition_label": "$(jq -r '.root_partlabel // "linux"' "$out/profile.json")",
  "real_ext4_root_transition": true,
  "root_pid1_systemd": true,
  "selinux_enforcing": true,
  "local_tty_keyboard_command": true,
  "wrong_partition_name_rejected": true,
  "changed_filesystem_uuid_accepted": true,
  "wrong_filesystem_type_rejected": true,
  "duplicate_partition_name_rejected": true,
  "boot_tested": false,
  "hardware_tested": false
}
JSON
echo 'Generic ARM64 real-root, SELinux, TTY and root-rejection fixtures passed'
