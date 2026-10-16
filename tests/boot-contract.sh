#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../src/image/core.sh
# shellcheck disable=SC1091
source "$root/src/image/core.sh"
reject() { if (image_main --build boot "$@") > /dev/null 2>&1; then echo 'Invalid boot request accepted' >&2; exit 1; fi; }
reject --build core --dry-run
reject --distro debian --dry-run
reject --release 45 --dry-run
reject --release rawhide --dry-run
reject --jobs 0 --dry-run
reject --jobs
reject --stock-boot
reject --reuse-boot-cache
reject --boot-template
reject --boot-template foreign --dry-run
reject --unknown
(image_main --build boot --offline --jobs 2 --dry-run) | grep -F 'Android boot v4 / boot_b' >/dev/null
(image_main --build=boot --help) | grep -F fedora_boot.img >/dev/null
jq -e '.release=="44" and .header_version==4 and .patch_count==44 and .mode=="initramfs-debug-only" and .boot_tested==false and .hardware_tested==false and .dt_handoff_verified==false and (.kernel_command_line|contains("rd.systemd.unit=uke-boot-debug.target"))' "$root/configs/boot/uke-boot-b.json" >/dev/null
if rg -n '^\s*(fastboot|adb|dd .*of=/dev/|.*set-active)' "$root/src/boot"; then echo 'Device mutation found' >&2; exit 1; fi
echo 'Boot CLI, explicit debug scope and non-mutation contracts passed'
