#!/usr/bin/env bash
# Host-only QEMU virt fixture. Its synthetic Uke root compatible is exclusively
# an identity-gate fixture, never an admitted Uke DTB or firmware/RAM profile.
# Run in the recorded native QEMU container with four source/output paths.
set -Eeuo pipefail
[[ $# == 4 && -d $1 && -d $2 && ! -e $3/root && -d $4 ]]
kernel=$1 initrd=$2 out=$3
builder=$4
release=7.2.9-senemos-uke
image=$kernel/artifacts/fedora-44/7.2.9/output/Image
modules=$kernel/build/fedora-44/7.2.9/extracted/usr/lib/modules/$release
[[ -s $image && -d $modules && -x $initrd/usr/bin/systemctl ]]
mkdir -p "$out"
cp -a "$initrd" "$out/root"
rm -rf "$out/root/usr/lib/modules/$release"
cp -a "$modules" "$out/root/usr/lib/modules/"
cp "$builder"/src/image/dracut/91uke-bringup/*.service "$out/root/usr/lib/systemd/system/"
# These observer files exist only in the VM fixture, outside the Core payload.
cat > "$out/root/qemu-observe.sh" <<'SH'
#!/bin/sh
sleep 12
echo qemu_observer_ready
/usr/bin/uke-boot-status --identity
echo identity_exit=$?
sleep 16
systemctl show uke-initrd-shell.service -p ActiveState -p SubState -p NRestarts
journalctl -b -u uke-initrd-shell.service --no-pager -o cat
echo qemu_observer_complete
systemctl --no-block poweroff
SH
cat > "$out/root/usr/lib/systemd/system/qemu-observe.service" <<'UNIT'
[Unit]
DefaultDependencies=no
After=systemd-journald.service systemd-udevd.service
Before=initrd-switch-root.target
Conflicts=initrd-switch-root.target
[Service]
Type=oneshot
ExecStart=/bin/sh /qemu-observe.sh
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyAMA0
TimeoutStartSec=90
UNIT
ln -s ../qemu-observe.service "$out/root/usr/lib/systemd/system/initrd.target.wants/qemu-observe.service"
(cd "$out/root"; find . -print0 | sort -z | cpio --null --quiet --reproducible --owner=0:0 -o -H newc) | gzip -n > "$out/initramfs.img"
qemu-system-aarch64 --version > "$out/qemu-version.txt"
rpm -qa --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "$out/host-packages.txt"
# Repack QEMU's padded dump before the direct Linux loader adds its fixups.
# Retaining the dump's 1 MiB padding produced an invalid early FDT with the
# recorded QEMU 11.1.2 loader. Preserve the dump separately for diagnosis.
qemu-system-aarch64 -machine "virt,gic-version=3,dumpdtb=$out/virt-dump.dtb" -cpu max -m 1536 -smp 2 -display none -kernel "$image"
dtc -q -I dtb -O dtb -o "$out/virt.dtb" "$out/virt-dump.dtb"
cp "$out/virt.dtb" "$out/synthetic-identity.dtb"
fdtput -t s "$out/synthetic-identity.dtb" / compatible linux,dummy-virt xiaomi,uke qcom,sm7675
command_line='root=LABEL=UKE_LINUX rw rootfstype=ext4 rootwait console=tty0 console=ttyAMA0 earlycon=pl011,mmio32,0x09000000 rd.senemos.tty=1 senemos.debug=esp32-cdc'
vm_pid=''
cleanup() { [[ -z $vm_pid ]] || kill "$vm_pid" 2>/dev/null || true; }
trap cleanup EXIT
for profile in foreign synthetic-identity; do
    dtb=$out/virt.dtb
    [[ $profile != synthetic-identity ]] || dtb=$out/synthetic-identity.dtb
    log=$out/$profile.serial.log
    timeout --signal=TERM --kill-after=5s 180 qemu-system-aarch64 \
        -machine virt,gic-version=3 -cpu max -accel tcg,thread=single -m 1536 -smp 2 \
        -display none -nic none -monitor none -serial "file:$log" \
        -qmp tcp:127.0.0.1:4444,server=on,wait=off \
        -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 \
        -kernel "$image" -initrd "$out/initramfs.img" -dtb "$dtb" \
        -append "$command_line" > "$out/$profile.qemu.log" 2>&1 &
    vm_pid=$!
    ready=0
    for ((i=0; i<120; ++i)); do
        if [[ -f $log ]] && grep -F qemu_observer_ready "$log" >/dev/null; then ready=1; break; fi
        kill -0 "$vm_pid" 2>/dev/null || break
        sleep 1
    done
    ((ready)) || { echo "VM observer did not start: $profile" >&2; exit 1; }
    if [[ $profile == synthetic-identity ]]; then
        # Exercise VM USB keyboard input into the actual initrd VT2 shell.
        # QMP stays on this disposable container's private loopback interface.
        exec 3<>/dev/tcp/127.0.0.1/4444
        IFS= read -r -t 5 qmp_line <&3
        [[ $qmp_line == *'"QMP"'* ]]
        printf '%s\n' '{"execute":"qmp_capabilities"}' >&3
        IFS= read -r -t 5 qmp_line <&3
        [[ $qmp_line == *'"return"'* ]]
        printf '%s\n' '{"execute":"human-monitor-command","arguments":{"command-line":"sendkey ctrl-alt-f2"}}' >&3
        sleep 1
        for key in e c h o spc v m t t y o k ret; do
            printf '{"execute":"human-monitor-command","arguments":{"command-line":"sendkey %s"}}\n' "$key" >&3
            sleep 0.15
        done
        exec 3>&-
    fi
    wait "$vm_pid"
    vm_pid=''
    tr -d '\r' < "$log" > "$out/$profile.serial.txt"
    log=$out/$profile.serial.txt
    grep -F qemu_observer_complete "$log" >/dev/null
    grep -F "Linux version $release" "$log" >/dev/null
    if [[ $profile == foreign ]]; then
        grep -F identity_exit=2 "$log" >/dev/null
        grep -Fx ActiveState=inactive "$log" >/dev/null
        grep -Fx NRestarts=0 "$log" >/dev/null
    else
        grep -F identity_exit=0 "$log" >/dev/null
        grep -Fx ActiveState=active "$log" >/dev/null
        grep -Fx SubState=running "$log" >/dev/null
        grep -Fx vmttyok "$log" >/dev/null
    fi
    echo "QEMU $profile kernel/initrd/console fixture passed; no Uke hardware acceptance"
done
sha256sum "$image" "$out/initramfs.img" "$out/virt.dtb" "$out/synthetic-identity.dtb" > "$out/SHA256SUMS"
