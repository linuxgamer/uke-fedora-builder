#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../src/image/core.sh
# shellcheck disable=SC1091
source "$root/src/image/core.sh"
reject() { if (image_main "$@") > /dev/null 2>&1; then echo 'Invalid image request accepted' >&2; exit 1; fi; }
reject --build desktop --dry-run
reject --distro debian --dry-run
reject --release 45 --dry-run
reject --jobs 0 --dry-run
reject --jobs invalid --dry-run
reject --jobs
reject --unknown
reject --esp-size 127 --dry-run
reject --linux-size 4095 --dry-run
reject --linux-size 999999999999 --dry-run
reject --esp-size=-1 --dry-run
reject --fat-sector 1024 --dry-run
reject --fat-sector 4096 --esp-size 256 --dry-run
reject --fat-sector --dry-run
(image_main --build core --distro=fedora --jobs=8 --offline --dry-run) >/dev/null
(image_main --build core --esp-size=512 --linux-size 8192 --fat-sector=4096 --offline --dry-run) | grep -F 'EXT4 8192 MiB, FAT32 ESP 512 MiB (4096-byte sectors)' >/dev/null
jq -e '.boot_tested==false and .hardware_tested==false and .physical_geometry_verified==false and .cdc.tablet_usb_role=="host" and .development_root_shell==true' "$root/configs/images/core-rawhide.json" >/dev/null
for input in "$root"/manifests/images/core-*.json; do
    jq -e 'all(.packages[]; (.sha256|test("^[a-f0-9]{64}$")) and (.file|test("^[A-Za-z0-9+_.~-]+\\.rpm$")) and (.url|startswith("https://")))' "$input" >/dev/null
done
fixture=$(mktemp -d); trap 'rm -rf "$fixture"' EXIT
[[ $(package_manager fedora '') == dnf ]]
[[ $(package_manager ubuntu debian) == apt ]]
[[ $(package_manager opensuse-tumbleweed suse) == zypper ]]
[[ $(package_manager arch '') == pacman ]]
[[ $(package_manager postmarketos alpine) == apk ]]
if package_manager unsupported ''; then exit 1; fi
printf input > "$fixture/input"
verify_cache "$fixture/input" "$(sha256sum "$fixture/input" | cut -d ' ' -f1)"
if (verify_cache "$fixture/input" "$(printf corrupted | sha256sum | cut -d ' ' -f1)") >/dev/null 2>&1; then exit 1; fi
if (verify_cache "$fixture/missing" "$(sha256sum "$fixture/input" | cut -d ' ' -f1)") >/dev/null 2>&1; then exit 1; fi
bash "$root/src/audit/check-console-session.sh" "$fixture"
mkdir -p "$fixture/usr/share/wayland-sessions" "$fixture/usr/share/xsessions"
: > "$fixture/usr/share/wayland-sessions/example.desktop"
if bash "$root/src/audit/check-console-session.sh" "$fixture" >/dev/null 2>&1; then exit 1; fi
mv "$fixture/usr/share/wayland-sessions/example.desktop" "$fixture/usr/share/xsessions/example.desktop"
if bash "$root/src/audit/check-console-session.sh" "$fixture" >/dev/null 2>&1; then exit 1; fi
bash "$root/tests/target-privacy-policy.sh"
bash "$root/tests/device-preflight-contract.sh"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$root/src/device/preflight.sh"; fi
printf '%s\n' 'Image CLI, pinned-input corruption, profile gates and privacy fixtures passed'
