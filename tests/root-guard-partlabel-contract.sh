#!/usr/bin/env bash
# Runs the actual guard against read-only synthetic sysfs/procfs. No disk is read.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v bwrap >/dev/null
fixture=$(mktemp -d)
trap 'status=$?; if ((status)); then cat "$fixture/result" 2>/dev/null || :; fi; rm -rf "$fixture"' EXIT
block=$(find /dev -maxdepth 2 -type b -print -quit 2>/dev/null || true)
[[ -n $block ]] || { echo 'A block inode is required for read-only stat fixtures' >&2; exit 2; }
mkdir -p "$fixture/bin" "$fixture/dev/disk/by-partlabel" "$fixture/sys/class/block" "$fixture/sys/devices/physical/block/fake1" "$fixture/sys/devices/virtual/block/fake2"
touch "$fixture/dev/fake1" "$fixture/dev/fake2"
printf '1\n' > "$fixture/sys/devices/physical/block/fake1/partition"
printf '1\n' > "$fixture/sys/devices/virtual/block/fake2/partition"
ln -s ../../devices/physical/block/fake1 "$fixture/sys/class/block/fake1"
printf '10.0 0.0\n' > "$fixture/uptime"
for tool in udevadm sleep mount dmesg; do printf '#!/bin/sh\nexit 0\n' > "$fixture/bin/$tool"; chmod 755 "$fixture/bin/$tool"; done
cat > "$fixture/bin/blkid" <<'SH'
#!/bin/sh
case "$3" in TYPE) printf '%s\n' "$FIXTURE_TYPE";; LABEL) printf '%s\n' "$FIXTURE_LABEL";; *) exit 2;; esac
SH
chmod 755 "$fixture/bin/blkid"
run_guard() {
    bwrap --ro-bind / / --ro-bind "$fixture/sys" /sys --ro-bind "$fixture/dev" /dev \
        --ro-bind "$block" /dev/fake1 --ro-bind "$block" /dev/fake2 \
        --ro-bind "$fixture/cmdline" /proc/cmdline --ro-bind "$fixture/uptime" /proc/uptime \
        --setenv PATH "$fixture/bin:/usr/bin:/bin" --setenv FIXTURE_TYPE "$type" --setenv FIXTURE_LABEL "$fslabel" \
        /bin/sh "$root/src/boot-pair/dracut/root-guard.sh" > "$fixture/result" 2>&1
}
reject() { if run_guard; then cat "$fixture/result"; echo 'Unsafe root admitted' >&2; exit 1; fi; grep -F UKE_ROOT_REJECTED "$fixture/result" >/dev/null; }
for partlabel in linux userdata; do
    printf 'root=PARTLABEL=%s rw\n' "$partlabel" > "$fixture/cmdline"
    printf 'DEVNAME=fake1\nPARTNAME=%s\n' "$partlabel" > "$fixture/sys/devices/physical/block/fake1/uevent"
    ln -sfn ../../fake1 "$fixture/dev/disk/by-partlabel/$partlabel"
    type=ext4 fslabel=UKE_LINUX
    run_guard
    grep -F "unique physical $partlabel partition contains UKE_LINUX ext4" "$fixture/result" >/dev/null
    type=f2fs; reject
    type=crypto_LUKS; reject
    type=ext4 fslabel=userdata; reject
    fslabel=UKE_LINUX
    ln -sfn ../../fake2 "$fixture/dev/disk/by-partlabel/$partlabel"; reject
    ln -sfn ../../fake1 "$fixture/dev/disk/by-partlabel/$partlabel"
    printf 'DEVNAME=fake2\nPARTNAME=%s\n' "$partlabel" > "$fixture/sys/devices/virtual/block/fake2/uevent"
    ln -s ../../devices/virtual/block/fake2 "$fixture/sys/class/block/fake2"; reject
    rm "$fixture/sys/class/block/fake2"
    mkdir -p "$fixture/sys/devices/physical/block/fake2"
    cp "$fixture/sys/devices/virtual/block/fake2/"{partition,uevent} "$fixture/sys/devices/physical/block/fake2/"
    ln -s ../../devices/physical/block/fake2 "$fixture/sys/class/block/fake2"; reject
    rm "$fixture/sys/class/block/fake2"
    printf 'DEVNAME=fake2\nPARTNAME=%s\n' "$partlabel" > "$fixture/sys/devices/physical/block/fake1/uevent"
    reject
    printf 'DEVNAME=fake1\nPARTNAME=unselected\n' > "$fixture/sys/devices/physical/block/fake1/uevent"
    reject
done
for cmdline in 'root=UUID=fixture' 'root=PARTLABEL=system' 'root=PARTLABEL=linux root=PARTLABEL=userdata' ''; do
    printf '%s\n' "$cmdline" > "$fixture/cmdline"; reject
done
echo 'Both exact root names, ext4/label/link/virtual checks and unsupported selectors passed'
