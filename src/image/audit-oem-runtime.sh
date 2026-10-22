#!/usr/bin/env bash
# Offline file/profile verification; never starts a service or accesses a device.
set -Eeuo pipefail
[[ $# == 4 ]] || { echo 'Usage: audit-oem-runtime.sh ROOT OEM_MANIFEST FIRMWARE_MANIFEST OUTPUT' >&2; exit 2; }
root=$(realpath -e "$1") oem=$2 firmware=$3 output=$4
config=$(dirname "$0")/../../configs/images/userdata-rawhide.json
[[ -d $root && $root != / && ! -L $output ]]
jq -e '.profile=="plasma-userdata-private-device-test" and .oem_runtime_inputs.required==true and .oem_runtime_inputs.touch_panel=="csot"' "$config" >/dev/null
[[ $(sha256sum "$oem" | cut -d ' ' -f1) == "$(jq -er .oem_runtime_inputs.oem_manifest_sha256 "$config")" ]]
[[ $(sha256sum "$firmware" | cut -d ' ' -f1) == "$(jq -er .oem_runtime_inputs.firmware_manifest_sha256 "$config")" ]]
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
check_file() {
    local path=$1 bytes=$2 expected=$3 provenance=$4 resolved
    resolved=$(realpath -e "$root/$path")
    [[ $resolved == "$root/"* && ! -L $root/$path && -f $resolved ]] || { echo "Unsafe OEM input: $path" >&2; exit 1; }
    [[ $(stat -c %s "$resolved") == "$bytes" && $(sha256sum "$resolved" | cut -d ' ' -f1) == "$expected" ]] || { echo "OEM input mismatch: $path" >&2; exit 1; }
    printf '%s\t%s\t%s\n' "$path" "$expected" "$provenance" >> "$work/files.tsv"
}
while IFS=$'\t' read -r destination path bytes sha; do
    case $destination in
      sensors) prefix=usr/share/uke-sensors;;
      firmware) prefix=usr/lib/firmware;;
      touch-inputs)
        check_file "usr/lib/firmware/qcom/uke/touch/$path" "$bytes" "$sha" verified-global-304-oem-source
        [[ $path == csot/* ]] || continue
        prefix=var/lib/uke-touch; path=${path#csot/};;
      *) exit 1;;
    esac
    check_file "$prefix/$path" "$bytes" "$sha" verified-global-304-oem-source
done < <(jq -r '.files[]|[.target_root,.target_path,.bytes,.sha256]|@tsv' "$oem")
while IFS=$'\t' read -r path bytes sha; do
    check_file "usr/lib/firmware/$path" "$bytes" "$sha" pinned-existing-local-firmware
done < <(jq -r '.files[]|[.target_path,.bytes,.sha256]|@tsv' "$firmware")
missing=()
while IFS= read -r name || [[ -n $name ]]; do
    [[ $name =~ ^[A-Za-z0-9_+-]+\.json$ ]]
    [[ -f $root/usr/share/uke-sensors/odm/$name ]] || missing+=("$name")
done < "$root/usr/share/uke-sensors/odm/json.lst"
actual=$(printf '%s\n' "${missing[@]}" | jq -Rsc 'split("\n")|map(select(length>0))|unique')
[[ $actual == "$(jq -c '.missing_sensor_configs|unique' "$oem")" ]]
touch_assets=$(jq '[.files[]|select(.target_root=="touch-inputs")]|length' "$oem")
expected=$(( $(jq '[.files[]|select(.target_root!="touch-inputs" or (.target_path|startswith("csot/")))]|length' "$oem") + $(jq '.files|length' "$firmware") + touch_assets ))
reference=$root/var/lib/uke-touch/reference.bin
[[ -f $reference && ! -L $reference && $(realpath -e "$reference") == "$root/"* && $(stat -c %a "$reference") == 600 ]]
grep -Fxq 'PARTLABEL=persist /mnt/vendor/persist ext4 ro,noload,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=10s 0 0' "$root/etc/fstab"
[[ -d $root/mnt/vendor/persist && ! -L $root/mnt/vendor/persist ]]
[[ -z $(find "$root/mnt/vendor/persist" -mindepth 1 -print -quit) ]]
jq -Rn --argjson missing "$actual" --argjson touch "$touch_assets" --argjson tm "$(jq '[.files[]|select(.target_root=="touch-inputs" and (.target_path|startswith("tm/")))]|length' "$oem")" '
  [inputs|split("\t")|{path:.[0],sha256:.[1],provenance:.[2]}] |
  {schema_version:1,scope:"offline private Uke root input verification",release:"OS3.0.304.0.WOZMIXM",
   installed_files_verified:length,active_inputs_verified:(length-$touch),packaged_touch_assets_verified:$touch,
   unselected_tm_files:$tm,missing_sensor_configs:$missing,
   private_touch_reference_present:true,device_operation_performed:false,hardware_tested:false,files:.}' \
    < "$work/files.tsv" > "$work/report.json"
[[ $(jq .installed_files_verified "$work/report.json") == "$expected" ]]
install -m600 "$work/report.json" "$output"
printf '%s OEM/pinned files verified; existing private touch reference retained, no device operation.\n' "$expected"
