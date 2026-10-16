#!/usr/bin/env bash
# Host invocation inside a disposable AArch64 container; never run on a tablet.
set -Eeuo pipefail
[[ $# == 4 ]] || exit 2
inputs=$1 output=$2 kernel_release=$3 boot_inputs=$4
rpmkeys --import "$inputs/fedora-key.asc"
# shellcheck source=verify-rpms.sh
# shellcheck disable=SC1091
source /builder/src/image/verify-rpms.sh
verify_stage_rpms "$inputs" system
verify_stage_rpms "$inputs" identity
verify_stage_rpms "$inputs" boot
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=0 replay "$inputs/system"
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=0 replay "$inputs/identity"
boot_rpms=("$boot_inputs"/*.rpm)
dnf -y --disablerepo='*' --setopt=localpkg_gpgcheck=0 install "${boot_rpms[@]}"
# Exported OCI roots do not preserve capabilities. Restore RPM-owned metadata
# before creating an archive that explicitly includes security.capability.
rpm --restore -a
rpm -V uke-core-meta uke-desktop-metas libstdc++ uke-boot-integration uke-esp32-cdc \
    senemos-uke-linux-kernel-mainline-core senemos-uke-linux-kernel-mainline-modules \
    senemos-uke-linux-kernel-mainline-dtbs
bash /builder/src/audit/check-console-session.sh /
[[ $(rpm -q --qf '%{RELEASE}' uke-core-meta) == 4.fc44 ]]
[[ -s /usr/lib/modules/$kernel_release/dtb/qcom/sm7675-xiaomi-uke.dtb ]]
# Remove optional container/graphics packages through RPM dependency checks.
# xkeyboard-config is retained until host initramfs assembly: removing it early
# also removes kbd and dracut. The assembly tools are not target requirements.
dnf -y --disablerepo='*' --setopt=clean_requirements_on_remove=False remove \
    gnupg2 libksba fedora-logos plymouth plymouth-uke
rpm -q dnf5 dracut cpio kmod systemd systemd-udev >/dev/null
mkdir -p /boot/efi /etc/dracut.conf.d /etc/selinux /var/lib/dbus
install -m644 /usr/share/senemos/boot/uke/fstab.template /etc/fstab
# Keep the selected physical root name consistent with the initramfs and UKI.
partlabel=$(cat "$inputs/root-partlabel")
[[ $partlabel == userdata || $partlabel == linux ]]
root_options=defaults
[[ $partlabel != userdata ]] || root_options=defaults,x-systemd.growfs
printf 'PARTLABEL=%s / ext4 %s 0 1\n' "$partlabel" "$root_options" > /etc/fstab
printf 'LABEL=UKE_ESP /boot/efi vfat umask=0077,nofail 0 2\n' >> /etc/fstab
cat /builder/configs/images/uke-persist.fstab >> /etc/fstab
install -d -m700 /mnt/vendor/persist
# Fedora leaves mounted contents below /mnt unlabelled. This empty, protected
# mountpoint itself needs the normal mount-directory type in the image.
printf '/mnt/vendor/persist -d system_u:object_r:mnt_t:s0\n' > /etc/selinux/targeted/contexts/files/file_contexts.local
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
# Restore Fedora 44 release and update repositories. An upstream Rawhide COPR
# must not supply packages to this release; downstream publication is separate.
mkdir -p /etc/yum.repos.d
rm -f /etc/yum.repos.d/fedora-rawhide.repo /etc/yum.repos.d/uke-development.repo
install -Dm644 "$inputs/fedora-key.asc" /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora44
cat > /etc/yum.repos.d/fedora.repo <<'REPO'
[fedora]
name=Fedora 44 - $basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-44&arch=$basearch
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora44
REPO
cat > /etc/yum.repos.d/fedora-updates.repo <<'REPO'
[updates]
name=Fedora 44 updates - $basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f44&arch=$basearch
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora44
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
    --gzip --add "uke-bringup" --kernel-cmdline "$(cat "$inputs/kernel-cmdline")" \
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
# Container runtime markers would make systemd skip real-host SELinux setup.
tar --numeric-owner --one-file-system --xattrs --xattrs-include='security.capability' \
    --exclude='./.dockerenv' --exclude='./.containerenv' \
    --exclude='./dev' --exclude='./proc' --exclude='./sys' --exclude='./run' \
    --exclude='./builder' --exclude='./work' --exclude='./inputs' --exclude='./output' --exclude='./prototype' --exclude='./boot-inputs' --exclude='./tmp/*' \
    -C / -cpf "$output/prepared-root.tar" .
# Virtual filesystems have live directory metadata. Archive empty mountpoints
# from ordinary storage instead of reading those mounts during export.
mkdir -p "$output/api-directories"/{dev,proc,sys,run}
tar --numeric-owner --owner=0 --group=0 --mode=0755 --append \
    -f "$output/prepared-root.tar" -C "$output/api-directories" dev proc sys run
rm -r "$output/api-directories"
