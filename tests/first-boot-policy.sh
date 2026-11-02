#!/usr/bin/env bash
# Real EXT4 metadata growth on a private regular file, never a host block device.
set -Eeuo pipefail
builder=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../src/public/first-boot-policy.sh
# shellcheck disable=SC1091
source "$builder/src/public/first-boot-policy.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
reject() { if "$@" > "$work/rejected" 2>&1; then echo "Incomplete root capacity accepted: $*" >&2; exit 1; fi; }
public_ext4_full_capacity 8589934592 2097152 4096 > /dev/null
public_ext4_full_capacity 549755813888 134217728 4096 > /dev/null
reject public_ext4_full_capacity 549755813888 2097152 4096
reject public_ext4_full_capacity 8589934592 2097153 4096
reject public_ext4_full_capacity 0 1 4096
reject public_ext4_full_capacity 999999999999999999999999 1 4096
reject public_ext4_full_capacity 8589934592 2097152 0
reject public_ext4_full_capacity '1; exit 0' 1 4096
# Use the real distribution formatter: its aligned MAJ:MIN column contains
# padding even with --noheadings. A mocked unpadded string misses this failure.
printf '10 1 8:32 / / rw,relatime - ext4 /dev/sda32 rw\n' > "$work/mountinfo"
aligned=$(findmnt -kn -F "$work/mountinfo" -o MAJ:MIN /)
raw=$(findmnt -krn -F "$work/mountinfo" -o MAJ:MIN /)
[[ $aligned != "$raw" && $raw == 8:32 ]]
[[ ! $aligned =~ ^[0-9]+:[0-9]+$ && $raw =~ ^[0-9]+:[0-9]+$ ]]
public_capacity_command > "$work/capacity-command"
grep -Fxq "devno=\$(findmnt -rn -o MAJ:MIN /)" "$work/capacity-command"
grep -Fxq "test \"\$(findmnt -rn -o FSTYPE /)\" = ext4" "$work/capacity-command"
truncate -s 32M "$work/ext4.raw"
mkfs.ext4 -q -F -L UKE_LINUX "$work/ext4.raw"
printf 'retained payload\n' > "$work/payload"
debugfs -w -R "write $work/payload /payload" "$work/ext4.raw" > "$work/write.log" 2>&1
truncate -s 96M "$work/ext4.raw"
geometry() { dumpe2fs -h "$work/ext4.raw" 2>/dev/null | awk -F: '/^Block count:/{blocks=$2+0} /^Block size:/{size=$2+0} END{print blocks,size}'; }
read -r blocks size < <(geometry)
reject public_ext4_full_capacity 100663296 "$blocks" "$size"
e2fsck -f -p "$work/ext4.raw" > "$work/fsck.log" 2>&1
resize2fs "$work/ext4.raw" > "$work/resize.log" 2>&1
read -r blocks size < <(geometry)
public_ext4_full_capacity 100663296 "$blocks" "$size"
resize2fs "$work/ext4.raw" >> "$work/resize.log" 2>&1
read -r blocks size < <(geometry)
public_ext4_full_capacity 100663296 "$blocks" "$size" > /dev/null
debugfs -R 'cat /payload' "$work/ext4.raw" > "$work/readback" 2>/dev/null
cmp "$work/payload" "$work/readback"
[[ $(e2label "$work/ext4.raw") == UKE_LINUX ]]
# Check the actual composition routine without touching the host's systemd tree.
mkdir -p "$work/root/usr/bin" "$work/root/usr/libexec/senemos-uke" "$work/root/usr/lib/systemd/system" "$work/bin"
for tool in usr/bin/clear usr/bin/uke-control usr/libexec/senemos-uke/uke-install-profile usr/lib/systemd/systemd-growfs; do
    printf '#!/bin/sh\nexit 0\n' > "$work/root/$tool"; chmod +x "$work/root/$tool"
done
: > "$work/root/usr/lib/systemd/system/systemd-growfs-root.service"
mkdir -p "$work/root/var/lib/senemos/installation"
printf 'stale\n' > "$work/root/var/lib/senemos/installation/online-grow-complete"
systemctl() {
    case $* in
        *' mask '*) ln -s /dev/null "$work/root/etc/systemd/system/uke-root-grow.service";;
        *' is-enabled '*) echo enabled;;
        *) :;;
    esac
}
systemd-analyze() { :; }
public_first_boot_policy "$work/root" "$work/policy.json"
[[ ! -e $work/root/var/lib/senemos/installation/online-grow-complete && $(< "$work/root/var/lib/uke-control/swap-policy") == half ]]
grep -Fq 'Requires=systemd-growfs-root.service' "$work/root/etc/systemd/system/uke-root-capacity.service"
grep -Fq 'After=uke-root-capacity.service uke-swap-ready.service' "$work/root/etc/systemd/system/plasma-setup.service.d/20-storage-ready.conf"
grep -Fq 'After=uke-root-capacity.service uke-swap-ready.service' "$work/root/etc/systemd/system/gdm.service.d/20-storage-ready.conf"
grep -Fq 'ExecStart=/usr/bin/uke-control swap apply' "$work/root/etc/systemd/system/uke-swap-ready.service"
grep -Fq '%%s' "$work/root/etc/systemd/system/uke-root-capacity.service"
jq -e '.duplicate_grow_service_masked and .capacity_gate_before_setup and .swap_after_capacity' "$work/policy.json" >/dev/null
echo 'Private EXT4 grows to device-sized capacity, preserves its label/data and repeats safely; stale markers, undersized filesystems and unsafe geometry reject.'
