#!/usr/bin/env bash
# Exercise the real planner with stub RPM/DNF commands inside a private mount view.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work/bin" "$work/job/"{inputs,audit,logs,root/var/lib/uke-touch}
printf fixture > "$work/job/root/var/lib/uke-touch/reference.bin"
chmod 600 "$work/job/root/var/lib/uke-touch/reference.bin"
touch "$work/job/packages.complete"
cat > "$work/bin/rpm" <<'RPM'
#!/bin/bash
case " $* " in
    *' --import '*) exit 0;;
    *' -qa '*) cat /job/inventory.tsv;;
    *) exit 2;;
esac
RPM
cat > "$work/bin/dnf5" <<'DNF'
#!/bin/bash
printf '%q ' "$@" >> /job/commands
printf '\n' >> /job/commands
printf 'Nothing to do\n'
DNF
printf '#!/bin/bash\nexit 0\n' > "$work/bin/install"
chmod +x "$work/bin/"*
profile=$work/profile.json
cp "$repo/configs/images/userdata-rawhide.json" "$profile"
release=$(jq -r .kernel_release "$profile")
for version in 7.2.11-14 7.2.11-17 7.2.12-1 7.2.12-3 7.2.12-5 "$release"; do
    for component in boot core dtbs modules; do
        name=senemos-uke-linux-kernel-mainline-$component
        printf '%s\t%s.fc46\t%s-%s.fc46.aarch64\n' "$name" "$version" "$name" "$version" >> "$work/job/inventory.tsv"
        if [[ $version == 7.2.11-14 || $version == 7.2.11-17 ]]; then
            mkdir -p "$work/job/inputs/kernel-copr/$version"
            touch "$work/job/inputs/kernel-copr/$version/$name-$version.fc46.aarch64.rpm"
        fi
    done
done
printf 'senemos-uke-linux-kernel-unstable-core\t7.3.0-2.fc46\tunrelated\n' >> "$work/job/inventory.tsv"
printf 'uke-power-profile-backend\t1.1.1-8.fc46\tuke-power-profile-backend-1.1.1-8.fc46.aarch64\n' >> "$work/job/inventory.tsv"
run() {
    bwrap --tmpfs / --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
        --symlink usr/lib64 /lib64 --dev /dev --proc /proc --unshare-net --ro-bind "$work/bin" /fixture/bin \
        --ro-bind "$repo" /builder --ro-bind "$profile" /builder/configs/images/userdata-rawhide.json \
        --bind "$work/job" /job --tmpfs /etc --dir /etc/rpm --dir /etc/yum.repos.d --dir /etc/pki/rpm-gpg \
        --setenv PATH /fixture/bin:/usr/bin:/bin --setenv UKE_COMPOSE_SOLVE_ONLY 1 \
        /bin/bash /builder/src/image/install-userdata-device-packages.sh
}
run
[[ $(wc -l < "$work/job/commands") == 4 ]]
[[ $(grep -c -- '--setopt=installonly_limit=0' "$work/job/commands") == 4 ]]
retire=$(grep ' remove ' "$work/job/commands")
[[ $retire != *7.2.11-14* && $retire != *7.2.11-17* && $retire != *"$release"* && $retire != *unrelated* ]]
[[ $retire == *uke-power-profile-backend-1.1.1-8.fc46.aarch64* ]]
install_selection=$(grep ' install --allowerasing ' "$work/job/commands")
[[ $install_selection == *power-profiles-daemon* && $install_selection != *uke-power-profile-backend* ]]
[[ $install_selection == *factory-wlan-v1* && $install_selection == *factory-bluetooth-v1* ]]
[[ $install_selection != *uke-bluetooth* && $install_selection != *uke-wifi-factory* ]]
for version in 7.2.12-1 7.2.12-3 7.2.12-5; do
    for component in boot core dtbs modules; do
        [[ $retire == *"senemos-uke-linux-kernel-mainline-$component-$version.fc46.aarch64"* ]]
    done
done
: > "$work/job/commands"
cat > "$work/bin/jq" <<'JQ'
#!/bin/bash
for argument; do [[ $argument != 'index($release)!=null' ]] || exit 99; done
exec /usr/bin/jq "$@"
JQ
chmod +x "$work/bin/jq"
if run > "$work/refused.log" 2>&1; then exit 1; fi
[[ ! -s $work/job/commands ]]
find "$work/bin/jq" -delete
jq '.root_filesystem="ext4" | .retained_kernel_releases=[]' "$profile" > "$work/next.json"
mv "$work/next.json" "$profile"
grep -F "$release.fc46" "$work/job/inventory.tsv" > "$work/selected.tsv"
mv "$work/selected.tsv" "$work/job/inventory.tsv"
run
[[ $(wc -l < "$work/job/commands") == 2 ]]
grep -Fq 'root-filesystem-v2' "$work/job/commands"
printf 'Image planner retains all declared cohorts, prunes only its generated root, bounds DNF, refuses failed retention queries and gates future root ABI; no real RPM/DNF transaction.\n'
