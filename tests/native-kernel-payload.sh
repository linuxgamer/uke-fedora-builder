#!/usr/bin/env bash
# Host-only audit of actual signed COPR outputs. Never runs tablet payloads.
set -Eeuo pipefail
[[ $# == 4 && -d $1 && -d $2 && -f $3 && ! -e $4 ]]
builder=$1 packages_dir=$2 profile=$3 out=$4
mkdir -p "$out/payload"
version=$(jq -er .version "$profile")
release=$version-senemos-uke
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
packages=("$packages_dir"/*.aarch64.rpm)
[[ ${#packages[@]} == 4 ]]
rpmkeys --import "$builder/configs/keys/uke-copr.asc"
printf '[]\n' > "$out/packages.json"
for package in "${packages[@]}"; do
    rpmkeys --checksig "$package" | grep -F 'signatures OK'
    [[ $(rpm -qp --qf '%{ARCH}:%{VERSION}' "$package") == "aarch64:$version" ]]
    rpm -qp --requires "$package" > "$out/${package##*/}.requires"
    (cd "$out/payload"; rpm2cpio "$package" | cpio -idm --quiet --no-absolute-filenames)
    jq --arg file "${package##*/}" --arg sha "$(sha256sum "$package" | cut -d ' ' -f1)" \
        --arg nevra "$(rpm -qp --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}' "$package")" \
        '. + [{file:$file,sha256:$sha,nevra:$nevra}]' "$out/packages.json" > "$out/packages.json.part"
    mv "$out/packages.json.part" "$out/packages.json"
done
root=$out/payload/usr/lib/modules/$release
identity=$out/payload/usr/share/senemos/uke/$release
jq -S . "$identity/source-lock.json" > "$out/source.json"
jq -S . "$profile" > "$out/expected-source.json"
cmp "$out/source.json" "$out/expected-source.json"
cmp "$identity/applied-patches.txt" <(jq -r '.patches[].path|split("/")|last' "$profile")
bash "$builder/src/audit/check-target-elf.sh" "$out/payload"
bash "$builder/src/audit/check-target-privacy.sh" "$out/payload"
llvm-readobj --file-headers "$root/vmlinuz" | grep -F IMAGE_FILE_MACHINE_ARM64
fdtget -t s "$root/dtb/qcom/sm7675-xiaomi-uke.dtb" / compatible | grep -F xiaomi,uke
: > "$out/module-abi.txt"
while IFS= read -r -d '' module; do
    [[ $(modinfo -F vermagic "$module") == "$release "* ]]
    zstd -dc "$module" > "$out/module-check.ko"
    llvm-readelf -h "$out/module-check.ko" | grep -F AArch64 >/dev/null
    if LC_ALL=C grep -aEq '/home/[^/[:space:]]+/|/Users/[^/[:space:]]+/|C:[\\]Users[\\]' "$out/module-check.ko"; then exit 1; fi
    printf '%s\t%s\n' "${module#"$out/payload/"}" "$(modinfo -F vermagic "$module")" >> "$out/module-abi.txt"
done < <(find "$root/kernel" -type f -name '*.ko.zst' -print0 | sort -z)
[[ $(wc -l < "$out/module-abi.txt") == 1146 ]]
depmod -e -F "$root/System.map" -b "$out/payload" -m /usr/lib/modules "$release" 2> "$out/depmod-validation.txt"
[[ ! -s $out/depmod-validation.txt && -s $root/modules.dep.bin ]]
rm "$out/module-check.ko"
sha256sum "$root/vmlinuz" "$root/config" "$root/dtb/qcom/sm7675-xiaomi-uke.dtb" "$out/module-abi.txt" > "$out/payload-checksums.txt"
echo 'Signed native kernel source identity, all module ELF/vermagic/dependencies and payload audits passed'
