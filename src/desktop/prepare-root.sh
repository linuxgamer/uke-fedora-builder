#!/usr/bin/env bash
# Run in a disposable Fedora 44 AArch64 container. /core, /meta and /builder
# are read-only inputs; /job contains the complete package and root receipts.
set -Eeuo pipefail
[[ $# == 1 && ( $1 == kde || $1 == gnome ) ]]
variant=$1
root=/job/root
packages=/job/packages
case $variant in
    kde) manager=sddm; meta=/meta/kde-plasma-uke-meta-1.0.0-9.fc44.aarch64.rpm;;
    gnome) manager=gdm; meta=/meta/gnome-uke-meta-1.0.0-9.fc44.aarch64.rpm;;
esac
[[ -s /core/prepared-root.tar && -s $meta ]]
mkdir -p "$root" "$packages"
# The boot-pair assembler needs its four pinned host RPMs alongside the root.
# Keep their original, checksummed bytes with each standalone desktop candidate.
mkdir -p /job/inputs/runtime/packages
while IFS=$'\t' read -r name expected; do
    source=/core/inputs/runtime/packages/$name
    [[ -f $source && $(sha256sum "$source" | cut -d ' ' -f1) == "$expected" ]]
    cp --reflink=auto -- "$source" "/job/inputs/runtime/packages/$name"
done < <(jq -r '.[] | [.file,.sha256] | @tsv' /builder/configs/boot/uke-boot-pair-host-rpms.json)
if [[ ! -e /job/extracted.passed ]]; then
    tar --numeric-owner --same-owner --xattrs --xattrs-include='security.capability' \
        -xf /core/prepared-root.tar -C "$root"
    touch /job/extracted.passed
fi
rpmkeys --root "$root" --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-aarch64
rpmkeys --checksig --nosignature "$meta" | grep -F 'digests OK'
# A signed, saved closure makes the downloaded Fedora selection reviewable and
# lets an interrupted run resume without substituting newer repository RPMs.
if [[ ! -e /job/downloaded.passed ]]; then
    dnf -y --installroot "$root" --releasever=44 \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=install_weak_deps=False --setopt=localpkg_gpgcheck=0 \
        --setopt=cachedir=/job/cache install --downloadonly "$meta" "$manager"
    find /job/cache -type f -name '*.rpm' -exec cp -n -- {} "$packages/" \;
    (cd "$packages"; sha256sum ./*.rpm > SHA256SUMS)
    touch /job/downloaded.passed
fi
(cd "$packages"; sha256sum -c SHA256SUMS)
for package in "$packages"/*.rpm; do
    rpmkeys --root "$root" --checksig "$package" | grep -F 'signatures OK'
done
if [[ ! -e /job/installed.passed ]]; then
    dnf -y --installroot "$root" --releasever=44 \
        --setopt=reposdir=/etc/yum.repos.d \
        --setopt=install_weak_deps=False --setopt=localpkg_gpgcheck=0 \
        --disablerepo='*' install "$meta" "$packages"/*.rpm
    touch /job/installed.passed
fi
bash /builder/src/boot-pair/check-desktop-variant.sh "$root" "$variant"
rpm --root "$root" -V "${variant/kde/kde-plasma}-uke-meta" "$manager"
rpm --root "$root" -qa --qf '%{NEVRA}\n' | sort > /job/installed-rpms.txt
rm -rf "$root/var/cache/dnf"* "$root/var/tmp/"* "$root/tmp/"*
rm -f "$root/var/log/dnf"* "$root/var/lib/systemd/random-seed"
: > "$root/etc/machine-id"
tar --numeric-owner --xattrs --xattrs-include='security.capability' \
    -cpf /job/prepared-root.tar -C "$root" .
sha256sum /job/prepared-root.tar | sed 's#  /job/#  #' > /job/prepared-root.sha256
jq -n --arg variant "$variant" \
    --arg core "$(sha256sum /core/prepared-root.tar | cut -d ' ' -f1)" \
    --arg meta "$(sha256sum "$meta" | cut -d ' ' -f1)" \
    --arg closure "$(sha256sum "$packages/SHA256SUMS" | cut -d ' ' -f1)" \
    '{device:"uke",distribution:"fedora",release:"44",architecture:"aarch64",
      variant:$variant,root_size_mib:8192,core_prepared_root_sha256:$core,
      desktop_meta_sha256:$meta,package_closure_sha256:$closure}' > /job/profile.json
jq -n --arg variant "$variant" \
    --arg root "$(sha256sum /job/prepared-root.tar | cut -d ' ' -f1)" \
    --arg profile "$(sha256sum /job/profile.json | cut -d ' ' -f1)" \
    '{schema_version:1,variant:$variant,prepared_root_sha256:$root,
      profile_sha256:$profile,static_checks_passed:true,
      boot_tested:false,hardware_tested:false}' > /job/manifest.json
sha256sum /job/profile.json /job/manifest.json /job/installed-rpms.txt \
    | sed 's#  /job/#  #' > /job/SHA256SUMS
echo "Prepared Fedora 44 $variant root with signed Fedora RPM closure"
