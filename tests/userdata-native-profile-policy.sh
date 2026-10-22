#!/usr/bin/env bash
# Ordinary-file and RPM stubs only; no real package or hardware acceptance.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work/bin" "$work/job/"{audit,root,original-fedora}
contexts=etc/selinux/targeted/contexts/files
mkdir -p "$work/job/root/$contexts" "$work/job/root/var/lib/selinux/targeted/active" "$work/job/original-fedora/$contexts"
for name in file_contexts file_contexts.homedirs; do
    printf 'original Fedora fixture %s\n' "$name" > "$work/job/original-fedora/$contexts/$name"
    cp "$work/job/original-fedora/$contexts/$name" "$work/job/root/$contexts/$name"
    cp "$work/job/original-fedora/$contexts/$name" "$work/job/root/var/lib/selinux/targeted/active/$name"
done
touch "$work/job/device-packages.complete"
cat > "$work/bin/rpm" <<'RPM'
#!/bin/bash
case "$*" in
    '--root /job/root -q --provides senemos-uke-linux-kernel-mainline-core-7.2.12-9.fc46.aarch64')
        printf 'uke-kernel(platform-profile-qos-v1) = 1\n';;
    '--root /job/root -q --provides senemos-uke-linux-kernel-mainline-core-7.2.12-6.fc46.aarch64')
        printf 'older selected kernel; another installed kernel has native profiles\n';;
    '--root /job/root -V power-profiles-daemon') [[ ! -e /job/modified-daemon ]];;
    '--root /job/root -q uke-power-profile-backend') [[ -e /job/legacy-backend ]];;
    '--root /job/root -q uke-bluetooth') [[ -e /job/legacy-bluetooth ]];;
    '--root /job/root -q uke-wifi-factory') [[ -e /job/legacy-wlan ]];;
    '--root /job/root -q --whatprovides uke-boot-integration(factory-wlan-v1) --qf %{NAME}\n'|\
    '--root /job/root -q --whatprovides uke-boot-integration(factory-bluetooth-v1) --qf %{NAME}\n')
        if [[ -e /job/wrong-factory-owner ]]; then printf 'unrelated\n'; else printf 'uke-boot-integration\n'; fi;;
    *) exit 2;;
esac
RPM
chmod +x "$work/bin/rpm"
printf '{"kernel_release":"7.2.12-9"}\n' > "$work/profile.json"
run() {
    bwrap --tmpfs / --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
        --symlink usr/lib64 /lib64 --dev /dev --proc /proc --unshare-net \
        --ro-bind "$repo" /builder --ro-bind "$work/profile.json" /builder/configs/images/userdata-rawhide.json \
        --bind "$work/job" /job --ro-bind "$work/bin" /fixture/bin \
        --setenv PATH /fixture/bin:/usr/bin:/bin /bin/bash /builder/src/image/audit-userdata-policy-sources.sh
}
run > "$work/passed.log"
for marker in legacy-backend modified-daemon legacy-bluetooth legacy-wlan wrong-factory-owner; do
    touch "$work/job/$marker"
    if run > "$work/refused.log" 2>&1; then exit 1; fi
    find "$work/job/$marker" -delete
done
printf '{"kernel_release":"7.2.12-6"}\n' > "$work/profile.json"
if run > "$work/refused.log" 2>&1; then exit 1; fi
printf '{"kernel_release":"7.2.12-9"}\n' > "$work/profile.json"
overlay=$work/job/root/usr/lib/systemd/system/power-profiles-daemon.service.d/60-uke-cpufreq.conf
mkdir -p "$(dirname "$overlay")"
ln -s /missing-retired-overlay "$overlay"
if run > "$work/refused.log" 2>&1; then exit 1; fi
find "$overlay" -delete
printf 'unexpected context\n' >> "$work/job/root/$contexts/file_contexts"
if run > "$work/refused.log" 2>&1; then exit 1; fi
printf 'Native image policy fixture passed: selected ABI, original daemon, factory bridge owner, retired packages/overlay and exact Fedora contexts; no real RPM or device test.\n'
