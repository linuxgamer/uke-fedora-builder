#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../src/image/core.sh
# shellcheck disable=SC1091
source "$root/src/image/core.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
pair=$fixture/pair
mkdir -p "$pair/qemu" "$fixture/bin"
truncate -s 100663296 "$pair/fedora_boot.img"
# A tiny RAW/FILL-header fixture: preflight verifies header and the sealed
# digest, not the full sparse decoder already exercised by codec tests.
printf '\x3a\xff\x26\xed\x01\x00\x00\x00\x1c\x00\x0c\x00\x00\x10\x00\x00\x00\x00\x0c\x00\x68\x02\x00\x00\x00\x00\x00\x00' > "$pair/system.img"
printf '%s\n' '{"real_ext4_root_transition":true,"root_pid1_systemd":true,"selinux_enforcing":true,"local_tty_keyboard_command":true,"wrong_partition_name_rejected":true,"wrong_filesystem_uuid_rejected":true}' > "$pair/qemu/result.json"
for file in packages.tsv kernel.config validation.json INSTALL.md README.txt; do printf 'fixture\n' > "$pair/$file"; done
jq -n --arg boot "$(sha256sum "$pair/fedora_boot.img" | cut -d ' ' -f1)" \
    --arg system "$(sha256sum "$pair/system.img" | cut -d ' ' -f1)" \
    --arg vm "$(sha256sum "$pair/qemu/result.json" | cut -d ' ' -f1)" \
    --slurpfile result "$pair/qemu/result.json" \
    '{schema_version:1,profile:{device:"uke",mode:"stock-abl-ext4-root",distribution:"fedora",release:"44",root_size_mib:3072,boot_partition_bytes:100663296,root_uuid:"03ea9569-c96d-cb08-0a64-53c6f816aa32",kernel_command_line:"root=UUID=03ea9569-c96d-cb08-0a64-53c6f816aa32 rw"},sha256:{boot:$boot,system:$system},checks:{module_byte_match:1144,privacy:true,sparse_roundtrip:true,full_sparse_logical_coverage:true},qemu_tested:true,qemu_evidence:{sha256:$vm,result:$result[0]},boot_tested:false,hardware_tested:false,flash_executed:false}' > "$pair/manifest.json"
cp "$pair/manifest.json" "$fixture/original-manifest"
checksums() { (cd "$pair"; sha256sum fedora_boot.img system.img manifest.json qemu/result.json packages.tsv kernel.config validation.json INSTALL.md README.txt > SHA256SUMS); }
checksums

cat > "$fixture/bin/fastboot" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$PREFLIGHT_LOG"
if [[ $* == devices ]]; then
    case $PREFLIGHT_CASE in
        none|adb|recovery|unauthorized) exit 0;;
        multiple) printf 'fixture-one fastboot\nfixture-two fastboot\n';;
        *) printf 'fixture-one fastboot\n';;
    esac
    exit 0
fi
[[ $# == 4 && $1 == -s && $2 == fixture-one && $3 == getvar ]] || exit 99
key=$4
case $key in
    product) value=uke; [[ $PREFLIGHT_CASE != foreign ]] || value=other;;
    current-slot) value=${PREFLIGHT_SLOT:-a}; [[ $PREFLIGHT_CASE != slot-b ]] || value=b;;
    unlocked) value=yes; [[ $PREFLIGHT_CASE != locked ]] || value=no;;
    is-userspace) value=no; [[ $PREFLIGHT_CASE != fastbootd ]] || value=yes;;
    is-logical:linux|is-logical:userdata) value=no; [[ $PREFLIGHT_CASE != logical ]] || value=yes;;
    partition-size:boot_b|partition-size:boot_a) value=0x06000000; [[ $PREFLIGHT_CASE != small-boot ]] || value=0x1000;;
    partition-size:linux|partition-size:userdata)
        value=0xc0000000
        case $PREFLIGHT_CASE in missing-linux) exit 1;; small-linux) value=1048576;; huge) value=999999999999999999999999999999;; esac;;
    *) exit 99;;
esac
if [[ $PREFLIGHT_CASE == whitespace ]]; then
    printf '%s:  %s  \n' "$key" "$value" >&2
else
    printf '(bootloader) %s: %s\n' "$key" "$value" >&2
fi
[[ $PREFLIGHT_CASE != duplicate ]] || printf '(bootloader) %s: %s\n' "$key" "$value" >&2
MOCK
cat > "$fixture/bin/adb" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$PREFLIGHT_LOG"
if [[ $* == 'devices -l' ]]; then
    printf 'List of devices attached\n'
    case $PREFLIGHT_CASE in
        adb|recovery)
            state=device; [[ $PREFLIGHT_CASE != recovery ]] || state=recovery
            printf 'private-serial %s product:uke model:private device:uke transport_id:7\n' "$state";;
        unauthorized) printf 'private-serial unauthorized transport_id:7\n';;
    esac
    exit 0
fi
[[ $# == 5 && $1 == -t && $2 == 7 && $3 == shell && $4 == -T ]] || exit 99
[[ $5 == *'/sys/class/block/'* && $5 != *'su '* && $5 != *'dd '* ]] || exit 99
printf 'product=uke\nslot=_a\nlocked=0\nboot_b_sectors=196608\nlinux_sectors=6291456\nroot_physical=yes\n'
MOCK
chmod +x "$fixture/bin/adb" "$fixture/bin/fastboot"
export PATH="$fixture/bin:$PATH" PREFLIGHT_LOG=$fixture/commands PREFLIGHT_CASE=none
run_check() {
    local expected=$1 actual=0; shift
    : > "$PREFLIGHT_LOG"
    (image_main --check-device --pair "$pair" "$@") > "$fixture/result.json" 2> "$fixture/stderr" || actual=$?
    [[ $actual == "$expected" ]] || { cat "$fixture/stderr"; printf 'Expected %s, got %s\n' "$expected" "$actual" >&2; exit 1; }
    if rg -n '(^| )(flash|erase|format|reboot|set-active|unlock|root|remount)( |$)' "$PREFLIGHT_LOG"; then echo 'Device mutation command attempted' >&2; exit 1; fi
    if [[ $expected != 1 ]]; then jq -e '.local_pair_verified and .device_write_executed==false and .boot_tested==false' "$fixture/result.json" >/dev/null; fi
}
run_check 0 --offline
[[ ! -s $PREFLIGHT_LOG ]]
# Keep the sealed historical UUID pair inspectable, and verify the new name
# selector against resealed VM evidence rather than accepting either blindly.
cp "$pair/qemu/result.json" "$fixture/original-qemu"
jq 'del(.wrong_filesystem_uuid_rejected) | .changed_filesystem_uuid_accepted=true | .wrong_filesystem_type_rejected=true | .duplicate_partition_name_rejected=true' "$fixture/original-qemu" > "$pair/qemu/result.json"
name_manifest() {
    local label=${1:-linux} boot=boot_b
    [[ $label != userdata ]] || boot=boot_a
    jq --arg label "$label" --arg boot "$boot" --slurpfile result "$pair/qemu/result.json" --arg vm "$(sha256sum "$pair/qemu/result.json" | cut -d ' ' -f1)" \
        '.profile.root_selector=("PARTNAME-"+$label) | .profile.root_partlabel=$label | .profile.boot_partition=$boot | .profile.partition_changes=[$boot,$label] | .profile.kernel_command_line=("root=PARTLABEL="+$label+" rw") |
         .qemu_evidence={sha256:$vm,result:$result[0]}' "$fixture/original-manifest" > "$pair/manifest.json"
    checksums
}
name_manifest
run_check 0 --offline
jq '.profile.kernel_command_line="root=UUID=03ea9569-c96d-cb08-0a64-53c6f816aa32 rw"' "$pair/manifest.json" > "$fixture/invalid-selector"
mv "$fixture/invalid-selector" "$pair/manifest.json"
checksums
run_check 1 --offline
for field in changed_filesystem_uuid_accepted wrong_filesystem_type_rejected duplicate_partition_name_rejected; do
    cp "$pair/qemu/result.json" "$fixture/name-qemu"
    jq --arg field "$field" '.[$field]=false' "$fixture/name-qemu" > "$pair/qemu/result.json"
    name_manifest
    run_check 1 --offline
    cp "$fixture/name-qemu" "$pair/qemu/result.json"
done
# Userdata must bind the new target and VM evidence; the preserved slot is B.
jq '.root_partition_label="userdata" | .root_filesystem_growth=true' "$pair/qemu/result.json" > "$fixture/userdata-qemu"
cp "$fixture/userdata-qemu" "$pair/qemu/result.json"
name_manifest userdata
run_check 0 --offline
PREFLIGHT_CASE=good PREFLIGHT_SLOT=b run_check 0
jq -e '.root_partition=="userdata" and .boot_partition=="boot_a" and .root_bytes==3221225472' "$fixture/result.json" >/dev/null
rg -F 'getvar partition-size:userdata' "$PREFLIGHT_LOG" >/dev/null
rg -F 'getvar partition-size:boot_a' "$PREFLIGHT_LOG" >/dev/null
PREFLIGHT_CASE=good PREFLIGHT_SLOT=a run_check 2
jq '.profile.kernel_command_line="root=PARTLABEL=linux rw"' "$pair/manifest.json" > "$fixture/wrong-target"
mv "$fixture/wrong-target" "$pair/manifest.json"
checksums
run_check 1 --offline
name_manifest userdata
jq '.root_partition_label="linux"' "$pair/qemu/result.json" > "$fixture/wrong-vm-target"
mv "$fixture/wrong-vm-target" "$pair/qemu/result.json"
name_manifest userdata
run_check 1 --offline
cp "$fixture/original-qemu" "$pair/qemu/result.json"
cp "$fixture/original-manifest" "$pair/manifest.json"
checksums
run_check 2
jq -e '.transport=="unavailable"' "$fixture/result.json" >/dev/null
PREFLIGHT_CASE=good run_check 0
jq -e '.status=="bootloader-geometry-compatible-owner-checks-required" and .linux_bytes==3221225472' "$fixture/result.json" >/dev/null
PREFLIGHT_CASE=whitespace run_check 0
jq -e '.boot_b_bytes==100663296 and .linux_bytes==3221225472' "$fixture/result.json" >/dev/null
for PREFLIGHT_CASE in multiple locked foreign slot-b fastbootd logical missing-linux small-linux small-boot duplicate huge unauthorized; do run_check 2; done
for PREFLIGHT_CASE in adb recovery; do
    run_check 2
    jq -e '.transport=="adb" and .linux_physical_partition=="yes" and .linux_bytes==3221225472 and .blockers==["bootloader-fastboot-check-required"]' "$fixture/result.json" >/dev/null
    if rg -n 'private-serial|fixture-one|/home/|model:private' "$fixture/result.json"; then echo 'Private inventory leaked' >&2; exit 1; fi
    rg -F -- '-t 7 shell -T' "$PREFLIGHT_LOG" >/dev/null
done
run_check 0 --offline --report "$fixture/report.json"
[[ $(stat -c %a "$fixture/report.json") == 600 ]]
run_check 1 --offline --report "$fixture/report.json"
run_check 1 --offline --build boot-pair
run_check 1 --pair
cp "$pair/SHA256SUMS" "$fixture/original-checksums"
printf '%s\n' "$(head -n 1 "$pair/SHA256SUMS")" >> "$pair/SHA256SUMS"
run_check 1 --offline
cp "$fixture/original-checksums" "$pair/SHA256SUMS"
printf tampered >> "$pair/system.img"
run_check 1 --offline
truncate -s 28 "$pair/system.img"
mv "$pair/system.img" "$fixture/system.img"
ln -s "$fixture/system.img" "$pair/system.img"
run_check 1 --offline
rm "$pair/system.img"
mv "$fixture/system.img" "$pair/system.img"
jq '.profile.kernel_command_line="root=UUID=wrong rw"' "$fixture/original-manifest" > "$pair/manifest.json"
checksums
run_check 1 --offline
cp "$fixture/original-manifest" "$pair/manifest.json"
jq '.wrong_filesystem_uuid_rejected=false' "$pair/qemu/result.json" > "$fixture/wrong-result"
mv "$fixture/wrong-result" "$pair/qemu/result.json"
checksums
run_check 1 --offline
echo 'Device preflight: offline identity, transport/read-only gates, private reports and corrupt-pair rejection passed'
