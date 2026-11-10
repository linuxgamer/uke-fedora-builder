#!/usr/bin/env bash
# Host invocation inside a disposable AArch64 container; never run on a tablet.
set -Eeuo pipefail
[[ $# == 4 ]] || exit 2
inputs=$1 output=$2 kernel_release=$3 boot_inputs=$4
rpmkeys --import "$inputs/fedora-key.asc"
rpmkeys --import "$inputs/copr-key.asc"
for archive in "$inputs"/system/packages/*.rpm "$inputs"/identity/packages/*.rpm; do
    rpmkeys --checksig "$archive" | grep -F 'signatures OK' >/dev/null
    arch=$(rpm -qp --qf '%{ARCH}' "$archive")
    [[ $arch == aarch64 || $arch == noarch ]]
done
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=1 replay "$inputs/system"
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=1 replay "$inputs/identity"
boot_rpms=("$boot_inputs/uke-boot-integration-0.1.0-4.fc46.aarch64.rpm"
    "$boot_inputs/uke-esp32-cdc-0.1.0-4.fc46.aarch64.rpm")
for boot_rpm in "${boot_rpms[@]}"; do
    rpmkeys --checksig "$boot_rpm" | grep -F 'signatures OK' >/dev/null
    [[ $(rpm -qp --qf '%{ARCH}' "$boot_rpm") == aarch64 ]]
done
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=1 install "${boot_rpms[@]}"
# Exported OCI roots do not preserve capabilities. Restore RPM-owned metadata
# before creating an archive that explicitly includes security.capability.
rpm --restore -a
rpm -V uke-core-meta uke-desktop-metas libstdc++ uke-boot-integration uke-esp32-cdc \
    senemos-uke-linux-kernel-mainline-core senemos-uke-linux-kernel-mainline-modules \
    senemos-uke-linux-kernel-mainline-dtbs
if rpm -qa --qf '%{NAME}\n' | grep -Ei '^plasma-workspace$|^dolphin$|^kde-plasma-uke-meta$'; then exit 1; fi
[[ $(rpm -q --qf '%{RELEASE}' uke-core-meta) == 3.fc46 ]]
[[ -s /usr/lib/modules/$kernel_release/dtb/qcom/sm7675-xiaomi-uke.dtb ]]
# Remove optional container/graphics packages through RPM dependency checks.
# xkeyboard-config is retained until host initramfs assembly: removing it early
# also removes kbd and dracut. The assembly tools are not target requirements.
dnf -y --disablerepo='*' --setopt=clean_requirements_on_remove=False remove \
    gnupg2 libksba fedora-logos plymouth plymouth-uke
rpm -q dnf5 dracut cpio kmod systemd systemd-udev >/dev/null
mkdir -p /boot/efi /etc/dracut.conf.d /etc/selinux /var/lib/dbus
install -m644 /usr/share/senemos/boot/uke/fstab.template /etc/fstab
# Filesystem identities survive partition resizing and fastboot partition names.
cat > /etc/fstab <<'FSTAB'
LABEL=UKE_LINUX / ext4 defaults,noatime,errors=remount-ro 0 1
LABEL=UKE_ESP /boot/efi vfat umask=0077,nofail 0 2
FSTAB
cat /builder/configs/images/uke-persist.fstab >> /etc/fstab
install -d -m700 /mnt/vendor/persist
cat > /etc/selinux/config <<'SELINUX'
SELINUX=enforcing
SELINUXTYPE=targeted
SELINUX
install -m644 /usr/share/senemos/boot/uke/dracut.conf /etc/dracut.conf.d/90-uke-image.conf
systemctl set-default multi-user.target
systemctl enable NetworkManager.service
systemctl mask NetworkManager-wait-online.service
# Core-only development access: the original debug shell receives HID input on
# VT2; all output goes through journald and its single ESP32 CDC writer.
mkdir -p /etc/systemd/system/debug-shell.service.d /etc/modules-load.d
install -m644 /usr/share/senemos/boot/uke/debug-shell-esp32.conf \
    /etc/systemd/system/debug-shell.service.d/90-uke-core.conf
systemctl enable debug-shell.service uke-esp32-cdc-log.service
systemctl mask getty@tty2.service
printf 'cdc_acm\n' > /etc/modules-load.d/uke-esp32.conf
# No root password, copied credentials, private keys or host machine identity.
[[ $(getent shadow root | cut -d: -f2) == '!'* ]]
systemctl disable sshd.service >/dev/null 2>&1 || true
rm -f /etc/ssh/ssh_host_* /etc/machine-id /var/lib/dbus/machine-id
rm -f /var/lib/systemd/random-seed
: > /etc/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
printf 'localhost\n' > /etc/hostname
printf '127.0.0.1 localhost\n::1 localhost\n' > /etc/hosts
printf '# Managed by NetworkManager\n' > /etc/resolv.conf
rm -rf /var/log/* /var/cache/dnf* /var/lib/dnf /root/.bash_history /tmp/*
# The original source package leaves empty repo configuration in its OCI base.
# Restore ordinary Fedora Rawhide updates; COPR uses the verified public key.
mkdir -p /etc/yum.repos.d
install -Dm644 "$inputs/fedora-key.asc" /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora46
cat > /etc/yum.repos.d/fedora-rawhide.repo <<'REPO'
[rawhide]
name=Fedora Rawhide - $basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=rawhide&arch=$basearch
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora46
REPO
install -m644 "$inputs/copr-key.asc" /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-copr
cat > /etc/yum.repos.d/uke-development.repo <<'REPO'
[copr-uke-development]
name=Senemos Uke development packages
baseurl=https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test/fedora-rawhide-$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-uke-copr
REPO
cat > /etc/dnf/dnf.conf <<'DNF'
[main]
install_weak_deps=False
allow_vendor_change=False
DNF
depmod "$kernel_release"
mkdir -p /usr/lib/dracut/modules.d/91uke-bringup
install -m644 /builder/src/image/dracut/91uke-bringup/* /usr/lib/dracut/modules.d/91uke-bringup/
chmod 755 /usr/lib/dracut/modules.d/91uke-bringup/module-setup.sh
# Use only installed modules; no host controller, root UUID or firmware guesses.
dracut --force --no-hostonly --no-hostonly-cmdline --no-early-microcode \
    --gzip --add uke-bringup --kernel-cmdline 'root=LABEL=UKE_LINUX rw rootfstype=ext4 rootwait console=tty0 rd.senemos.tty=1 senemos.debug=esp32-cdc' \
    --filesystems ext4 --omit 'network plymouth crypt systemd-cryptsetup syslog lvm mdraid btrfs i18n' \
    "/boot/initramfs-$kernel_release.img" "$kernel_release"
# Initramfs generation is host composition only. Remove its host-assembly RPMs
# after generation, with full dependency checks; never redact RPM-owned bytes.
# On-device regeneration/UKI activation still needs a separately admitted flow.
dnf -y --disablerepo='*' --setopt=clean_requirements_on_remove=False remove dracut xkeyboard-config file file-libs
# Remove host-only setup files left by the explicitly installed module directory.
rm -rf /usr/lib/dracut/modules.d/91uke-bringup
rpm -q dnf5 cpio kmod systemd systemd-udev uke-boot-integration uke-esp32-cdc >/dev/null
[[ -s /boot/initramfs-$kernel_release.img ]]
rm -rf /var/log/* /var/cache/dnf* /var/lib/dnf /root/.bash_history /tmp/*
rpm -qa --qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{LICENSE}\n' | sort > "$output/installed-rpms.tsv"
getcap -r /usr > "$output/capabilities.txt"
tar --numeric-owner --one-file-system --xattrs --xattrs-include='security.capability' \
    --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' --exclude='./run/*' \
    --exclude='./builder' --exclude='./work' --exclude='./inputs' --exclude='./output' --exclude='./prototype' --exclude='./boot-inputs' --exclude='./tmp/*' \
    -C / -cpf "$output/prepared-root.tar" .
