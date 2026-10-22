#!/usr/bin/env bash
# Offline host composer. Original Fedora desktop files are not rewritten.
set -Eeuo pipefail
# shellcheck source=src/image/filesystem-policy.sh
source /builder/src/image/filesystem-policy.sh
filesystem=$(userdata_profile_filesystem /builder/configs/images/userdata-rawhide.json)
root=/job/root
[[ $# == 0 && -f /job/packages.complete && ! -L $root && ! -e /job/rootfs-frozen ]]
[[ $(stat -c %u "$root/etc/passwd") == 0 ]]
rpm --root "$root" -q plasma-setup plasma-login-manager kde-settings-plasmalogin \
    senemos-uke-linux-kernel-mainline-singleboot \
    plasma-discover-offline-updates plasma-discover-packagekit PackageKit \
    glibc-all-langpacks ncurses dnf5-plugins shadow-utils sudo openssh-server >/dev/null
[[ -x $root/usr/bin/clear && -f $root/usr/lib/systemd/system/plasmalogin.service ]]
if rpm --root "$root" -qa --qf '%{NAME}\n' | grep -E '(^sddm|-(debuginfo|debugsource)$|^gcc$|^gdb$|^clang$|^make$)'; then exit 1; fi
awk -F: '$3>=1000 && $3!=65534 {bad=1; print "Unexpected human account: " $1 > "/dev/stderr"} END {exit bad}' "$root/etc/passwd"
chroot "$root" /usr/sbin/usermod -L root
grep -Eq '^root:(!|\*)' "$root/etc/shadow"
chroot "$root" /usr/sbin/visudo -cf /etc/sudoers
grep -Eq '^%wheel[[:space:]]+ALL=\(ALL\)[[:space:]]+ALL' "$root/etc/sudoers"
if grep -rE '^[^#].*NOPASSWD' "$root/etc/sudoers" "$root/etc/sudoers.d"; then exit 1; fi
mkdir -p "$root/etc/xdg" "$root/etc/rpm" "$root/etc/dnf" "$root/etc/yum.repos.d"
install -d -m755 "$root/etc/uke-control"
printf 'test\n' > "$root/etc/uke-control/channel"
chmod 644 "$root/etc/uke-control/channel"
chroot "$root" /usr/bin/kwriteconfig6 --file /etc/xdg/plasmasetuprc --group Accounts --key UserGroups wheel
chroot "$root" /usr/bin/systemd-sysusers /usr/lib/sysusers.d/plasma-setup-sysuser.conf
[[ ! -e $root/etc/plasma-setup-done ]]
systemctl --root="$root" enable plasma-setup.service plasmalogin.service NetworkManager.service \
    firewalld.service bluetooth.service chronyd.service upower.service
systemctl --root="$root" unmask sshd.service
systemctl --root="$root" unmask sshd.socket
systemctl --root="$root" disable sshd.service sshd.socket
systemctl --root="$root" disable nftables.service
systemctl --root="$root" set-default graphical.target
systemctl --root="$root" mask debug-shell.service NetworkManager-wait-online.service \
    uke-cdc-shell.service uke-esp32-cdc-log.service uke-boot-guard.service
[[ $(readlink "$root/etc/systemd/system/display-manager.service") == /usr/lib/systemd/system/plasmalogin.service ]]
printf 'PARTLABEL=userdata / %s defaults,noatime 0 0\n' "$filesystem" > "$root/etc/fstab"
cat /builder/configs/images/uke-persist.fstab >> "$root/etc/fstab"
install -d -m700 "$root/mnt/vendor/persist"
cat > "$root/etc/selinux/config" <<'SELINUX'
SELINUX=enforcing
SELINUXTYPE=targeted
SELINUX
# Verify the RPM-populated offline policy store before generating filesystem labels.
chroot "$root" /usr/bin/semodule -l > /job/audit/selinux-modules.txt
grep -Fxq uke-ssc /job/audit/selinux-modules.txt
grep -Fxq uke-power-profile /job/audit/selinux-modules.txt
printf '%%_install_langs all\n' > "$root/etc/rpm/macros.uke-languages"
[[ $(gpg --show-keys --with-colons /job/inputs/uke-copr-test.asc | awk -F: '$1=="fpr" {print $10; exit}') == DAFC3C5A881FB49C7167EE2D6F772E3D487BD13E ]]
install -m644 /job/inputs/uke-copr-test.asc "$root/etc/pki/rpm-gpg/RPM-GPG-KEY-uke-copr-test"
rpm --root "$root" --import /job/inputs/uke-copr-test.asc
# A channel switch is an explicit uke-control operation after installation.
stable_repo=$root/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:mcc45tr:uke-linux.repo
[[ ! -L $stable_repo ]]
if [[ -f $stable_repo ]]; then rm -- "$stable_repo"; fi
cat > "$root/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:mcc45tr:uke-linux-test.repo" <<'REPO'
[copr:copr.fedorainfracloud.org:mcc45tr:uke-linux-test]
name=Uke Linux Test
baseurl=https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test/fedora-rawhide-$basearch/
enabled=1
type=rpm-md
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-uke-copr-test
skip_if_unavailable=False
priority=40
includepkgs=senemos-uke-linux-kernel-mainline*,uke-*
REPO
# The matched slot writer validates every kernel transaction before activation.
cat > "$root/etc/dnf/dnf.conf" <<'DNF'
[main]
install_weak_deps=False
allow_vendor_change=False
installonly_limit=0
excludepkgs=kernel,kernel-core,kernel-modules*,*-debuginfo,*-debugsource
DNF
printf 'LANG=en_US.UTF-8\n' > "$root/etc/locale.conf"
printf 'localhost\n' > "$root/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost\n' > "$root/etc/hosts"
printf '# Managed by NetworkManager\n' > "$root/etc/resolv.conf"
find "$root/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -type f -delete
find "$root/var/log" "$root/var/cache" "$root/tmp" "$root/var/tmp" -mindepth 1 -depth -delete
find "$root/root" -mindepth 1 -name '.*history' -type f -delete
for file in etc/machine-id var/lib/dbus/machine-id var/lib/systemd/random-seed; do
    [[ ! -d $root/$file ]]
    if [[ -e $root/$file || -L $root/$file ]]; then unlink "$root/$file"; fi
done
: > "$root/etc/machine-id"
mkdir -p "$root/var/lib/dbus" "$root/usr/share/uke"
ln -s /etc/machine-id "$root/var/lib/dbus/machine-id"
install -m644 /builder/configs/images/userdata-rawhide.json "$root/usr/share/uke/image-profile.json"
printf 'userdata-%s-%s-device-test\n' "$filesystem" "$(jq -er .kernel_release /builder/configs/images/userdata-rawhide.json)" > "$root/usr/share/uke/image-finalized"
# A newly composed installation must run its own completion-gated growth phase.
rm -f -- "$root/var/lib/senemos/installation/online-grow-complete" "$root/var/lib/senemos/installation/online-grow-complete.tmp"
for tree in dev proc sys run; do
    if findmnt --mountpoint "$root/$tree" --noheadings >/dev/null; then
        echo 'Mounted runtime tree refused during offline finalization' >&2; exit 1
    fi
    find "$root/$tree" -mindepth 1 -depth -delete
done
echo 'Fresh Plasma Setup, locked root, PLM, offline updates and test COPR configured; kernel activation remains gated.'
