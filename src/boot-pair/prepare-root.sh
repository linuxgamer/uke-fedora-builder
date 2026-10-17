#!/usr/bin/env bash
# Disposable pinned ARM64 host userspace; never invoked on the tablet.
set -Eeuo pipefail
[[ $# == 1 ]]
owner=$1
[[ $(uname -m) == aarch64 ]]
root=/job/root
trap 'if [[ $owner != none ]]; then chown -R "$owner" /job; fi' EXIT
release=7.2.9-senemos-uke
(cd /job/inputs; sha256sum -c SHA256SUMS)
rm -rf "$root"
mkdir -p "$root" /job/tmp /job/empty-config
tar --numeric-owner --same-owner --xattrs --xattrs-include='security.capability' -xf /job/inputs/prepared-root.tar -C "$root"
packages=(/job/inputs/kernel/*.aarch64.rpm)
[[ ${#packages[@]} == 4 ]]
support=(/job/inputs/support/*.aarch64.rpm)
[[ ${#support[@]} == 3 ]]
# Locally built development RPMs are admitted by the frozen input SHA256
# catalog and RPM payload digests; they do not carry the former COPR signature.
for package in "${packages[@]}" "${support[@]}"; do
    rpmkeys --root "$root" --checksig --nosignature "$package" | grep -F 'digests OK'
done
rpm --root "$root" -Uvh --replacepkgs "${packages[@]}" "${support[@]}"
rpm --root "$root" --restore senemos-uke-linux-kernel-mainline{,-core,-modules,-dtbs}
rpm --root "$root" -V senemos-uke-linux-kernel-mainline{,-core,-modules,-dtbs}
rpm --root "$root" --restore uke-boot-integration uke-esp32-cdc
rpm --root "$root" -V uke-boot-integration uke-esp32-cdc
rpm --root "$root" -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' | sort > /job/installed-rpms.tsv
variant=$(cat /job/inputs/variant)
case $variant in
    tty) bash /builder/src/audit/check-console-session.sh "$root";;
    kde|gnome) bash /builder/src/boot-pair/check-desktop-variant.sh "$root" "$variant";;
    *) echo "Unsupported pair variant: $variant" >&2; exit 1;;
esac
partlabel=$(sed -n 's/.* root=PARTLABEL=\([^ ]*\).*/\1/p' /job/inputs/kernel-cmdline)
[[ $partlabel == userdata || $partlabel == linux ]]
root_options=defaults
[[ $partlabel != userdata ]] || root_options=defaults,x-systemd.growfs
printf 'PARTLABEL=%s / ext4 %s 0 1\n' "$partlabel" "$root_options" > "$root/etc/fstab"
cat /builder/configs/images/uke-persist.fstab >> "$root/etc/fstab"
install -d -m700 "$root/mnt/vendor/persist"
profiles=$root/usr/share/senemos/boot/uke
install -Dm644 "$profiles/machine-info" "$root/etc/machine-info"
printf 'uke\n' > "$root/etc/hostname"
install -Dm644 "$profiles/fastfetch.jsonc" "$root/etc/fastfetch/config.jsonc"
install -Dm600 "$profiles/usb-network.nmconnection" "$root/etc/NetworkManager/system-connections/uke-usb-debug.nmconnection"
install -Dm644 "$profiles/usb-network-managed.conf" "$root/etc/NetworkManager/conf.d/90-uke-usb-debug.conf"
rm -f "$root/etc/systemd/system/sysinit.target.wants/debug-shell.service" \
    "$root/etc/systemd/system/multi-user.target.wants/uke-esp32-cdc-log.service" \
    "$root/etc/systemd/system/debug-shell.service.d/90-uke-core.conf"
ln -sfn /dev/null "$root/etc/systemd/system/getty@tty1.service"
if [[ $variant != tty ]]; then
    # Keep the local bring-up shell on a VT separate from the login manager.
    install -d -m755 "$root/etc/systemd/system/uke-screen-shell.service.d"
    cat > "$root/etc/systemd/system/uke-screen-shell.service.d/90-desktop-vt.conf" <<'EOF'
[Unit]
Conflicts=
Conflicts=getty@tty6.service
[Service]
TTYPath=/dev/tty6
EOF
    ln -sfn /dev/null "$root/etc/systemd/system/getty@tty6.service"
    manager=sddm
    [[ $variant != gnome ]] || manager=gdm
    ln -sfn "/usr/lib/systemd/system/$manager.service" "$root/etc/systemd/system/display-manager.service"
fi
for unit in uke-screen-shell uke-cdc-shell uke-root-status; do
    install -Dm644 "/builder/src/boot-pair/$unit.service" "$root/usr/lib/systemd/system/$unit.service"
    mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    if [[ $unit != uke-cdc-shell ]]; then
        ln -sfn "/usr/lib/systemd/system/$unit.service" "$root/etc/systemd/system/multi-user.target.wants/$unit.service"
    fi
done
rm -f "$root/etc/systemd/system/multi-user.target.wants/uke-cdc-shell.service" \
    "$root/etc/systemd/system/multi-user.target.wants/uke-cdc-acm.service"
for unit in uke-usb-network uke-usb-network-shell; do
    rm -f "$root/etc/systemd/system/multi-user.target.wants/$unit.service"
done
install -Dm755 /builder/src/boot-pair/screen-shell.sh "$root/usr/libexec/uke-screen-shell"
install -Dm755 /builder/src/boot-pair/root-status.sh "$root/usr/libexec/uke-root-status"
install -Dm644 /builder/src/boot-pair/console-printk.conf "$root/etc/sysctl.d/90-uke-console.conf"
# Automatic native-COPR updates must not silently replace the module tuple of
# this built-in-initramfs stock-ABL candidate. Update through a rebuilt pair.
printf '\nexcludepkgs=senemos-uke-linux-kernel-mainline*\n' >> "$root/etc/dnf/dnf.conf"
mkdir -p "$root/etc/systemd/journald.conf.d"
printf '[Journal]\nStorage=persistent\nSystemMaxUse=64M\nSystemMaxFileSize=8M\n' > "$root/etc/systemd/journald.conf.d/90-uke-bringup.conf"
rm -f "$root/etc/modules-load.d/uke-esp32.conf"
printf 'g_serial\n' > "$root/etc/modules-load.d/uke-cdc.conf"
early_firmware=()
early_drivers=()
if [[ -s /job/inputs/early-firmware.tar ]]; then
    # The ADSP announces QRTR services during firmware startup. Load the
    # transport and the in-kernel domain mapper before udev can start it.
    # The previous trial lacked early ADSP services until a DSP restart;
    # this ordering candidate still requires a fresh physical boot.
    early_drivers=(qrtr_smd qcom_pd_mapper)
    manifest=/job/early-firmware.sha256
    [[ $(sha256sum /job/inputs/early-firmware.tar | cut -d ' ' -f1) == $(awk '$1=="#archive-sha256" {print $2}' "$manifest") ]]
    mkdir -p "$root/usr/lib/firmware"
    tar --no-same-owner -xf /job/inputs/early-firmware.tar -C "$root/usr/lib/firmware"
    bash /builder/src/boot-pair/check-early-firmware.sh "$root" "$manifest"
    while read -r expected path; do
        [[ $expected != \#* ]] || continue
        early_firmware+=(--include "$root/$path" "/$path")
    done < "$manifest"
fi
chroot "$root" /usr/bin/depmod "$release"
# Temporarily install the exact signed host assembly dependency closure in
# this disposable native root. Remove it through RPM before target export.
# Avoid cross-sysroot guesses about upstream dracut hooks.
rpmkeys --root "$root" --import /builder/configs/keys/fedora-44.asc
temporary_rpms=()
temporary_names=()
for package in /job/inputs/host-rpms/*.rpm; do
    rpmkeys --root "$root" --checksig "$package" | grep -F 'signatures OK'
    name=$(rpm -qp --qf '%{NAME}' "$package")
    if rpm --root "$root" -q "$name" >/dev/null 2>&1; then
        [[ $(rpm --root "$root" -q --qf '%{NEVRA}' "$name") == "$(rpm -qp --qf '%{NEVRA}' "$package")" ]]
    else
        temporary_rpms+=("$package")
        temporary_names+=("$name")
    fi
done
if ((${#temporary_rpms[@]})); then rpm --root "$root" -Uvh "${temporary_rpms[@]}"; fi
mkdir -p "$root/usr/lib/dracut/modules.d/92uke-abl"
install -m644 /builder/src/boot-pair/dracut/* "$root/usr/lib/dracut/modules.d/92uke-abl/"
chmod 755 "$root/usr/lib/dracut/modules.d/92uke-abl/module-setup.sh"
# Upstream --sysroot resolves both hooks and target dependencies from this
# signed temporary installation, while host /proc and /dev remain available.
dracut --sysroot "$root" \
    --conf /dev/null --confdir /job/empty-config --tmpdir /job/tmp \
    --force --no-hostonly --no-hostonly-cmdline --no-early-microcode --gzip \
    --add "uke-abl" --kernel-cmdline "$(cat /job/inputs/kernel-cmdline)" \
    --force-drivers "${early_drivers[*]} ufs_qcom phy_qcom_qmp_ufs qcom_battmgr dwc3_qcom phy_msm_snps_eusb2_uke repeater_qti_pmic_eusb2_uke i2c_qcom_geni gpi ktz8866" \
    --filesystems ext4 --omit 'network plymouth crypt systemd-cryptsetup syslog lvm mdraid btrfs i18n' \
    "${early_firmware[@]}" \
    /job/initramfs.cpio.gz "$release"
[[ -s /job/initramfs.cpio.gz ]]
if ((${#temporary_names[@]})); then rpm --root "$root" -e "${temporary_names[@]}"; fi
rm -rf "$root/usr/lib/dracut/modules.d/92uke-abl"
rpm --root "$root" -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' | sort > /job/final-rpms.tsv
[[ $(sha256sum /job/final-rpms.tsv | cut -d ' ' -f1) == $(sha256sum /job/installed-rpms.tsv | cut -d ' ' -f1) ]]
cp /job/initramfs.cpio.gz "$root/boot/initramfs-$release.img"
rm -rf "$root/var/log/"* "$root/var/cache/dnf"* "$root/tmp/"* "$root/var/tmp/"*
rm -f "$root/etc/ssh/ssh_host_"* "$root/var/lib/systemd/random-seed" "$root/root/.bash_history"
: > "$root/etc/machine-id"
tar --numeric-owner --xattrs --xattrs-include='security.capability' -cpf /job/pair-root.tar -C "$root" .
(cd /job; sha256sum pair-root.tar > pair-root.sha256)
printf '%s\n' 'Pinned ARM64 root RPM replacement and root-capable dracut assembly complete'
