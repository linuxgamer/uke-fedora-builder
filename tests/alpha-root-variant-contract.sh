#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/input/etc/cmdline.d" "$fixture/input/usr/libexec" "$fixture/input/usr/lib/systemd/system/initrd.target.wants" \
    "$fixture/input/usr/lib/firmware" "$fixture/input/etc/NetworkManager/system-connections" "$fixture/input/root/.ssh"
cat > "$fixture/base.config" <<'CONFIG'
CONFIG_INITRAMFS_SOURCE="/project/private.cpio.gz"
CONFIG_CMDLINE="rdinit=/usr/lib/systemd/systemd root=PARTLABEL=linux rw rootfstype=ext4 senemos.debug=cdc-acm console=tty0"
CONFIG_CMDLINE_FORCE=y
CONFIG
printf 'root=PARTLABEL=linux rw senemos.debug=cdc-acm console=tty0\n' > "$fixture/input/etc/cmdline.d/10-default.conf"
printf 'rd.driver.pre=qrtr_smd\nrd.driver.pre=qcom_pd_mapper\nrd.driver.pre=qcom_battmgr\nrd.driver.pre=ufs_qcom\n' > "$fixture/input/etc/cmdline.d/20-force_drivers.conf"
printf 'root::0:0::/root:/bin/sh\n' > "$fixture/input/etc/passwd"
printf 'root:private-password-hash:1:0:99999:7:::\n' > "$fixture/input/etc/shadow"
printf 'private-machine-identity\n' > "$fixture/input/etc/machine-id"
chmod 444 "$fixture/input/etc/machine-id"
cp "$root/src/boot-pair/dracut/root-guard.sh" "$fixture/input/usr/libexec/uke-root-guard"
chmod 755 "$fixture/input/usr/libexec/uke-root-guard"
printf 'private-firmware\n' > "$fixture/input/usr/lib/firmware/adsp.mdt"
printf 'private-key\n' > "$fixture/input/root/.ssh/authorized_keys"
printf 'private-network\n' > "$fixture/input/etc/NetworkManager/system-connections/test"
ln -s ../uke-cdc-shell.service "$fixture/input/usr/lib/systemd/system/initrd.target.wants/uke-cdc-shell.service"
for label in linux userdata; do
    out=$fixture/$label
    bash "$root/src/boot-pair/prepare-alpha-variant.sh" "$fixture/base.config" "$fixture/input" "$label" "$out" "/project/build/$label/initramfs.cpio.gz"
    grep -F "root=PARTLABEL=$label " "$out/kernel.config" >/dev/null
    grep -F "root=PARTLABEL=$label " "$out/initramfs-root/etc/cmdline.d/10-default.conf" >/dev/null
    [[ ! -e $out/initramfs-root/usr/lib/firmware && ! -e $out/initramfs-root/root && ! -e $out/initramfs-root/etc/NetworkManager/system-connections ]]
    [[ ! -e $out/initramfs-root/etc/shadow ]]
    [[ ! -s $out/initramfs-root/etc/machine-id ]]
    [[ ! -L $out/initramfs-root/usr/lib/systemd/system/initrd.target.wants/uke-cdc-shell.service ]]
    grep -F 'root:!:' "$out/initramfs-root/etc/passwd" >/dev/null
    grep -Fx rd.driver.pre=ufs_qcom "$out/initramfs-root/etc/cmdline.d/20-force_drivers.conf" >/dev/null
    if grep -E 'senemos.debug|qrtr_smd|qcom_pd_mapper|qcom_battmgr' "$out/kernel.config" "$out/initramfs-root/etc/cmdline.d/"*; then exit 1; fi
    (cd "$out"; sha256sum -c SHA256SUMS)
done
# The primary recipe now supplies a userdata source; conversion must work both ways.
sed 's/root=PARTLABEL=linux /root=PARTLABEL=userdata /' "$fixture/base.config" > "$fixture/userdata.config"
sed -i 's/root=PARTLABEL=linux /root=PARTLABEL=userdata /' "$fixture/input/etc/cmdline.d/10-default.conf"
bash "$root/src/boot-pair/prepare-alpha-variant.sh" "$fixture/userdata.config" "$fixture/input" linux "$fixture/from-userdata" /project/build/from-userdata/initramfs.cpio.gz
grep -F 'root=PARTLABEL=linux ' "$fixture/from-userdata/kernel.config" >/dev/null
grep -F 'root=PARTLABEL=linux ' "$fixture/from-userdata/initramfs-root/etc/cmdline.d/10-default.conf" >/dev/null
sed -i 's/root=PARTLABEL=userdata /root=PARTLABEL=linux /' "$fixture/input/etc/cmdline.d/10-default.conf"
reject() { if bash "$root/src/boot-pair/prepare-alpha-variant.sh" "$@" >/dev/null 2>&1; then echo 'Unsafe variant request accepted' >&2; exit 1; fi; }
reject "$fixture/base.config" "$fixture/input" system "$fixture/bad" /project/build/test.cpio.gz
reject "$fixture/base.config" "$fixture/input" linux "$fixture/linux" /project/build/test.cpio.gz
reject "$fixture/base.config" "$fixture/input" linux "$fixture/bad" /tmp/unreviewed/test.cpio.gz
printf 'CONFIG_CMDLINE="root=PARTLABEL=userdata rw"\n' >> "$fixture/base.config"
reject "$fixture/base.config" "$fixture/input" linux "$fixture/bad" /project/build/test.cpio.gz
echo 'Alpha boot selector, sanitization, locked debug and input refusal contracts passed'
