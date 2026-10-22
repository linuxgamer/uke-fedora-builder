#!/usr/bin/env bash
# Update the retained private root from the canonical signed test repository.
set -Eeuo pipefail
[[ $# == 0 && -f /job/packages.complete && ! -e /job/rootfs-frozen ]]
root=/job/root
# shellcheck source=src/image/filesystem-policy.sh
source /builder/src/image/filesystem-policy.sh
filesystem=$(userdata_profile_filesystem /builder/configs/images/userdata-rawhide.json)
release=$(jq -er .kernel_release /builder/configs/images/userdata-rawhide.json)
[[ $release =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ && -d $root && ! -L $root ]]
install -m644 /job/inputs/compose.repo /etc/yum.repos.d/uke-compose.repo
install -m644 /job/inputs/fedora-46.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora46
install -m644 /job/inputs/uke-copr-test.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-copr-test
printf '%%_install_langs all\n' > /etc/rpm/macros.zz-uke-languages
rpm --root "$root" --import /job/inputs/uke-copr-test.asc
reference=$root/var/lib/uke-touch/reference.bin
[[ -f $reference && ! -L $reference && $(stat -c %a "$reference") == 600 ]]
reference_sha=$(sha256sum "$reference" | cut -d ' ' -f1)
command=(dnf5 --use-host-config --installroot="$root" --releasever=rawhide
    --disable-repo='*' --enable-repo=rawhide --enable-repo=uke-linux-test
    --setopt=cachedir=/job/cache --setopt=keepcache=True --setopt=gpgcheck=True
    --setopt=uke-linux-test.metadata_expire=0
    --setopt=rawhide.metadata_expire=0
    --setopt=localpkg_gpgcheck=True --setopt=install_weak_deps=False --setopt=installonly_limit=0
    --setopt=allow_vendor_change=True
    --setopt=tsflags=nodocs --setopt=excludepkgs='*-debuginfo,*-debugsource,kernel,kernel-core,kernel-modules*,sddm*')
packages=("senemos-uke-linux-kernel-mainline-singleboot-$release.fc46"
    uke-core-meta uke-kde-plasma-meta uke-core uke-hw
    uke-power uke-sensors uke-additional uke-extras
    uke-control uke-control-tests uke-firmware fastfetch
    uke-front-color uke-adaptive-display
    power-profiles-daemon uke-touchscreen
    'uke-boot-integration(factory-wlan-v1)' 'uke-boot-integration(factory-bluetooth-v1)'
    uke-charge-control uke-offline-charge uke-battery-observer
    uke-mesa-dri-drivers uke-mesa-vulkan-drivers uke-ssc-fileservice
    uke-libaccounts-glib uke-libwacom uke-libwacom-data
    ddcutil openssh-server nftables firewalld selinux-policy-targeted policycoreutils)
rollback=()
retired=()
retained=$(jq -cer '.retained_kernel_releases | select(type=="array" and length==(unique|length) and all(.[]; type=="string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$")))' /builder/configs/images/userdata-rawhide.json)
while IFS= read -r baseline; do
    [[ $baseline != "$release" ]]
    for component in boot core dtbs modules; do
        archive=/job/inputs/kernel-copr/$baseline/senemos-uke-linux-kernel-mainline-$component-$baseline.fc46.aarch64.rpm
        if [[ ! -f $archive && ( $baseline == 7.2.11-14 || $baseline == 7.2.11-17 ) ]]; then
            archive=/job/inputs/kernel${baseline##*-}-copr/senemos-uke-linux-kernel-mainline-$component-$baseline.fc46.aarch64.rpm
        fi
        [[ -f $archive && ! -L $archive ]]
        rollback+=("$archive")
    done
done < <(jq -r '.[]' <<< "$retained")
rpm --root "$root" -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' > /job/audit/image-kernel-inventory.tsv
while IFS=$'\t' read -r name version nevra; do
    case $name in
        uke-power-profile-backend) retired+=("$nevra");;
        senemos-uke-linux-kernel-mainline-boot|senemos-uke-linux-kernel-mainline-core|\
        senemos-uke-linux-kernel-mainline-dtbs|senemos-uke-linux-kernel-mainline-modules)
            baseline=${version%.fc46}
            [[ $baseline =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
            keep=$(jq -r --arg release "$baseline" 'index($release)!=null' <<< "$retained")
            [[ $keep == true || $keep == false ]]
            if [[ $baseline != "$release" && $keep == false ]]; then
                retired+=("$nevra")
            fi;;
    esac
done < /job/audit/image-kernel-inventory.tsv
if [[ $filesystem != f2fs ]]; then
    packages+=('uke-kernel-update(root-filesystem-v2)')
fi
solve() {
    local output=$1 rc=0
    shift
    "${command[@]}" "$@" --assumeno > "$output" 2>&1 || rc=$?
    if [[ $rc == 0 ]]; then
        grep -Fq 'Nothing to do' "$output"
    else
        [[ $rc == 1 ]] && grep -Fq 'Operation aborted by the user' "$output"
    fi
}
if [[ ${UKE_COMPOSE_SOLVE_ONLY:-0} == 1 ]]; then
    solve /job/logs/device-solve.log install --allowerasing "${packages[@]}"
    solve /job/logs/rawhide-sync-solve.log distro-sync --allowerasing --exclude='senemos-uke-linux-kernel-mainline*'
    if ((${#rollback[@]})); then solve /job/logs/rollback-solve.log install "${rollback[@]}"; fi
    if ((${#retired[@]})); then solve /job/logs/retire-solve.log remove --setopt=clean_requirements_on_remove=False "${retired[@]}"; fi
    exit
fi
"${command[@]}" -y install --allowerasing "${packages[@]}" > /job/logs/device-install.log 2>&1
# Synchronize the retained Fedora root while preserving the selected kernel tuple.
"${command[@]}" -y distro-sync --allowerasing \
    --exclude='senemos-uke-linux-kernel-mainline*' > /job/logs/rawhide-sync.log 2>&1
# Only the generated root is pruned, following its explicit retained-kernel profile.
if ((${#rollback[@]})); then
    "${command[@]}" -y install "${rollback[@]}" > /job/logs/rollback-install.log 2>&1
fi
if ((${#retired[@]})); then
    "${command[@]}" -y remove --setopt=clean_requirements_on_remove=False "${retired[@]}" > /job/logs/retire-install.log 2>&1
fi
"${command[@]}" check > /job/logs/device-dependency-check.log 2>&1
rpm --root "$root" -q --provides "senemos-uke-linux-kernel-mainline-core-$release.fc46.aarch64" |
    grep -Fx 'uke-kernel(platform-profile-qos-v1) = 1' > /job/audit/native-profile-capability.txt
rpm --root "$root" -q uke-core-meta power-profiles-daemon >/dev/null
for package in uke-power-profile-backend uke-bluetooth uke-wifi-factory; do
    if rpm --root "$root" -q "$package" >/dev/null 2>&1; then
        printf 'Retired standalone package remains installed: %s\n' "$package" >&2; exit 1
    fi
done
[[ $(sha256sum "$reference" | cut -d ' ' -f1) == "$reference_sha" ]]
rpm --root "$root" -q uke-local-touch-data >/dev/null
rpm --root "$root" --restore -a
rpm --root "$root" -qa --qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{SOURCERPM}\n' |
    LC_ALL=C sort > /job/installed-rpms.tsv
[[ $(rpm --root "$root" -q senemos-uke-linux-kernel-mainline-singleboot --qf '%{VERSION}-%{RELEASE}') == "$release.fc46" ]]
systemctl --root="$root" unmask uke-install-profile.service
systemctl --root="$root" enable uke-install-profile.service uke-wifi-factory.service uke-touchscreen.service \
    uke-adaptive-display.target uke-userdata-accept.service uke-control.service
if [[ -f $root/usr/lib/systemd/system/uke-root-grow.service ]]; then
    systemctl --root="$root" enable uke-root-grow.service
fi
printf 'device-packages-complete\n' > /job/device-packages.complete
