#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../src/image/core.sh
# shellcheck disable=SC1091
source "$root/src/image/core.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
pair=$fixture/pair
mkdir -p "$pair/qemu"
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

run_check() {
    local expected=$1 actual=0; shift
    (image_main --check-device --pair "$pair" "$@") > "$fixture/result.json" 2> "$fixture/stderr" || actual=$?
    [[ $actual == "$expected" ]] || { cat "$fixture/stderr"; printf 'Expected %s, got %s\n' "$expected" "$actual" >&2; exit 1; }
}
run_check 0
jq -e '.status=="local-pair-verified" and .transport=="offline" and
       .live_device_checked==false and .device=="unknown" and
       .device_write_executed==false and .boot_tested==false' "$fixture/result.json" >/dev/null
run_check 0 --offline --report "$fixture/report.json"
[[ $(stat -c %a "$fixture/report.json") == 600 ]]
run_check 1 --offline --report "$fixture/report.json"
run_check 1 --build boot-pair
run_check 1 --pair
cp "$pair/SHA256SUMS" "$fixture/original-checksums"
cp "$pair/system.img" "$fixture/original-system"
printf '%s\n' "$(head -n 1 "$pair/SHA256SUMS")" >> "$pair/SHA256SUMS"
run_check 1
cp "$fixture/original-checksums" "$pair/SHA256SUMS"
printf tampered >> "$pair/system.img"
run_check 1
cp "$fixture/original-system" "$pair/system.img"
truncate -s 28 "$pair/system.img"
mv "$pair/system.img" "$fixture/system.img"
ln -s "$fixture/system.img" "$pair/system.img"
run_check 1
rm "$pair/system.img"
mv "$fixture/system.img" "$pair/system.img"
cp "$fixture/original-system" "$pair/system.img"
cp "$pair/manifest.json" "$fixture/original-manifest"
jq '.profile.release="rawhide"' "$pair/manifest.json" > "$fixture/invalid-manifest"
mv "$fixture/invalid-manifest" "$pair/manifest.json"
checksums
run_check 1
printf '%s\n' 'Device preflight: local identity, private reports and corrupt-pair rejection passed; no device tool was invoked.'
