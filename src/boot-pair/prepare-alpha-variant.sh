#!/usr/bin/env bash
# Host-only: prepare a public boot variant from a preserved matching initramfs.
set -Eeuo pipefail
[[ $# == 5 ]] || { echo 'Usage: prepare-alpha-variant.sh CONFIG INITRAMFS_ROOT linux|userdata NEW_OUTPUT CONTAINER_ARCHIVE_PATH' >&2; exit 2; }
config=$1 init=$2 partlabel=$3 out=$4 archive_path=$5
[[ -f $config && ! -L $config && -d $init && ! -L $init && ! -e $out && ! -L $out ]] || exit 2
[[ $partlabel == linux || $partlabel == userdata ]] || exit 2
[[ $archive_path =~ ^/project/[A-Za-z0-9_./-]+$ && $archive_path != *'..'* ]] || exit 2
root=$(cd "$(dirname "$0")/../.." && pwd)
grep -Fx 'CONFIG_CMDLINE_FORCE=y' "$config" >/dev/null
[[ $(grep -c '^CONFIG_CMDLINE=' "$config") == 1 && $(grep -c '^CONFIG_INITRAMFS_SOURCE=' "$config") == 1 ]]
cmdline=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$config")
[[ $(printf '%s\n' "$cmdline" | tr ' ' '\n' | grep -c '^root=') == 1 && " $cmdline " == *' root=PARTLABEL=linux '* ]]
[[ -x $init/usr/libexec/uke-root-guard && -s $init/etc/cmdline.d/10-default.conf ]]
[[ $(grep -roE 'root=[^[:space:]]+' "$init/etc/cmdline.d" | wc -l) == 1 ]]
grep -F 'root=PARTLABEL=linux ' "$init/etc/cmdline.d/10-default.conf" >/dev/null
# A stale hand-written mount must not override dracut's command-line generator.
[[ ! -e $init/etc/systemd/system/sysroot.mount && ! -e $init/usr/lib/systemd/system/sysroot.mount ]]
mkdir -p "$out/initramfs-root"
cp -a "$init/." "$out/initramfs-root/"
public=$out/initramfs-root
# OEM firmware and device provisioning have no redistribution admission here.
rm -rf "${public:?}/usr/lib/firmware" "$public/lib/firmware" \
    "$public/etc/NetworkManager/system-connections" "$public/etc/wpa_supplicant" \
    "$public/etc/ssh" "$public/var/lib/NetworkManager" "$public/var/log" \
    "$public/root" "${public:?}/home"
rm -f "$public/etc/"{shadow,gshadow}* "$public/etc/"{passwd-,group-,.pwd.lock} "$public/var/lib/systemd/random-seed"
find "$public/etc" -type f \( -name 'ssh_host_*' -o -name 'authorized_keys' -o -name '*~' \) -delete
if [[ -f $public/etc/machine-id ]]; then chmod u+w "$public/etc/machine-id"; : > "$public/etc/machine-id"; fi
if [[ -f $public/etc/passwd ]]; then sed -i 's/^root:[^:]*:/root:!:/' "$public/etc/passwd"; fi
for unit in uke-cdc-acm uke-cdc-shell uke-initrd-screen uke-usb-network uke-usb-network-shell debug-shell; do
    find "$public/etc/systemd" "$public/usr/lib/systemd" -type l -name "$unit.service" -delete 2>/dev/null || :
done
if [[ -f $public/etc/cmdline.d/20-force_drivers.conf ]]; then
    sed -i '/^rd.driver.pre=\(qrtr_smd\|qcom_pd_mapper\|qcom_battmgr\)$/d' "$public/etc/cmdline.d/20-force_drivers.conf"
fi
install -m755 "$root/src/boot-pair/dracut/root-guard.sh" "$out/initramfs-root/usr/libexec/uke-root-guard"
install -m644 "$root/src/boot-pair/dracut/uke-root-guard.service" "$out/initramfs-root/usr/lib/systemd/system/uke-root-guard.service"
sed -e "s/root=PARTLABEL=linux /root=PARTLABEL=$partlabel /" -e 's/ senemos.debug=[^[:space:]]*//g' "$init/etc/cmdline.d/10-default.conf" > "$out/initramfs-root/etc/cmdline.d/10-default.conf"
awk -v label="$partlabel" -v archive="$archive_path" '
    /^CONFIG_CMDLINE=/ {sub(/root=PARTLABEL=linux /, "root=PARTLABEL=" label " "); gsub(/ senemos.debug=[^ \042]*/, "")}
    /^CONFIG_INITRAMFS_SOURCE=/ {$0="CONFIG_INITRAMFS_SOURCE=\"" archive "\""}
    {print}
' "$config" > "$out/kernel.config"
bash "$root/src/audit/check-target-elf.sh" "$out/initramfs-root"
bash "$root/src/audit/check-target-privacy.sh" "$out/initramfs-root"
epoch=${SOURCE_DATE_EPOCH:-1791024250}
[[ $epoch =~ ^[0-9]+$ ]]
find "$out/initramfs-root" -exec touch -h -d "@$epoch" {} +
(cd "$out/initramfs-root"; find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --reproducible --owner=0:0 --quiet | gzip -n -9 > ../initramfs.cpio.gz)
printf '%s\n' "$partlabel" > "$out/root-partlabel"
(cd "$out"; sha256sum kernel.config initramfs.cpio.gz root-partlabel > SHA256SUMS)
printf 'Prepared PARTLABEL=%s; unchanged kernel source/modules still require a matched Image link and separate physical test.\n' "$partlabel"
