#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../src/image/core.sh
# shellcheck disable=SC1091
source "$root/src/image/core.sh"
bash "$root/tests/early-firmware-contract.sh"
reject() { if (image_main --build boot-pair "$@") >/dev/null 2>&1; then echo 'Invalid pair request accepted' >&2; exit 1; fi; }
reject --distro debian --dry-run
reject --release 45 --dry-run
reject --release rawhide --dry-run
reject --jobs 0 --dry-run
reject --jobs
reject --device-dt
reject --root-partlabel
reject --root-partlabel= --dry-run
reject --root-partlabel system --dry-run
reject --kernel-cache
reject --unknown
(image_main --build boot-pair --offline --dry-run) | grep -F 'Two-image stock-ABL' >/dev/null
(image_main --build boot-pair --dry-run) | grep -F 'boot_a and userdata' >/dev/null
(image_main --build boot-pair --root-partlabel linux --dry-run) | grep -F 'boot_a and linux' >/dev/null
(image_main --build=boot-pair --help) | grep -F system.img >/dev/null
jq -e '.release=="44" and .patch_count==44 and .mode=="stock-abl-ext4-root" and .root_selector=="PARTNAME-userdata" and .root_partlabel=="userdata" and .boot_partition=="boot_a" and .partition_changes==["boot_a","userdata"] and .root_size_mib==3072 and .boot_tested==false and .hardware_tested==false' "$root/configs/boot/uke-boot-pair.json" >/dev/null
jq -e 'length==3 and all(.[]; (.file|test("^uke-(boot-integration|esp32-cdc|cdc-debug)-[0-9.]+-[0-9]+[.]fc44[.]aarch64[.]rpm$")) and (.sha256|test("^[a-f0-9]{64}$")))' "$root/configs/boot/uke-boot-pair-support-rpms.json" >/dev/null
if rg -n '^\s*(fastboot|adb|dd .*of=/dev/|.*set-active)' "$root/src/boot-pair"; then echo 'Device mutation found' >&2; exit 1; fi
# Resume must preserve the frozen recipe and reject tampering, including when
# the development kernel has unrelated read-only Git objects below src/.
# shellcheck source=../src/boot-pair/entry.sh
# shellcheck disable=SC1091
source "$root/src/boot-pair/entry.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
kernel=$fixture/kernel
mkdir -p "$kernel/src/boot/vendor" "$kernel/src/upstream/.git/objects" "$kernel/patches/boot" "$kernel/patches/7.2.9" "$kernel/tests"
touch "$kernel/src/boot/uke-abl.c" "$kernel/src/boot/prepare-abl-source.sh" \
    "$kernel/src/boot/sm7675-uke-ufs.dtso" "$kernel/src/boot/sm7675-uke-usb2.dtso" \
    "$kernel/src/boot/vendor/fdt_check.c" "$kernel/src/boot/sm7675-uke-adreno732.dtsi" \
    "$kernel/patches/7.2.9/0036-gpu.patch" "$kernel/patches/7.2.9/0037-interconnect.patch" \
    "$kernel/patches/boot/test.patch" \
    "$kernel/tests/abl-dt-check.cpp" "$kernel/tests/abl-dt-contract.sh" "$kernel/tests/boot-supplier-contract.sh"
printf 'unrelated read-only source\n' > "$kernel/src/upstream/.git/objects/sentinel"
chmod 444 "$kernel/src/upstream/.git/objects/sentinel"
BUILDER=$root WORK=$fixture/job
mkdir -p "$WORK/recipe" "$WORK/kernel-recipe" "$WORK/inputs"
recipe=$(pair_recipe_hash "$BUILDER" "$kernel")
pair_freeze_recipe "$kernel" "$recipe"
[[ ! -e $WORK/kernel-recipe/src/upstream ]]
chmod 444 "$WORK/kernel-recipe/src/boot/uke-abl.c"
pair_freeze_recipe "$kernel" "$recipe"
[[ $(stat -c %a "$WORK/kernel-recipe/src/boot/uke-abl.c") == 444 ]]
grep -Fx 'PARTLABEL=persist /mnt/vendor/persist ext4 ro,noload,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=10s 0 0' "$WORK/recipe/configs/images/uke-persist.fstab"
printf '# tamper\n' >> "$WORK/recipe/configs/images/uke-persist.fstab"
if (pair_freeze_recipe "$kernel" "$recipe") >/dev/null 2>&1; then echo 'Tampered persist policy accepted' >&2; exit 1; fi
cp "$BUILDER/configs/images/uke-persist.fstab" "$WORK/recipe/configs/images/uke-persist.fstab"
printf 'tamper\n' >> "$WORK/recipe/src/boot-pair/root-status.sh"
if (pair_freeze_recipe "$kernel" "$recipe") >/dev/null 2>&1; then echo 'Tampered frozen recipe accepted' >&2; exit 1; fi
echo 'Pair CLI, scope, non-mutation and frozen-recipe resume contracts passed'
