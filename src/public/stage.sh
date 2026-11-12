#!/usr/bin/env bash
# Runs only inside disposable host workers, never on the tablet.
set -Eeuo pipefail
[[ $# == 1 && -f /job/request.json && -d /cache ]]
request=/job/request.json
policy=/builder/configs/public-build.json
stage=$1
copr_inputs=${UKE_COPR_ROOT_INPUTS:-}
if [[ -n $copr_inputs ]]; then
    [[ $copr_inputs == /inputs/target && ${UKE_OFFLINE:-0} == 1 && -f /.uke-copr-sdk && $(< /.uke-copr-sdk) == 1 ]]
    [[ $stage == root || $stage == repository-kernel ]]
fi
if [[ -n ${UKE_WORKER_CA:-} ]]; then
    [[ -r $UKE_WORKER_CA ]]
    printf '\nsslcacert=%s\n' "$UKE_WORKER_CA" >> /etc/dnf/dnf.conf
fi
fedora_release=$(jq -er .fedora_release "$request")
case $fedora_release in 44|45|rawhide) ;; *) echo "Unsupported Fedora target" >&2; exit 1;; esac
# The worker is pinned to the requested distribution; derive its RPM macros there.
fedora_number=$(rpm --eval '%{fedora}')
dist=$(rpm --eval '%{?dist}')
[[ $fedora_number =~ ^[0-9]+$ && $dist == ".fc$fedora_number" ]]
[[ $fedora_release == rawhide || $fedora_number == "$fedora_release" ]]
fedora_key=/builder/configs/keys/fedora-$fedora_number.asc
[[ -s $fedora_key ]] || { echo "Unreviewed Fedora signing key: $fedora_number" >&2; exit 1; }
if [[ ${UKE_OUTPUT_OWNER:-none} != none ]]; then
    [[ $UKE_OUTPUT_OWNER =~ ^[0-9]+:[0-9]+$ ]]
    # Preserve the numeric owners in the staging root used for filesystem readback.
    trap 'chown -R "$UKE_OUTPUT_OWNER" /job/artifacts' EXIT
fi
channel=$(jq -er .channel "$request")
if [[ $channel == unstable && ( $stage == repository-kernel || $stage == root || $stage == filesystem ) ]]; then
    [[ $fedora_release == rawhide ]] || exit 1
    # shellcheck source=repository-tools.sh
    # shellcheck disable=SC1091
    source /builder/src/public/repository-tools.sh
fi
filesystem=$(jq -er .filesystem "$request")
partition=$(jq -er .partition "$request")
jobs=$(jq -er .jobs "$request")
die() { printf 'stage: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'stage: %s\n' "$*"; }
# shellcheck source=kernel-source.sh
# shellcheck disable=SC1091
source /builder/src/public/kernel-source.sh
# shellcheck source=cohort.sh
# shellcheck disable=SC1091
source /builder/src/public/cohort.sh
# The host resolved the exact source commit and Linux version once; the release is derived from the source below.
source_commit=$(jq -er .kernel_commit "$request")
kernel_version=$(jq -er .kernel_version "$request")
KERNEL_PROFILE=$(jq -r '.kernel_profile // "normal"' "$request")
KERNEL_CONFIG_SHA=$(jq -r '.kernel_native_config_sha256 // empty' "$request")
export KERNEL_CONFIG_SHA
RUN_TESTS=$(jq -r 'if .run_kernel_tests == false then 0 else 1 end' "$request")
case $KERNEL_PROFILE in normal|el2-require) ;; *) die 'Unadmitted kernel profile';; esac
kernel_family=$(jq -er --arg profile "$KERNEL_PROFILE" '.kernel.profiles[$profile].family' "$policy")
[[ $source_commit =~ ^[0-9a-f]{40}$ && $kernel_version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
cache_flags=()
[[ ${UKE_OFFLINE:-0} != 1 || -n $copr_inputs ]] || cache_flags+=(--cacheonly)
rpm -qa --qf '%{NEVRA}\n' | LC_ALL=C sort > "/job/artifacts/worker-$stage-rpms.txt"
local_repository() {
    createrepo_c --update --excludes='*.src.rpm' /job/artifacts
    cat > /etc/yum.repos.d/uke-source-build.repo <<'REPO'
[uke-source-build]
name=Locally compiled pinned Uke sources
baseurl=file:///job/artifacts
enabled=1
gpgcheck=0
priority=1
REPO
}
kernel_checkout() {
    local url snapshot
    url=$(jq -er .kernel_url "$request")
    # A local checkout reaches the worker as a snapshot bundle made by the host, never as a live mount.
    snapshot=$(jq -r '.kernel_bundle // empty' "$request")
    if [[ -n $snapshot ]]; then url=/job/$snapshot; fi
    source=/cache/kernel-$source_commit
    if [[ ! -d $source/.git ]]; then
        [[ ${UKE_OFFLINE:-0} != 1 || -n $snapshot ]]
        git -c safe.directory='*' clone --no-checkout --no-hardlinks "$url" "$source"
    fi
    git -C "$source" checkout --detach "$source_commit"
    [[ $(git -C "$source" rev-parse HEAD) == "$source_commit" && -z $(git -C "$source" status --porcelain --untracked-files=no) ]]
    # Validate this exact SRPM producer before downloading its source archives.
    kernel_source_check "$source" "$kernel_version"
    # Downloaded source inputs are shared between source commits so a new commit never fetches them again.
    for shared in releases touch-runtime; do
        mkdir -p "/cache/$shared" "$source/source-cache"
        for input in "$source/source-cache/$shared"/*; do
            [[ -L $input || ! -f $input ]] || cp -n "$input" "/cache/$shared/"
        done
        rm -rf "$source/source-cache/$shared"
        ln -sfn "/cache/$shared" "$source/source-cache/$shared"
    done
    # Keep the kernel.org release list this build resolved from, for later offline runs.
    if [[ -f /job/inputs/releases.json ]]; then cp -f /job/inputs/releases.json /cache/releases/releases.json; fi
}
kernel_srpm() {
    # The signed upstream source and every adaptation hash are checked by make srpm.
    make -C "$source" srpm outdir=/job/srpm version="$kernel_version" run_tests="$RUN_TESTS" el2_profile="$KERNEL_PROFILE"
    mkdir -p /job/rpmbuild
    srpms=(/job/srpm/*.src.rpm)
    [[ ${#srpms[@]} == 1 && -f ${srpms[0]} ]]
    [[ $(rpm -qp --qf '%{VERSION}' "${srpms[0]}") == "$kernel_version" ]] || die "The source RPM is not Linux $kernel_version"
}
kernel_spec() {
    rpm --define '_topdir /job/rpmbuild' -i "${srpms[0]}"
    spec=(/job/rpmbuild/SPECS/*.spec)
    [[ ${#spec[@]} == 1 ]]
    # The release comes from the selected source, so the initramfs, RPMs and module paths share one name.
    rpm_release=$(rpmspec -q --srpm --qf '%{VERSION}-%{RELEASE}\n' --define '_topdir /job/rpmbuild' --define 'dist %{nil}' "${spec[0]}")
    [[ $rpm_release =~ ^${kernel_version//./\\.}-[0-9A-Za-z._+]+$ ]] || die "Unexpected kernel release from the source spec: $rpm_release"
    [[ $(rpmspec -q --srpm --qf '%{NAME}' "${spec[0]}") == "$kernel_family" ]] || die 'Source package family differs from the selected profile'
    release=$(rpmspec -q --qf '[%{PROVIDENAME}\n]' --define 'dist %{nil}' "${spec[0]}" | sed -n 's/^kernel-uname-r(\([^)]*\))$/\1/p')
    [[ -n $release ]] || release=$rpm_release
    case $KERNEL_PROFILE in
        normal) [[ $release == "$rpm_release" ]] || die 'Unexpected ordinary Image ABI';;
        el2-require) [[ $release == "$rpm_release-kvm" ]] || die 'Expected the canonical -kvm Image ABI';;
    esac
    printf '%s\n' "$rpm_release" > /job/kernel-rpm-release
    printf '%s\n' "$release" > /job/kernel-release
    say "Kernel release $release (Linux $kernel_version from ${source_commit:0:12})"
    # Older pinned specs clamp compiler jobs to 8; lift only that clamp so every requested CPU is used.
    # shellcheck disable=SC2016
    sed -i '/^test "\$jobs" -le 8 || jobs=8$/d' "${spec[0]}"
}
kernel_collect() {
    # Stages run in separate containers, so find the source RPM again.
    srpms=(/job/srpm/*.src.rpm)
    [[ ${#srpms[@]} == 1 && -f ${srpms[0]} ]]
    mkdir -p /job/artifacts/kernel
    cp "${srpms[@]}" /job/artifacts/kernel/
    cp /job/rpmbuild/RPMS/aarch64/*.rpm /job/artifacts/kernel/
    rpm -qp --qf '%{NEVRA}\t%{SOURCERPM}\n' /job/artifacts/kernel/*.aarch64.rpm | sort > /job/artifacts/kernel/packages.tsv
    # Read back the payload without executing RPM scriptlets.
    mkdir /job/kernel-payload
    for package in /job/artifacts/kernel/*.aarch64.rpm; do
        rpm2cpio "$package" > /job/payload.cpio
        (cd /job/kernel-payload; cpio -idmu --quiet --no-absolute-filenames < /job/payload.cpio)
    done
    release=$(< /job/kernel-release)
    rpm_release=$(< /job/kernel-rpm-release)
    [[ $(rpm -qp --qf '%{VERSION}-%{RELEASE}' /job/artifacts/kernel/"$kernel_family"-core-*.aarch64.rpm) == "$rpm_release$dist" ]] ||
        die "Built kernel RPMs do not match release $release"
    bundle=/job/kernel-payload/usr/lib/senemos/kernel-updates/$release
    modules=/job/kernel-payload/usr/lib/modules/$release
    [[ -f $bundle/linux.img && -f $bundle/userdata.img && -f $modules/vmlinuz ]]
    (cd "$modules"; sha256sum -c "$bundle/modules.sha256")
    c++ -std=c++20 -O2 -Wall -Wextra -Werror "$source/src/boot/boot-image.cpp" -o /job/boot-image
    for profile in linux userdata; do
        /job/boot-image inspect "$bundle/$profile.img" > "/job/artifacts/kernel/boot-$profile.json"
        /job/boot-image extract "$bundle/$profile.img" "/job/$profile.Image"
        cmp "$modules/vmlinuz" "/job/$profile.Image"
        cp "$bundle/$profile.img" "/job/artifacts/boot-$profile.img"
    done
    if [[ $KERNEL_PROFILE != normal ]]; then
        jq -e --arg profile "$KERNEL_PROFILE" --arg source "$source_commit" --arg release "$release" \
            '.el2_profile == $profile and .kernel_source_commit == $source and .kernel_release == $release and .firmware_exit_enabled == false' \
            "$bundle/el2-build.json" >/dev/null || die 'Built EL2 profile differs from the request'
        cp "$bundle/el2-build.json" /job/artifacts/kernel/
    fi
    # The native RPM producer audits its linked initramfs with no Python exception.
    cohort_payload_inventory "$modules" > /job/artifacts/kernel/payload.sha256
    jq -n --arg source "$source_commit" --arg release "$release" --arg version "$kernel_version" \
        --arg payload "$(sha256sum /job/artifacts/kernel/payload.sha256 | cut -d ' ' -f1)" \
        --arg dist "$dist" --arg profile "$KERNEL_PROFILE" --arg family "$kernel_family" --arg rpm "$rpm_release" \
        --arg requested "$(jq -er .kernel_requested "$request")" \
        '{rpm_dist:$dist,kernel_profile:$profile,kernel_family:$family,rpm_version_release:$rpm,kernel_source_commit:$source,kernel_version:$version,kernel_requested:$requested,kernel_release:$release,payload_sha256:$payload,kernel_rpms_locally_built:true,
          local_kernel_rpm_signature:"unsigned local build; signed upstream source verified by producer",
          physical_boot_tested:false,hardware_tested:false,automatic_kernel_activation:false}' \
        > /job/artifacts/kernel/kernel-info.json
    jq --slurpfile info /job/artifacts/kernel/kernel-info.json '. + $info[0]' "$request" > /job/artifacts/manifest.json
}
if [[ $stage == repository-kernel ]]; then
    bash /builder/src/public/repository-kernel.sh
    exit
fi
if [[ $stage == kernel ]]; then
    [[ $(uname -m) == aarch64 ]]
    kernel_checkout
    kernel_srpm
    kernel_spec
    rpmbuild -bb --target aarch64 --define '_topdir /job/rpmbuild' \
        --define "_smp_build_ncpus $jobs" --define "dist $dist" "${spec[0]}"
    kernel_collect
    exit
fi
# Cross hosts: sources and compilation run natively; only the AArch64 userspace pieces are emulated.
if [[ $stage == kernel-source ]]; then
    kernel_checkout
    kernel_srpm
    kernel_spec
    exit
fi
if [[ $stage == kernel-base ]]; then
    [[ $(uname -m) == aarch64 ]]
    release=$(< /job/kernel-release)
    # Same relative layout as the RPM build tree, so path prefixes are identical.
    work=$(mktemp -d) && cd "$work"
    tar -xJf /job/rpmbuild/SOURCES/senemos-uke-boot-recipe.tar.xz
    cmp boot-recipe/lock.json /job/rpmbuild/SOURCES/boot-payload.json
    (cd boot-recipe; jq -r '.source_assets[] | .sha256 + "  " + .path' lock.json | sha256sum -c -)
    bash boot-recipe/src/boot/make-initramfs-base.sh /job/rpmbuild/boot-userspace "$release"
    mkdir -p /job/prebuilt
    clang++ -std=c++17 -O2 -Wall -Wextra -Werror -ffile-prefix-map="$PWD"=. \
        boot-recipe/src/boot/offline-switch-root.cpp -o /job/prebuilt/uke-offline-switch-root
    readelf -h /job/prebuilt/uke-offline-switch-root | grep -E 'Machine:.*AArch64' >/dev/null
    # Newer kernel sources also ship an AArch64 touch client that the spec links against target libraries.
    touch_runtime=$(compgen -G '/job/rpmbuild/SOURCES/senemos-uke-touch-runtime-*.tar.xz' || :)
    if [[ -n $touch_runtime ]]; then
        tar -xJf "$touch_runtime"
        (cd touch-runtime; sha256sum --check --strict --quiet SOURCE-SHA256SUMS)
        # shellcheck disable=SC2046
        g++ $(rpm --eval '%{build_cxxflags}') -std=c++20 -Wall -Wextra -Werror -ffile-prefix-map="$PWD"=. \
            touch-runtime/capture/touch-capture.cpp touch-runtime/capture/upstream/nt36532-thp/nvt_touch_core.cpp \
            -lcrypto -lsystemd -o /job/prebuilt/uke-touch-capture $(rpm --eval '%{build_ldflags}')
        readelf -h /job/prebuilt/uke-touch-capture | grep -E 'Machine:.*AArch64' >/dev/null
    fi
    exit
fi
# Re-run only the packaging checks on RPMs a finished kernel-build left in /job/rpmbuild.
if [[ $stage == kernel-collect ]]; then
    source=/cache/kernel-$source_commit
    [[ -d $source/.git && -n $(compgen -G '/job/rpmbuild/RPMS/aarch64/*.rpm') ]]
    kernel_collect
    exit
fi
if [[ $stage == kernel-build ]]; then
    source=/cache/kernel-$source_commit
    [[ -d $source/.git ]]
    spec=(/job/rpmbuild/SPECS/*.spec)
    [[ ${#spec[@]} == 1 && -d /job/rpmbuild/boot-userspace && -f /job/prebuilt/uke-offline-switch-root ]]
    # Cross compilation: LLVM targets arm64 from this host; BuildRequires are provided by the worker image.
    [[ ! -f /job/prebuilt/uke-touch-capture ]] || export UKE_PREBUILT_TOUCH_CAPTURE=/job/prebuilt/uke-touch-capture
    UKE_PREBUILT_SWITCH_ROOT=/job/prebuilt/uke-offline-switch-root \
        rpmbuild -bb --nodeps --target aarch64 --define '_topdir /job/rpmbuild' \
        --define "_smp_build_ncpus $jobs" --define "dist $dist" "${spec[0]}"
    kernel_collect
    exit
fi
if [[ $stage == hardware ]]; then
    [[ $(uname -m) == aarch64 && $channel == stable ]]
    hardware_commit=$(jq -er .hardware.commit "$policy")
    [[ $hardware_commit =~ ^[0-9a-f]{40}$ ]]
    hardware=/cache/hardware-$hardware_commit
    if [[ ! -d $hardware/.git ]]; then
        [[ ${UKE_OFFLINE:-0} != 1 ]]
        git clone --no-checkout "$(jq -er .hardware.url "$policy")" "$hardware"
    fi
    git -C "$hardware" checkout --detach "$hardware_commit"
    [[ -z $(git -C "$hardware" status --porcelain --untracked-files=no) ]]
    # shellcheck source=source-inputs.sh
    # shellcheck disable=SC1091
    source /builder/src/public/source-inputs.sh
    public_source_inputs "$hardware" /builder/configs/public-source-mirrors.json
    mkdir -p /job/artifacts/runtime
    local_repository
    for family in uke-additional uke-sensors uke-hw uke-power uke-core uke-metas; do
        top=/job/hardware-$family
        FEDORA_TARGET="$fedora_release" make -C "$hardware/packaging/families" srpm FAMILY="$family" outdir="$top/source"
        srpms=("$top/source/SRPMS/"*.src.rpm)
        [[ ${#srpms[@]} == 1 && -f ${srpms[0]} ]]
        dnf5 "${cache_flags[@]}" -y builddep "${srpms[0]}"
        for attempt in 1 2 3 4; do
            printf 'Building %s, dependency pass %s\n' "$family" "$attempt"
            result=0
            rpmbuild --rebuild --target aarch64 --define "_topdir $top" \
                --define "_smp_build_ncpus $jobs" --define "dist $dist" "${srpms[0]}" || result=$?
            [[ $result != 0 ]] || break
            [[ $result == 11 ]] || exit "$result"
            requirements=("$top/SRPMS/"*.buildreqs.nosrc.rpm)
            [[ -f ${requirements[0]} ]]
            dnf5 "${cache_flags[@]}" -y builddep "${requirements[@]}"
            rm -- "${requirements[@]}"
        done
        [[ $result == 0 ]]
        cp "${srpms[@]}" /job/artifacts/runtime/
        find "$top/RPMS" -type f -name '*.rpm' -exec cp -t /job/artifacts/runtime/ {} +
        local_repository
    done
    jq --arg source "$hardware_commit" '. + {hardware_source_commit:$source,
        hardware_rpms_locally_built:true,local_runtime_repository:"unsigned RPMs compiled from the pinned public source"}' \
        /job/artifacts/manifest.json > /job/manifest.tmp
    mv /job/manifest.tmp /job/artifacts/manifest.json
    exit
fi
[[ $stage == root || $stage == filesystem ]]
if [[ $stage == filesystem ]]; then
    bash /builder/src/public/filesystem.sh
    exit
fi
arch_flags=()
if [[ $(uname -m) != aarch64 ]]; then
    # Native dnf and rpm install the AArch64 root; the host binfmt handler runs its scriptlets and chroot commands.
    arch_flags=(--forcearch=aarch64)
fi
root=/job/root
[[ ! -e $root ]]
mkdir -p "$root" /job/original-fedora /job/keydb
# Restore the all-language policy before DNF starts its RPM transaction. Fedora
# container bases otherwise inherit %_install_langs en_US and strip translations.
# shellcheck source=languages.sh
# shellcheck disable=SC1091
source /builder/src/public/languages.sh
public_language_policy
if [[ $(jq -r '.shared_core_phase // "none"' "$request") == import ]]; then
    [[ -f /job/shared-core/rootfs.tar && -d /job/shared-core/original-fedora ]]
    tar --extract --numeric-owner --acls --xattrs --selinux --xattrs-include=security.capability \
        --xattrs-include=security.selinux -f /job/shared-core/rootfs.tar -C "$root"
    cp -a /job/shared-core/original-fedora/. /job/original-fedora/
    # Installing a DE cannot repair files stripped from already-installed core
    # RPMs. Fail before DNF; an affected frozen core must be recreated.
    public_language_inventory "$root" /job/imported-core-language-files.tsv /job/imported-core-locales.txt
    public_language_audit "$root" /job/imported-core-language-files.tsv core /job/imported-core-locales.txt /job/artifacts/imported-core-language-audit.json || die 'Imported core has an incomplete language payload; rebuild the common core'
fi
mkdir -p "$root/proc"
# shellcheck source=root-proc.sh
# shellcheck disable=SC1091
source /builder/src/public/root-proc.sh
root_cleanup() {
    local status=$?
    public_root_proc_unmount "$root" || status=1
    if [[ ${UKE_OUTPUT_OWNER:-none} != none ]]; then chown -R "$UKE_OUTPUT_OWNER" /job/artifacts || status=1; fi
    exit "$status"
}
trap root_cleanup EXIT
public_root_proc_mount "$root"

# shellcheck source=channel.sh
# shellcheck disable=SC1091
source /builder/src/public/channel.sh
public_channel "$channel" "$policy"
project=$PUBLIC_PROJECT
fingerprint=$PUBLIC_FINGERPRINT
key=/cache/$project.asc
if [[ ${UKE_OFFLINE:-0} != 1 ]]; then
    curl --proto '=https' --tlsv1.2 -fL --retry 3 "https://download.copr.fedorainfracloud.org/results/mcc45tr/$project/pubkey.gpg" -o "$key.part"
    mv "$key.part" "$key"
fi
[[ $(gpg --show-keys --with-colons "$key" | awk -F: '$1=="fpr" {print $10;exit}') == "$fingerprint" ]]
install -m644 "$key" /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-selected
install -m644 "$fedora_key" /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-fedora
# shellcheck source=root-repository.sh
# shellcheck disable=SC1091
source /builder/src/public/root-repository.sh
repository_mode=public
[[ -z $copr_inputs ]] || repository_mode=copr-frozen
public_root_repository /etc/yum.repos.d/uke-selected.repo "$project" "$fedora_release" "$repository_mode"
desktop=$(jq -er .desktop "$request")
# shellcheck source=desktop-repository.sh
# shellcheck disable=SC1091
source /builder/src/public/desktop-repository.sh
public_desktop_repository "$desktop" /etc/yum.repos.d/uke-desktop.repo /etc/pki/rpm-gpg
# shellcheck source=root-packages.sh
# shellcheck disable=SC1091
source /builder/src/public/root-packages.sh
public_root_packages packages "$fedora_release" "$channel" "$desktop" "$(jq -er .default_shell "$request")" || die 'Unsupported root package selection'
release=$(jq -er .kernel_release /job/artifacts/kernel/kernel-info.json)
base=$kernel_family
rpm_release=$(jq -er '.rpm_version_release // .kernel_release' /job/artifacts/kernel/kernel-info.json)
local_rpms=()
for component in '' -core -modules -dtbs -boot; do
    package=/job/artifacts/kernel/$base$component-$rpm_release$dist.aarch64.rpm
    [[ -f $package ]]
    local_rpms+=("$package")
done
if [[ $partition == userdata ]]; then
    local_rpms+=("/job/artifacts/kernel/$base-singleboot-$rpm_release$dist.aarch64.rpm")
fi
if [[ $channel == unstable ]]; then
    # Do not depend on the producer's temporary key database crossing jobs.
    # The key fingerprint was checked above against the selected channel policy.
    # shellcheck source=root-kernel-signatures.sh
    # shellcheck disable=SC1091
    source /builder/src/public/root-kernel-signatures.sh
    public_root_kernel_signatures "$key" /job/root-kernel-keydb "${local_rpms[@]}" || die 'Root kernel RPM signature verification failed'
fi
# Source-built local RPMs are unsigned. Remote RPM signature checks stay enabled.
excluded=$(public_root_exclusions "$KERNEL_PROFILE")
dnf=(dnf5 "${cache_flags[@]}" ${arch_flags[@]+"${arch_flags[@]}"} --use-host-config --installroot="$root" --releasever="$fedora_release"
    --disable-repo='*' --enable-repo=uke-selected
    --setopt=cachedir="/cache/dnf-$channel" --setopt=keepcache=True
    --setopt=install_weak_deps=False --setopt=gpgcheck=True --setopt=installonly_limit=0
    # Uke packages require files such as /usr/lib/systemd/systemd-growfs, which only the filelists metadata resolves.
    --setopt=optional_metadata_types=filelists --setopt=max_parallel_downloads=10
    --setopt=tsflags= --setopt="excludepkgs=$excluded")
if [[ -n $copr_inputs ]]; then dnf+=(--enable-repo=copr-frozen-fedora)
else
    while IFS= read -r repo; do dnf+=(--enable-repo="$repo"); done < <(jq -er --arg release "$fedora_release" ' .fedora_targets[$release].repos[]' /builder/configs/build-rules.json)
fi
if [[ $desktop == cutefish || $desktop == nextkde ]]; then dnf+=(--enable-repo=uke-desktop); fi
if [[ -d /job/artifacts/runtime ]]; then
    local_repository
    dnf+=(--enable-repo=uke-source-build)
fi
# shellcheck source=root-transaction.sh
# shellcheck disable=SC1091
source /builder/src/public/root-transaction.sh
public_root_transaction "$root" /job/root-install.log dnf local_rpms packages
# The loop variable expands in the target's Bash, after chroot.
# shellcheck disable=SC2016
chroot "$root" /usr/bin/bash -ec 'for tool in clear ps ip ping file find which curl tar gzip unzip; do command -v "$tool" >/dev/null; done; TERM=xterm clear >/dev/null'
mkdir -p "$root/etc/rpm"
printf '%%_install_langs all\n%%_excludedocs 0\n' > "$root/etc/rpm/macros.zz-uke-languages"
public_language_inventory "$root" /job/artifacts/rpm-language-files.tsv /job/artifacts/supported-locales.txt
public_language_repair "$root" /job/artifacts/rpm-language-files.tsv /job/artifacts/supported-locales.txt dnf \
    /job/language-repair.log /job/artifacts/language-repair.json || die 'Complete RPM translation repair failed'
public_language_audit "$root" /job/artifacts/rpm-language-files.tsv "$desktop" /job/artifacts/supported-locales.txt /job/artifacts/language-audit.json || die 'Installed language payload is incomplete'
rpm --root "$root" -qa --qf '%{NEVRA}\t%{SOURCERPM}\t%{VENDOR}\n' | LC_ALL=C sort > /job/artifacts/installed-rpms.tsv
# shellcheck source=desktop-isolation.sh
# shellcheck disable=SC1091
source /builder/src/public/desktop-isolation.sh
public_desktop_isolation /job/artifacts/installed-rpms.tsv "$desktop" || die 'Installed desktop isolation audit failed'
printf '{"desktop_isolation_audited":true,"previous_desktop_image_input":false}\n' > /job/artifacts/desktop-isolation.json
if [[ -f /job/artifacts/core-installed-rpms.tsv ]]; then
    # shellcheck source=shared-core.sh
    # shellcheck disable=SC1091
    source /builder/src/public/shared-core.sh
    public_core_packages_check /job/artifacts/core-installed-rpms.tsv /job/artifacts/installed-rpms.tsv ||
        die 'Desktop transaction changed an immutable shared core package'
fi
[[ $(rpm --root "$root" -q "$base-core" --qf '%{VERSION}-%{RELEASE}') == "$rpm_release$dist" ]]
bundle=$root/usr/lib/senemos/kernel-updates/$release
(cd "$root/usr/lib/modules/$release"; sha256sum -c "$bundle/modules.sha256")
cp "$bundle/$partition.img" /job/artifacts/boot.img
cmp /job/artifacts/boot.img "/job/artifacts/boot-$partition.img"
# Prove Python exceptions against independently signature-verified Fedora bytes.
rpmkeys --dbpath /job/keydb --import "$fedora_key"
: > /job/fedora-inputs.tsv
if [[ -f /job/shared-core/fedora-inputs.tsv ]]; then cp /job/shared-core/fedora-inputs.tsv /job/fedora-inputs.tsv; fi
# Only archives whose exact NEVRA is installed in the root count as its original bytes.
declare -A installed=()
while IFS=$'\t' read -r nevra _; do installed[$nevra]=1; done < /job/artifacts/installed-rpms.tsv
while IFS= read -r -d '' archive; do
    IFS=$'\t' read -r vendor nevra < <(rpm -qp --qf '%{VENDOR}\t%{NEVRA}\n' "$archive")
    [[ $vendor == 'Fedora Project' && -n ${installed[$nevra]:-} ]] || continue
    rpmkeys --dbpath /job/keydb --checksig "$archive" | grep -F 'signatures OK'
    printf '%s\t%s\n' "$nevra" "$(sha256sum "$archive" | cut -d ' ' -f1)" >> /job/fedora-inputs.tsv
    rpm2cpio "$archive" | (cd /job/original-fedora; cpio -idmu --quiet --no-absolute-filenames)
done < <(if [[ -n $copr_inputs ]]; then find "$copr_inputs/rpms/fedora" -type f -name '*.rpm' -print0
         else find "/cache/dnf-$channel" -type f -name '*.rpm' -print0; fi)
LC_ALL=C sort -u /job/fedora-inputs.tsv > /job/artifacts/fedora-inputs.tsv
[[ -s /job/artifacts/fedora-inputs.tsv ]]
bash /builder/src/public/login-shell.sh "$root" "$(jq -er .default_shell "$request")" > /job/artifacts/login-shell.json
[[ $(rpm --root "$root" -q fedora-release-common --qf '%{VERSION}') == "$fedora_number" ]]
# Official Fedora carry-over builds are admitted only through verified Fedora RPM bytes.
while IFS=$'\t' read -r name rpm_release; do
    case $name in uke-*|senemos-uke-*) [[ $rpm_release == *"$dist" || $rpm_release == *"$dist".* ]] || die "Foreign-release Uke package: $name-$rpm_release";; esac
done < <(rpm --root "$root" -qa --qf '%{NAME}\t%{RELEASE}\n')
chroot "$root" /usr/sbin/usermod -L root
systemctl --root="$root" enable NetworkManager.service firewalld.service bluetooth.service chronyd.service
systemctl --root="$root" disable sshd.service sshd.socket
systemctl --root="$root" mask debug-shell.service uke-boot-guard.service
# shellcheck source=desktop-setup.sh
# shellcheck disable=SC1091
source /builder/src/public/desktop-setup.sh
public_desktop_setup "$root" "$desktop" /job/artifacts/account-provisioning.json
mkdir -p "$root/etc/senemos" "$root/etc/uke-control" "$root/etc/dnf" "$root/var/lib/uke-touch"
printf 'automatic=0\n' > "$root/etc/senemos/kernel-update.conf"
printf 'automatic=0\n' > "$root/etc/senemos/userdata-update.conf"
internal_channel=$channel
[[ $channel != testing ]] || internal_channel='test'
printf '%s\n' "$internal_channel" > "$root/etc/uke-control/channel"
root_options=defaults,noatime
[[ $partition != userdata || $filesystem != ext4 ]] || root_options+=,x-systemd.growfs
printf 'PARTLABEL=%s / %s %s 0 0\n' "$partition" "$filesystem" "$root_options" > "$root/etc/fstab"
cat /builder/configs/images/uke-persist.fstab >> "$root/etc/fstab"
mkdir -p "$root/mnt/vendor/persist"
chmod 700 "$root/mnt/vendor/persist"
printf 'SELINUX=enforcing\nSELINUXTYPE=targeted\n' > "$root/etc/selinux/config"
install -m644 /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-selected "$root/etc/pki/rpm-gpg/"
public_root_repository "$root/etc/yum.repos.d/uke-selected.repo" "$project" "$fedora_release"
if [[ $desktop == cutefish || $desktop == nextkde ]]; then
    cp /etc/yum.repos.d/uke-desktop.repo "$root/etc/yum.repos.d/uke-desktop.repo"
    desktop_project=cutefish
    [[ $desktop != nextkde ]] || desktop_project=kdenext
    cp "/etc/pki/rpm-gpg/RPM-GPG-KEY-uke-$desktop_project" "$root/etc/pki/rpm-gpg/"
fi
cat > "$root/etc/dnf/dnf.conf" <<'DNF'
[main]
install_weak_deps=False
installonly_limit=0
excludepkgs=kernel,kernel-core,kernel-modules*,*-debuginfo,*-debugsource
DNF
private=false
if [[ -f /job/inputs/reference.bin ]]; then
    [[ ! -L /job/inputs/reference.bin && $(stat -c %s /job/inputs/reference.bin) == 5432 ]]
    install -m600 /job/inputs/reference.bin "$root/var/lib/uke-touch/reference.bin"
    private=true
fi
# Generic images can complete setup using USB input until their own touch data exist.
mkdir -p "$root/etc/systemd/system/uke-touchscreen.service.d"
printf '[Unit]\nConditionPathExists=/var/lib/uke-touch/reference.bin\n' > "$root/etc/systemd/system/uke-touchscreen.service.d/local-data.conf"
for unit in uke-touchscreen.service uke-wifi-factory.service uke-install-profile.service; do
    systemctl --root="$root" enable "$unit"
done
if [[ $partition == userdata && $filesystem == ext4 ]]; then
    # shellcheck source=first-boot-policy.sh
    # shellcheck disable=SC1091
    source /builder/src/public/first-boot-policy.sh
    public_first_boot_policy "$root" /job/artifacts/first-boot-policy.json
    mkdir -p /job/fstab-generated/{normal,early,late}
    SYSTEMD_FSTAB="$root/etc/fstab" SYSTEMD_PROC_CMDLINE='root=PARTLABEL=userdata rw' SYSTEMD_SYSFS_CHECK=0 SYSTEMD_IN_INITRD=0 \
        /usr/lib/systemd/system-generators/systemd-fstab-generator /job/fstab-generated/normal /job/fstab-generated/early /job/fstab-generated/late
    find /job/fstab-generated -type l -printf '%P -> %l\n' > /job/artifacts/fstab-generated-links.txt
    grep -F 'systemd-growfs-root.service' /job/artifacts/fstab-generated-links.txt || die 'Fedora fstab generator did not connect root growth'
fi
# The source initramfs grows only provisioned F2FS userdata before mounting it.
find "$root/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -delete
find "$root/var/log" "$root/tmp" "$root/var/tmp" -mindepth 1 -depth -delete
for file in etc/machine-id var/lib/dbus/machine-id var/lib/systemd/random-seed; do
    rm -f "$root/$file"
done
: > "$root/etc/machine-id"
[[ ! -e $root/var/lib/uke-touch/reference.bin || $private == true ]]
jq --argjson private "$private" --slurpfile shell /job/artifacts/login-shell.json --arg dist "$dist" '. + {default_shell_path:$shell[0].path,shell_provisioning:$shell[0].provisioning,rpm_dist:$dist,rpm_transaction_validated:true,source_checked:true,device_private_data_included:$private,
    oem_firmware_included:true,redistribution_review_required:true,
    touch_reference_validation:"shape and permissions only; physical acceptance is separate",
    python_policy:"only byte-identical signature-verified original Fedora packages",
    credentials_included:false,ssh_enabled:false}' /job/artifacts/manifest.json > /job/manifest.tmp
mv /job/manifest.tmp /job/artifacts/manifest.json
jq --slurpfile account /job/artifacts/account-provisioning.json '. + $account[0]' /job/artifacts/manifest.json > /job/manifest.tmp
mv /job/manifest.tmp /job/artifacts/manifest.json
jq --slurpfile isolation /job/artifacts/desktop-isolation.json '. + $isolation[0]' /job/artifacts/manifest.json > /job/manifest.tmp
mv /job/manifest.tmp /job/artifacts/manifest.json
jq --slurpfile languages /job/artifacts/language-audit.json '. + {language_payload_verified:true,
    rpm_install_languages:$languages[0].rpm_install_languages,turkish_utf8_locale:$languages[0].turkish_utf8_locale}' \
    /job/artifacts/manifest.json > /job/manifest.tmp
mv /job/manifest.tmp /job/artifacts/manifest.json
if [[ -f /job/artifacts/first-boot-policy.json ]]; then
    jq '. + {root_capacity_gate_configured:true,swap_policy:"half",clear_binary_verified:true}' /job/artifacts/manifest.json > /job/manifest.tmp
    mv /job/manifest.tmp /job/artifacts/manifest.json
fi
if [[ $channel == unstable ]]; then
    cohort_codec=$UKE_IMAGE_TOOLS/boot-image
else
    cohort_codec=/job/cohort-boot-image
    c++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/src/boot/boot-image.cpp -o "$cohort_codec"
fi
cohort_root_check "$request" /job/artifacts "$root" "$cohort_codec" \
    /job/artifacts/kernel/packages.tsv /job/artifacts/installed-rpms.tsv > /job/cohort-validation.json
jq --slurpfile cohort /job/cohort-validation.json '. + {cohort_validation:$cohort[0]}' \
    /job/artifacts/manifest.json > /job/manifest.tmp
mv /job/manifest.tmp /job/artifacts/manifest.json
public_root_proc_unmount "$root"
# Audit the final installed files only after every chroot operation has finished
# and procfs is detached. The auditor rejects any remaining mounted subtree.
icon_proof=()
if [[ $desktop == cutefish ]]; then
    # shellcheck source=cutefish-icons-proof.sh
    # shellcheck disable=SC1091
    source /builder/src/public/cutefish-icons-proof.sh
    public_cutefish_icons_proof "$root" "/cache/dnf-$channel" /job/original-cutefish /job/artifacts/desktop-inputs.tsv \
        /etc/pki/rpm-gpg/RPM-GPG-KEY-uke-cutefish
    icon_proof=(--verified-cutefish-payload /job/original-cutefish)
fi
bash /builder/src/audit/check-target-payload.sh --original-kde-payload /job/original-fedora "${icon_proof[@]}" "$root"
for tree in dev proc sys run; do
    if findmnt --mountpoint "$root/$tree" --noheadings >/dev/null; then die 'Mounted runtime tree during export'; fi
    find "$root/$tree" -xdev -mindepth 1 -depth -delete
done
# shellcheck source=root-metadata.sh
# shellcheck disable=SC1091
source /builder/src/public/root-metadata.sh
if [[ $channel == unstable ]]; then
    archive_verifier=$UKE_IMAGE_TOOLS/ext4-labels
else
    archive_verifier=/job/ext4-labels
    c++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/src/image/ext4-labels.cpp \
        -o "$archive_verifier" -lext2fs -lcom_err -lselinux
fi
public_root_archive "$root" /job/rootfs.tar "$archive_verifier"
if [[ $desktop == core ]]; then
    # shellcheck source=shared-core.sh
    # shellcheck disable=SC1091
    source /builder/src/public/shared-core.sh
    public_core_pack /job
fi
