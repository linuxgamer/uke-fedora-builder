#!/usr/bin/env bash
# Host-only AArch64 Fedora container stage; the target starts empty.
set -Eeuo pipefail
[[ $# == 1 && ( $1 == solve || $1 == install ) ]] || exit 2
mode=$1
root=/job/root
[[ -d /job/inputs && -f /builder/configs/images/userdata-rawhide.json ]]
[[ ! -L $root && ! -e $root/usr/share/uke/image-finalized ]]
mkdir -p "$root" /etc/rpm /etc/yum.repos.d /job/cache /job/logs
# --use-host-config reads the container RPM macros during the transaction.
printf '%%_install_langs all\n' > /etc/rpm/macros.zz-uke-languages
[[ $(rpm --eval '%{_install_langs}') == all ]]
install -m644 /job/inputs/fedora-46.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora46
install -m644 /job/inputs/uke-copr.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-copr
install -m644 /job/inputs/compose.repo /etc/yum.repos.d/uke-compose.repo
packages=()
mapfile -t packages < /job/inputs/packages.txt
(( ${#packages[@]} >= 90 ))
for package in "${packages[@]}"; do [[ $package =~ ^[a-zA-Z0-9+_.-]+$ ]]; done
dnf_command=(dnf5 --use-host-config --installroot="$root" --releasever=rawhide
    --disable-repo='*' --enable-repo=rawhide --enable-repo=uke-linux
    --setopt=install_weak_deps=False --setopt=keepcache=True
    --setopt=cachedir=/job/cache --setopt=gpgcheck=True --setopt=localpkg_gpgcheck=True
    --setopt=tsflags=nodocs
    --setopt=excludepkgs='*-debuginfo,*-debugsource,kernel,kernel-core,kernel-modules*,sddm*')
if [[ $mode == solve ]]; then
    result=0
    "${dnf_command[@]}" install "${packages[@]}" --assumeno > /job/logs/solve.log 2>&1 || result=$?
    [[ $result == 1 ]] && grep -Fq 'Operation aborted by the user' /job/logs/solve.log
    exit
fi
"${dnf_command[@]}" -y install "${packages[@]}" > /job/logs/install.log 2>&1
"${dnf_command[@]}" check > /job/logs/dependency-check.log 2>&1
rpm --root "$root" -qa --qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{SOURCERPM}\n' |
    LC_ALL=C sort > /job/installed-rpms.tsv
[[ -s /job/installed-rpms.tsv ]]
rpm --root "$root" --restore -a
printf '%%_install_langs all\n' > "$root/etc/rpm/macros.uke-languages"
touch /job/packages.complete
