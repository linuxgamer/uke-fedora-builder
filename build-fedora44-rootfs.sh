#!/usr/bin/env bash
# Fedora 44 rootfs composition. This produces a tarball, never writes a device.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
usage() {
    cat <<'HELP'
Usage: ./build-fedora44-rootfs.sh --profile tty|kde|gnome|phosh|plasma-mobile \
       --kernel-rpms DIR --core-rpm FILE --hardware-rpms DIR \
       --output DIR [--touch-panel csot|tm] [--root-mib 4096]

Compose a Fedora 44 AArch64 rootfs from Fedora packages and locally built
Linux 7.2.11 and selected hardware RPMs. Requires Docker or Podman and
AArch64 emulation on an x86_64 host. Output includes a sparse EXT4 image,
the package inventory and hashes. The image includes OEM touch firmware and a
tablet touch reference from the bundled, hash-pinned Uke OEM set. An account is
created on tty1 at the tablet's first boot. The builder never writes a device.
HELP
}
die() { printf 'fedora44-rootfs: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --inside ]]; then
    [[ $# == 1 && -d /workspace && -d /kernel-rpms && -d /hardware-rpms && -d /local-blobs && -f /core-rpm/uke-core-meta.rpm && -f /builder/uke-create-user && -f /builder/uke-create-user.service ]] || die 'Invalid container invocation'
    root=/workspace/root
    mkdir "$root"
    phase_start=$SECONDS
    phase_done() {
        printf '%s\t%s\n' "$1" "$((SECONDS - phase_start))" >> /workspace/timing.tsv
        phase_start=$SECONDS
    }
    dnf -y --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True --setopt=install_weak_deps=False install \
        tar zstd gcc-c++ e2fsprogs e2fsprogs-devel libselinux-devel systemd diffutils
    dnf -y --use-host-config --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True --installroot="$root" --releasever=44 \
        --setopt=install_weak_deps=False --setopt=localpkg_gpgcheck=False install \
        fedora-release basesystem bash coreutils systemd systemd-udev \
        NetworkManager dnf5 sudo shadow-utils util-linux kmod python3 \
        e2fsprogs selinux-policy-targeted \
        /kernel-rpms/senemos-uke-linux-kernel-mainline-core-*.rpm \
        /kernel-rpms/senemos-uke-linux-kernel-mainline-modules-*.rpm \
        /kernel-rpms/senemos-uke-linux-kernel-mainline-dtbs-*.rpm \
        /core-rpm/uke-core-meta.rpm
    phase_done base-packages
    rpm --root "$root" -q --qf '%{VERSION} %{RELEASE} %{ARCH}\n' \
        senemos-uke-linux-kernel-mainline-core \
        senemos-uke-linux-kernel-mainline-modules \
        senemos-uke-linux-kernel-mainline-dtbs | \
        awk '$1 != "7.2.11" || $2 !~ /^[1-9][0-9]*\.fc44$/ || $3 != "aarch64" { bad=1 } NR==1 { release=$2 } $2 != release { bad=1 } END { exit bad || NR != 3 }' \
        || die 'Expected three matching Fedora 44 AArch64 Linux 7.2.11 RPMs'
    kernel_release=$(rpm --root "$root" -q --qf '%{VERSION}-%{RELEASE}\n' senemos-uke-linux-kernel-mainline-core)
    [[ -d $root/usr/lib/modules/${kernel_release%.fc44} ]] || die 'Kernel module directory is absent'
    [[ $(rpm --root "$root" -q --qf '%{VERSION} %{RELEASE} %{ARCH}' uke-core-meta) == '1.0.0 5.fc44 aarch64' ]] || die 'Expected Fedora 44 Uke Core RPM'
    dnf -y --use-host-config --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True --installroot="$root" --releasever=44 \
        --setopt=install_weak_deps=False --setopt=localpkg_gpgcheck=False install \
        /hardware-rpms/uke-touchscreen-0.1.0-*.fc44.aarch64.rpm \
        /hardware-rpms/uke-battery-observer-0.1.0-*.fc44.aarch64.rpm \
        /hardware-rpms/uke-wifi-factory-0.1.0-*.fc44.aarch64.rpm \
        /hardware-rpms/uke-bluetooth-0.1.0-*.fc44.aarch64.rpm \
        /hardware-rpms/libssc-0.4.4-*.fc44.aarch64.rpm \
        /hardware-rpms/iio-sensor-proxy-3.9-*.fc44.aarch64.rpm \
        /hardware-rpms/uke-ssc-fileservice-2026.09.21-*.fc44.aarch64.rpm \
        /hardware-rpms/uke-fedora44-oem-data-3.0.303.0-2.fc44.noarch.rpm
    phase_done hardware-packages
    rpm --root "$root" -q --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' \
        uke-touchscreen uke-battery-observer uke-wifi-factory uke-bluetooth | \
        awk '($1 == "uke-touchscreen" && $3 ~ /^([8-9]|[1-9][0-9]+)\.fc44$/) ||
             ($1 == "uke-battery-observer" && $3 ~ /^([8-9]|[1-9][0-9]+)\.fc44$/) ||
             ($1 == "uke-wifi-factory" && $3 ~ /^(22|2[3-9]|[3-9][0-9]|[1-9][0-9][0-9]+)\.fc44$/) ||
             ($1 == "uke-bluetooth" && $3 ~ /^([6-9]|[1-9][0-9]+)\.fc44$/) {
                if ($2 == "0.1.0" && $4 == "aarch64") good++
             } END { exit good != 4 || NR != 4 }' || die 'Expected four selected Fedora 44 hardware RPMs'
    rpm --root "$root" -q --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' \
        libssc iio-sensor-proxy uke-ssc-fileservice uke-fedora44-oem-data | \
        awk '($1 == "libssc" && $2 == "0.4.4" && $3 ~ /^[1-9][0-9]*\.fc44$/ && $4 == "aarch64") ||
             ($1 == "iio-sensor-proxy" && $2 == "3.9" && $3 ~ /^[1-9][0-9]*\.fc44$/ && $4 == "aarch64") ||
             ($1 == "uke-ssc-fileservice" && $2 == "2026.09.21" && $3 ~ /^[1-9][0-9]*\.fc44$/ && $4 == "aarch64") ||
             ($1 == "uke-fedora44-oem-data" && $2 == "3.0.303.0" && $3 == "2.fc44" && $4 == "noarch") { good++ }
             END { exit good != 4 || NR != 4 }' || die 'Expected Fedora 44 SSC and OEM data RPMs'
    systemctl --root="$root" enable uke-touchscreen.service uke-battery.service uke-wifi-factory.service uke-bluetooth-address.service
    install -Dm644 /builder/uke-ssc-fedora44.target "$root/usr/lib/systemd/system/uke-ssc-fedora44.target"
    systemctl --root="$root" enable uke-ssc-fedora44.target
    panel=$(cat /workspace/TOUCH-PANEL)
    case $panel in csot|tm) ;; *) die 'Invalid touch panel selection' ;; esac
    for name in normal.bin config.ini; do
        [[ -f /local-blobs/touch/$panel/$name && ! -L /local-blobs/touch/$panel/$name ]] || die "Missing selected touch input: $name"
        install -Dm600 "/local-blobs/touch/$panel/$name" "$root/var/lib/uke-touch/$name"
    done
    [[ -f /local-blobs/touch/reference.bin && ! -L /local-blobs/touch/reference.bin ]] || die 'Missing device touch reference'
    install -Dm600 /local-blobs/touch/reference.bin "$root/var/lib/uke-touch/reference.bin"
    chmod 0700 "$root/var/lib/uke-touch"
    install -Dm755 /builder/uke-create-user "$root/usr/libexec/uke-create-user"
    install -Dm644 /builder/uke-create-user.service "$root/usr/lib/systemd/system/uke-create-user.service"
    systemctl --root="$root" enable uke-create-user.service
    profile=$(cat /workspace/PROFILE-ID)
    case $profile in
        tty)
            systemctl --root="$root" set-default multi-user.target
            systemctl --root="$root" enable getty@tty1.service
            ;;
        kde|gnome|phosh|plasma-mobile)
            common=(NetworkManager-wifi bluez mesa-dri-drivers pipewire wireplumber
                    polkit udisks2 xorg-x11-server-Xwayland)
            case $profile in
                kde) desktop=(plasma-desktop plasma-workspace kwin sddm
                              sddm-wayland-plasma konsole dolphin plasma-nm
                              plasma-keyboard plasma-systemsettings plasma-pa
                              powerdevil); display=sddm ;;
                gnome) desktop=(gnome-shell gnome-session-wayland-session gdm gnome-control-center
                                gnome-settings-daemon gnome-terminal nautilus); display=gdm ;;
                phosh) desktop=(phosh phoc gdm phosh-mobile-settings
                                stevia-phosh-osk-provider gnome-control-center); display=gdm ;;
                plasma-mobile) desktop=(plasma-mobile plasma-workspace kwin sddm
                                         plasma-settings plasma-nm plasma-keyboard
                                         plasma-pa powerdevil); display=sddm ;;
            esac
            dnf -y --use-host-config --disable-repo=fedora-cisco-openh264 \
                --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True \
                --installroot="$root" --releasever=44 --setopt=install_weak_deps=False \
                install noopenh264 "${common[@]}" "${desktop[@]}"
            session=$profile
            [[ $profile != kde ]] || session=plasma
            [[ $profile != gnome ]] || session=gnome
            [[ -s $root/usr/share/wayland-sessions/$session.desktop ]] || die "Missing $profile Wayland session"
            systemctl --root="$root" set-default graphical.target
            systemctl --root="$root" enable "$display.service"
            ;;
        *) die 'Invalid profile in workspace' ;;
    esac
    phase_done profile-packages-and-configuration
    for forbidden in senemos-uke-linux-kernel-mainline senemos-uke-linux-kernel-mainline-boot uke-kernel-update uke-charge-control uke-offline-charge uke-boot-integration; do
        if rpm --root "$root" -q "$forbidden" >/dev/null 2>&1; then
            die "Forbidden boot or charging package in userdata image: $forbidden"
        fi
    done
    root_password=$(awk -F: '$1=="root" {print $2}' "$root/etc/shadow")
    [[ $root_password == '!'* || $root_password == '*'* ]] || die 'Root account is not locked'
    systemctl --root="$root" enable NetworkManager.service
    printf 'PARTLABEL=userdata / ext4 defaults,noatime,x-systemd.growfs 0 1\n' > "$root/etc/fstab"
    cat /builder/uke-persist.fstab >> "$root/etc/fstab"
    install -d -m700 "$root/mnt/vendor/persist"
    install -d -m700 "$root/root"
    : > "$root/etc/machine-id"
    mkdir -p "$root/var/lib/dbus"
    rm -f "$root/var/lib/dbus/machine-id"
    ln -s /etc/machine-id "$root/var/lib/dbus/machine-id"
    rm -f "$root/etc/ssh"/ssh_host_*
    rpm --root "$root" -qa --qf '%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\n' | \
        LC_ALL=C sort > /workspace/packages.tsv
    root_mib=$(cat /workspace/ROOT-MIB)
    # mkfs.ext4 -d creates the root inode as 0755 even when Fedora's
    # filesystem package stages the installroot directory as 0555.
    chmod 0755 "$root"
    local_contexts=$root/etc/selinux/targeted/contexts/files/file_contexts.local
    [[ -f $local_contexts && ! -s $local_contexts ]] || die 'Unexpected local SELinux file contexts'
    printf '%s\n' '/mnt/vendor/persist -d system_u:object_r:mnt_t:s0' > "$local_contexts"
    truncate -s "$((root_mib * 1024 * 1024))" /workspace/userdata.raw.img
    mkfs.ext4 -q -F -b 4096 -L UKE_LINUX -m 0 \
        -E lazy_itable_init=0,lazy_journal_init=0 -d "$root" /workspace/userdata.raw.img
    phase_done ext4-population
    g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/ext4-labels.cpp \
        -o /workspace/ext4-labels -lext2fs -lcom_err -lselinux
    contexts=$root/etc/selinux/targeted/contexts/files/file_contexts
    [[ -s $contexts ]] || die 'Fedora SELinux file contexts are missing'
    /workspace/ext4-labels apply /workspace/userdata.raw.img "$root" "$contexts"
    /workspace/ext4-labels verify /workspace/userdata.raw.img "$root" "$contexts"
    e2fsck -fn /workspace/userdata.raw.img >/workspace/ext4-check.txt
    phase_done labeling-and-fsck
    g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/android-sparse.cpp -o /workspace/android-sparse
    /workspace/android-sparse encode /workspace/userdata.raw.img /workspace/userdata.img
    /workspace/android-sparse decode /workspace/userdata.img /workspace/userdata.readback.img
    cmp /workspace/userdata.raw.img /workspace/userdata.readback.img
    phase_done sparse-roundtrip
    rm /workspace/userdata.readback.img /workspace/ext4-labels /workspace/android-sparse
    (cd "$root"; tar --numeric-owner --xattrs --acls -cpf - .) | zstd -T2 -3 -o /workspace/rootfs.tar.zst
    phase_done rootfs-archive
    sha256sum /workspace/rootfs.tar.zst /workspace/userdata.raw.img \
        /workspace/userdata.img /workspace/packages.tsv /workspace/PROFILE \
        /workspace/PROFILE-ID /workspace/ROOT-MIB \
        /workspace/KERNEL-RPMS.sha256 /workspace/CORE-RPM.sha256 \
        /workspace/HARDWARE-RPMS.sha256 /workspace/LOCAL-BLOBS.sha256 \
        /workspace/TOUCH-PANEL /workspace/timing.tsv | \
        sed 's|/workspace/||' > /workspace/SHA256SUMS
    exit 0
fi

profile='' rpms='' core_rpm='' hardware_rpms='' output='' panel=csot root_mib=4096
blobs=$here/../uke-linux-hardware-support/xiaomi-uke-firmware/payload/oem-os3.0.303.0
while (($#)); do
    case $1 in
        --profile|--kernel-rpms|--core-rpm|--hardware-rpms|--touch-panel|--output|--root-mib)
            (($# >= 2)) || die "Missing value for $1"
            case $1 in --profile) profile=$2;; --kernel-rpms) rpms=$2;; --core-rpm) core_rpm=$2;; --hardware-rpms) hardware_rpms=$2;; --touch-panel) panel=$2;; --output) output=$2;; --root-mib) root_mib=$2;; esac
            shift 2;;
        --help|-h) usage; exit 0;;
        *) die "Unknown argument: $1";;
    esac
done
case $profile in tty|kde|gnome|phosh|plasma-mobile) ;; *) die 'Unknown profile' ;; esac
[[ -d $rpms && -f $core_rpm && -d $hardware_rpms && -d $blobs && -n $output ]] || die 'Provide --kernel-rpms, --core-rpm, --hardware-rpms and --output; bundled OEM files must be present'
case $panel in csot|tm) ;; *) die 'Select csot or tm touch panel' ;; esac
[[ $root_mib =~ ^[1-9][0-9]*$ ]] && ((root_mib >= 4096 && root_mib <= 65536)) || die 'Root image size must be 4096..65536 MiB'
verify="$here/../uke-linux-hardware-support/xiaomi-uke-firmware/src/verify-local-blobs.sh"
[[ -x $verify ]] || die "Local blob verifier missing: $verify"
"$verify" --root "$blobs" || die 'Bundled OEM files are incomplete; see uke-linux-hardware-support/xiaomi-uke-firmware/docs/LOCAL-BLOBS.md'
if command -v podman >/dev/null; then container=podman
elif command -v docker >/dev/null; then container=docker
else die 'Docker or Podman is required; host packages are not installed automatically'; fi
rpms=$(realpath -- "$rpms")
core_rpm=$(realpath -- "$core_rpm")
hardware_rpms=$(realpath -- "$hardware_rpms")
blobs=$(realpath -- "$blobs")
output=$(realpath -m -- "$output")
for part in core modules dtbs; do
    mapfile -t matches < <(find "$rpms" -maxdepth 1 -type f -name "senemos-uke-linux-kernel-mainline-$part-7.2.11-*.fc44.aarch64.rpm" -print)
    ((${#matches[@]} == 1)) || die "Expected one Fedora 44 7.2.11 $part RPM in $rpms"
    filename=$(basename -- "${matches[0]}")
    [[ $filename =~ ^senemos-uke-linux-kernel-mainline-$part-7\.2\.11-([1-9][0-9]*)\.fc44\.aarch64\.rpm$ ]] || die "RPM filename mismatch: $part"
    if [[ -z ${kernel_rpm_release:-} ]]; then kernel_rpm_release=${BASH_REMATCH[1]};
    else [[ $kernel_rpm_release == "${BASH_REMATCH[1]}" ]] || die 'Kernel RPM releases differ'; fi
done
hardware_files=()
for package in uke-touchscreen uke-battery-observer uke-wifi-factory uke-bluetooth; do
    mapfile -t matches < <(find "$hardware_rpms" -maxdepth 1 -type f -name "$package-0.1.0-*.fc44.aarch64.rpm" -print)
    ((${#matches[@]} == 1)) || die "Expected one Fedora 44 $package RPM in $hardware_rpms"
    hardware_files+=("${matches[0]}")
done
for entry in 'libssc:0.4.4:aarch64' 'iio-sensor-proxy:3.9:aarch64' \
             'uke-ssc-fileservice:2026.09.21:aarch64'; do
    IFS=: read -r package version arch <<< "$entry"
    mapfile -t matches < <(find "$hardware_rpms" -maxdepth 1 -type f -name "$package-$version-*.fc44.$arch.rpm" -print)
    ((${#matches[@]} == 1)) || die "Expected one Fedora 44 $package RPM in $hardware_rpms"
    hardware_files+=("${matches[0]}")
done
[[ -f $hardware_rpms/uke-fedora44-oem-data-3.0.303.0-2.fc44.noarch.rpm ]] || die 'Expected Fedora 44 OEM data RPM release 2'
hardware_files+=("$hardware_rpms/uke-fedora44-oem-data-3.0.303.0-2.fc44.noarch.rpm")
[[ ! -e $output ]] || die 'Output path already exists; select a new directory'
mkdir -p "$output"
cache_dir=$here/build/cache
mkdir -p "$cache_dir/dnf"
trap 'printf "fedora44-rootfs: incomplete output retained at %s\n" "$output" >&2' ERR
printf 'Fedora 44 %s; Linux 7.2.11-%s; source composition only\n' "$profile" "$kernel_rpm_release" > "$output/PROFILE"
printf '%s\n' "$profile" > "$output/PROFILE-ID"
printf '%s\n' "$root_mib" > "$output/ROOT-MIB"
printf '%s\n' "$panel" > "$output/TOUCH-PANEL"
sha256sum "$rpms"/senemos-uke-linux-kernel-mainline-{core,modules,dtbs}-7.2.11-"$kernel_rpm_release".fc44.aarch64.rpm | \
    sed "s|$rpms/||" > "$output/KERNEL-RPMS.sha256"
printf '%s  %s\n' "$(sha256sum "$core_rpm" | cut -d ' ' -f1)" "$(basename -- "$core_rpm")" > "$output/CORE-RPM.sha256"
sha256sum "${hardware_files[@]}" | sed "s|$hardware_rpms/||" > "$output/HARDWARE-RPMS.sha256"
sha256sum "$blobs/touch/$panel/normal.bin" "$blobs/touch/$panel/config.ini" "$blobs/touch/reference.bin" | sed "s|$blobs/||" > "$output/LOCAL-BLOBS.sha256"
run_label=()
[[ -z ${UKE_BUILD_RUN_ID:-} ]] || run_label=(--label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID")
"$container" run --rm --network=host --platform linux/arm64 --security-opt label=disable \
    "${run_label[@]}" \
    -v "$cache_dir:/build-cache" \
    -v "$output:/workspace" -v "$rpms:/kernel-rpms:ro" \
    -v "$hardware_rpms:/hardware-rpms:ro" \
    -v "$blobs:/local-blobs:ro" \
    -v "$core_rpm:/core-rpm/uke-core-meta.rpm:ro" \
    -v "$here/build-fedora44-rootfs.sh:/builder.sh:ro" \
    -v "$here/src/image/ext4-labels.cpp:/builder/ext4-labels.cpp:ro" \
    -v "$here/src/boot-pair/android-sparse.cpp:/builder/android-sparse.cpp:ro" \
    -v "$here/configs/firstboot/uke-create-user:/builder/uke-create-user:ro" \
    -v "$here/configs/firstboot/uke-create-user.service:/builder/uke-create-user.service:ro" \
    -v "$here/configs/images/uke-persist.fstab:/builder/uke-persist.fstab:ro" \
    -v "$here/configs/images/uke-ssc-fedora44.target:/builder/uke-ssc-fedora44.target:ro" \
    registry.fedoraproject.org/fedora:44 bash /builder.sh --inside
printf 'Rootfs artifacts: %s/rootfs.tar.zst and %s/userdata.img\n' "$output" "$output"
