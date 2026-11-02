#!/bin/bash
# Runs inside a newly bootstrapped native ARM64 root, never on a tablet.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
trap 'printf "Ubuntu root configuration failed at line %s\n" "$LINENO" >&2' ERR
[[ $(uname -m) == aarch64 && $(dpkg --print-architecture) == arm64 ]]
# shellcheck source=/dev/null
source /etc/os-release
[[ $VERSION_CODENAME == tenacious && $VERSION_ID == 27.04 ]]
[[ -d /run/uke-build-inputs && -f /run/uke-build-inputs/ppa.gpg ]]
inputs=/run/uke-build-inputs
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
# Ubuntu's native libstdc++ runtime also carries optional GDB Python printers.
# Do not install those debugger-only helpers on the Python-free tablet root;
# retain the native library, package metadata and every copyright/license.
printf 'path-exclude=/usr/share/gcc/python/*\npath-exclude=/usr/share/gdb/auto-load/usr/lib/aarch64-linux-gnu/libstdc++*-gdb.py\npath-exclude=/usr/share/apport/package-hooks/*.py\n' > /etc/dpkg/dpkg.cfg.d/uke-no-python-debuggers
install -Dm644 "$inputs/ppa.gpg" /usr/share/keyrings/uke-linux-unstable.gpg
printf 'deb [arch=arm64 signed-by=/usr/share/keyrings/uke-linux-unstable.gpg] https://ppa.launchpadcontent.net/mcs45tr/uke-linux-unstable/ubuntu tenacious main\n' > /etc/apt/sources.list.d/uke-linux-unstable.list
apt-get update
apt-get install -y --no-install-recommends --reinstall libstdc++6
# Bootstrap may already contain optional crash-report hooks. Reapply only
# their owning packages with the explicit exclusion; never delete arbitrary
# package-owned files or change AppArmor policy/loading programs.
mapfile -t hook_owners < <(dpkg-query -S '/usr/share/apport/package-hooks/*.py' 2>/dev/null | sed 's/: \/.*//' | sort -u || true)
if ((${#hook_owners[@]})); then apt-get install -y --no-install-recommends --reinstall "${hook_owners[@]}"; fi
apt-get install -y --no-install-recommends systemd-sysv systemd-resolved udev dbus apparmor ca-certificates e2fsprogs util-linux kmod iproute2 libpam-systemd locales fonts-dejavu-core console-setup-linux uke-speaker-firmware
# These are locally built, fully verified native artifact DEBs. APT keeps the
# exact inter-package dependencies; no fake kernel/firmware ABI is supplied.
apt-get install -y --no-install-recommends "$inputs/debs/"*.deb
install -Dm755 "$inputs/uke-apparmor-probe" /usr/libexec/uke-apparmor-probe
install -Dm644 "$inputs/uke-apparmor-probe.profile" /etc/apparmor.d/uke-apparmor-probe
install -Dm644 "$inputs/uke-apparmor-verify.service" /usr/lib/systemd/system/uke-apparmor-verify.service
install -Dm755 "$inputs/uke-test-result.sh" /usr/libexec/uke-test-result
install -Dm644 "$inputs/uke-test-result.service" /usr/lib/systemd/system/uke-test-result.service
install -Dm644 "$inputs/uke-test-result.timer" /usr/lib/systemd/system/uke-test-result.timer
install -d /etc/uke-test /etc/systemd/system/multi-user.target.requires
printf 'UKE_APPARMOR_ALLOWED\n' > /etc/uke-test/allowed
printf 'Public denial fixture; contains no private data.\n' > /etc/uke-test/denied
chmod 644 /etc/uke-test/{allowed,denied}
ln -s /usr/lib/systemd/system/uke-apparmor-verify.service /etc/systemd/system/multi-user.target.requires/
systemctl --root=/ enable apparmor.service
systemctl --root=/ enable uke-test-result.service
systemctl --root=/ enable uke-test-result.timer
install -d /etc/systemd/system/apparmor.service.d
printf '[Unit]\nOnFailure=uke-test-result.service\n' > /etc/systemd/system/apparmor.service.d/uke-test-result.conf
# Reserve the visible VT for a read-only result, preserving all account locks.
systemctl --root=/ mask getty@tty1.service
systemctl --root=/ set-default multi-user.target
# Compile policy syntax without loading it into the build server's kernel.
apparmor_parser --skip-kernel-load --skip-cache /etc/apparmor.d/uke-apparmor-probe
printf 'LABEL=UKE_LINUX / ext4 defaults 0 1\n' > /etc/fstab
printf 'uke-ubuntu-test\n' > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 uke-ubuntu-test\n' > /etc/hosts
printf 'LANG=C.UTF-8\n' > /etc/default/locale
# Retain distribution account locks. No test password, autologin, SSH server,
# SSH key, remote shell or sudo exemption is created.
awk -F: '$2!="*" && $2!="!" && $2!="!*" && $2!="!!" {exit 1}' /etc/shadow
[[ -z $(dpkg-query -W -f='${binary:Package}\n' | grep -Ei '(^|[-:])(python[0-9.]*|libpython[0-9.]*)(-|:|$)' || true) ]]
find /usr /opt /etc -type f \( -name '*.py' -o -name '*.pyc' -o -name '*.pyo' \) -print > "$inputs/rejected-python-files.txt"
if [[ -s $inputs/rejected-python-files.txt ]]; then cat "$inputs/rejected-python-files.txt" >&2; exit 1; fi
[[ -z $(find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*' -print -quit) ]]
# systemd's stock provision.conf creates this empty protected directory.
# Its existence is not a credential; any populated entry is rejected.
if [[ -e /root/.ssh || -L /root/.ssh ]]; then
 [[ -d /root/.ssh && ! -L /root/.ssh && $(stat -c %u /root/.ssh) == 0 && $(stat -c %a /root/.ssh) == 700 ]]
 [[ -z $(find /root/.ssh -mindepth 1 -print -quit) ]]
fi
[[ $(sha256sum /usr/lib/firmware/qcom/uke/audio/fs19xx.fsm | cut -d' ' -f1) == f319e71d60ed19d539296665fa06cc07fbcf93bf82f773c787bed65289129e7b ]]
dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' > "$inputs/root-packages.tsv"
apt-cache policy uke-speaker-firmware > "$inputs/ppa-policy.txt"
cp /var/lib/apt/lists/*InRelease "$inputs/"
systemd-analyze verify /usr/lib/systemd/system/uke-apparmor-verify.service /usr/lib/systemd/system/uke-test-result.service /usr/lib/systemd/system/uke-test-result.timer
printf '%s\n' root_constructed=true python_runtime=false desktop=none credentials_created=false apparmor_policy_compiled=true runtime_enforcement_tested=false > "$inputs/root-qualification"
