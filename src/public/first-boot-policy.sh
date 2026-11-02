#!/usr/bin/env bash
# Host composition of standard systemd growth and an independent read-only gate.
public_ext4_full_capacity() {
    local capacity=$1 blocks=$2 block_size=$3 filesystem gap
    [[ $capacity =~ ^[1-9][0-9]{0,12}$ && $blocks =~ ^[1-9][0-9]{0,12}$ && $block_size =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    ((capacity <= 2199023255552 && block_size >= 1024 && block_size <= 65536 && blocks <= capacity / block_size)) || return 1
    filesystem=$((blocks * block_size))
    gap=$((capacity - filesystem))
    ((gap >= 0 && gap < block_size)) || {
        printf 'EXT4 capacity incomplete: filesystem=%s partition=%s gap=%s\n' "$filesystem" "$capacity" "$gap" >&2
        return 1
    }
    printf 'EXT4 full capacity verified: filesystem=%s partition=%s block_size=%s\n' "$filesystem" "$capacity" "$block_size"
}

public_capacity_command() {
    declare -f public_ext4_full_capacity
    cat <<'COMMAND'
set -o pipefail
test "$(/usr/libexec/senemos-uke/uke-install-profile check)" = userdata
test "$(findmnt -rn -o FSTYPE /)" = ext4
devno=$(findmnt -rn -o MAJ:MIN /)
[[ $devno =~ ^[0-9]+:[0-9]+$ ]]
device=/dev/block/$devno
test -b "$device"
read -r hex_major hex_minor < <(stat -Lc '%t %T' "$device")
[[ $hex_major =~ ^[0-9a-fA-F]{1,8}$ && $hex_minor =~ ^[0-9a-fA-F]{1,8}$ ]]
test "$((16#$hex_major)):$((16#$hex_minor))" = "$devno"
capacity=$(blockdev --getsize64 "$device")
header=$(LC_ALL=C dumpe2fs -h "$device" 2>/dev/null)
blocks=$(printf '%s\n' "$header" | sed -n 's/^Block count: *//p')
block_size=$(printf '%s\n' "$header" | sed -n 's/^Block size: *//p')
public_ext4_full_capacity "$capacity" "$blocks" "$block_size"
COMMAND
}

public_first_boot_policy() {
    local root=$1 receipt=$2 command unit
    [[ -d $root && ! -L $root && $root != / ]] || return 1
    [[ -x $root/usr/bin/clear && -x $root/usr/bin/uke-control && -x $root/usr/libexec/senemos-uke/uke-install-profile &&
       -x $root/usr/lib/systemd/systemd-growfs && -f $root/usr/lib/systemd/system/systemd-growfs-root.service ]] || return 1
    mkdir -p "$root/etc/systemd/system" "$root/var/lib/uke-control" "$root/etc/systemd/journald.conf.d"
    # One writer only: fstab/generator + the original Fedora root grow service.
    if [[ ! -L $root/etc/systemd/system/uke-root-grow.service || $(readlink "$root/etc/systemd/system/uke-root-grow.service") != /dev/null ]]; then
        systemctl --root="$root" disable uke-root-grow.service
        systemctl --root="$root" mask uke-root-grow.service
    fi
    rm -f -- "$root/var/lib/senemos/installation/online-grow-complete" "$root/var/lib/senemos/installation/online-grow-complete.tmp"
    printf 'half\n' > "$root/var/lib/uke-control/swap-policy"
    chmod 600 "$root/var/lib/uke-control/swap-policy"
    command=$(public_capacity_command)
    command=${command//\\/\\\\}; command=${command//\"/\\\"}
    command=${command//\$/\$\$}; command=${command//$'\n'/\\n}
    command=${command//%/%%}
    cat > "$root/etc/systemd/system/uke-root-capacity.service" <<UNIT
[Unit]
Description=Verify the grown Uke EXT4 root against its physical userdata capacity
Requires=systemd-growfs-root.service
After=systemd-growfs-root.service local-fs.target
Before=uke-control.service uke-swap-ready.service systemd-user-sessions.service display-manager.service plasma-setup.service

[Service]
Type=oneshot
Environment=LC_ALL=C
ExecStart=/usr/bin/bash -euc "$command"
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
UNIT
    mkdir -p "$root/etc/systemd/system/uke-control.service.d"
    printf '[Unit]\nRequires=uke-root-capacity.service\nAfter=uke-root-capacity.service\n' > "$root/etc/systemd/system/uke-control.service.d/20-root-capacity.conf"
    cat > "$root/etc/systemd/system/uke-swap-ready.service" <<'UNIT'
[Unit]
Description=Apply the existing Uke half-RAM disk swap policy before graphical setup
Requires=uke-root-capacity.service
Wants=uke-control.service
After=uke-root-capacity.service uke-control.service
Before=systemd-user-sessions.service display-manager.service plasma-setup.service

[Service]
Type=oneshot
ExecStart=/usr/bin/uke-control swap apply
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
UNIT
    for unit in systemd-user-sessions.service gdm.service plasmalogin.service plasma-setup.service; do
        mkdir -p "$root/etc/systemd/system/$unit.d"
        printf '[Unit]\nRequires=uke-root-capacity.service uke-swap-ready.service\nAfter=uke-root-capacity.service uke-swap-ready.service\n' > "$root/etc/systemd/system/$unit.d/20-storage-ready.conf"
    done
    # Preserve diagnostics even when the display manager cannot show a login.
    printf '[Journal]\nStorage=persistent\nSystemMaxUse=64M\nRuntimeMaxUse=16M\n' > "$root/etc/systemd/journald.conf.d/20-uke-persistent.conf"
    systemctl --root="$root" enable uke-root-capacity.service uke-swap-ready.service uke-control.service
    [[ $(readlink "$root/etc/systemd/system/uke-root-grow.service") == /dev/null ]]
    [[ $(systemctl --root="$root" is-enabled uke-root-capacity.service) == enabled &&
       $(systemctl --root="$root" is-enabled uke-swap-ready.service) == enabled &&
       $(systemctl --root="$root" is-enabled uke-control.service) == enabled ]]
    systemd-analyze --root="$root" verify uke-root-capacity.service uke-swap-ready.service || return
    jq -n '{root_growth:"original-systemd-growfs-root",root_selector:"PARTLABEL=userdata",
        duplicate_grow_service_masked:true,capacity_gate_before_setup:true,swap_policy:"half",
        swap_backend:"existing-uke-control-disk-swap",swap_after_capacity:true,clear_binary_verified:true,
        persistent_journal:true,hardware_tested:false}' > "$receipt"
}
