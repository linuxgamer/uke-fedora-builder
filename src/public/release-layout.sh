#!/usr/bin/env bash
# Image delivery metadata; this script never opens a device or edits image bytes.
set -Eeuo pipefail
export LC_ALL=C
release_fail() { printf 'image-release: %s\n' "$*" >&2; exit 1; }
release_manifest() {
    jq -e '
      .distribution=="fedora" and .architecture=="aarch64" and
      (.fedora_release | IN("rawhide","44","45")) and .release==.fedora_release and
      .image_built and .rpm_transaction_validated and .source_checked and
      .mode=="singleboot" and .partition=="userdata" and .filesystem=="ext4" and
      .device_private_data_included==false and .ssh_enabled==false and .automatic_kernel_activation==false and
      ((.desktop=="cutefish" and .credentials_included==true and .public_test_account=="senemos" and
        .account_setup=="gdm-expired-public-test-account" and .password_change_required==true and .password_change_backend_tested==true and
        .autologin_enabled==false and .remote_password_login==false and .passwordless_sudo==false) or
       (.desktop!="cutefish" and .credentials_included==false)) and
      .kernel_rpm_signature=="verified COPR signature" and .kernel_rpms_locally_built==false and
      .filesystem_contents_readback and .filesystem_metadata_readback and
      .selinux_policy_contexts_verified and .independent_aosp_decoder_verified and .sparse_roundtrip_verified and
      .cohort_validation.final_filesystem_hashes_verified and
      .cohort_validation.source=="matched-request-and-producer" and .cohort_validation.packages=="matched-producer-rpm-identities" and
      .cohort_validation.kernel_modules_config_dt=="matched-producer-payload-bytes" and
      .cohort_validation.boot_kernel=="extracted-and-matched" and .cohort_validation.root_selector=="matched-fstab" and
      ([.boot_sha256,.root_sparse_sha256,.payload_sha256] | all(.[]; type=="string" and test("^[0-9a-f]{64}$"))) and
      (.size_mib|type=="number" and .>0) and .root_raw_bytes==(.size_mib*1048576) and
      ([.kernel_commit,.kernel_source_commit] | all(.[]; type=="string" and test("^[0-9a-f]{40}$"))) and
      ([.image_built,.rpm_transaction_validated,.source_checked,.filesystem_contents_readback,.filesystem_metadata_readback,
        .selinux_policy_contexts_verified,.independent_aosp_decoder_verified,.sparse_roundtrip_verified,.cohort_validation.final_filesystem_hashes_verified] | all(.[]; .==true)) and
      ([.kernel_profile,.kernel_family,.kernel_version,.kernel_release,.rpm_dist,.rpm_version_release,
        .kernel_repository,.kernel_key_fingerprint] | all(.[]; type=="string" and length>0))
    ' "$1" >/dev/null || release_fail 'Incomplete or unsupported image manifest'
}
release_cohort() {
    release_manifest "$1"
    # Desktop, shell and builder revision may differ. The boot bytes are checked
    # independently; module/config/DT identity and root selection must agree.
    jq -S '{distribution,architecture,fedora_release,mode,partition,filesystem,size_mib,root_raw_bytes,
      kernel_profile,kernel_family,kernel_version,kernel_release,kernel_commit,kernel_source_commit,
      rpm_dist,rpm_version_release,kernel_repository,kernel_key_fingerprint,payload_sha256}' "$1"
}
release_names() {
    local manifest=$1 day=$2 revision=$3 desktop version iso
    release_manifest "$manifest"
    [[ $day =~ ^[0-9]{6}$ && $revision =~ ^(0|[1-9][0-9]{0,3})$ ]] || release_fail 'Invalid DDMMYY date or numeric revision'
    iso=20${day:4:2}-${day:2:2}-${day:0:2}
    [[ $(date -d "$iso" +%d%m%y) == "$day" ]] || release_fail 'Invalid calendar date'
    version=$(jq -er .fedora_release "$manifest")
    case $(jq -er .desktop "$manifest") in
        kde) desktop=kde-plasma;; gnome) desktop=gnome;; plasma-mobile) desktop=kde-plasma-mobile;;
        cutefish) desktop=cutefish;; nextkde) desktop=nextkde;; *) release_fail 'Unknown desktop name';;
    esac
    jq -n --arg version "$version" --arg desktop "$desktop" --arg date "$day" --arg revision "$revision" '
      {distribution:"fedora",version:$version,date:$date,revision:$revision,
       tag:("fedora-"+$version+"-uke-senemos-"+$date+"-r"+$revision),
       boot:("fedora-"+$version+"-uke-senemos-boot-"+$date+"-r"+$revision+".img"),
       system:("fedora-"+$version+"-"+$desktop+"-uke-senemos-system-"+$date+"-r"+$revision+".img.zst")}'
}
release_asset_name() {
    local layout=$1 name=$2 version day revision
    version=$(jq -er .version "$layout"); day=$(jq -er .date "$layout"); revision=$(jq -er .revision "$layout")
    [[ $name == "fedora-$version-uke-senemos-boot-$day-r$revision.img" ||
       $name =~ ^fedora-$version-(kde-plasma|gnome|kde-plasma-mobile|cutefish|nextkde)-uke-senemos-system-$day-r${revision}[.]img([.]zst)?$ ]]
}
release_verify() {
    local delivery=$1 file name manifest cohort boot sha expected count=0
    [[ -f $delivery/receipts/layout.json && -f $delivery/receipts/cohort.json ]] || release_fail 'Missing delivery receipts'
    boot=$(jq -er .boot "$delivery/receipts/layout.json")
    [[ -f $delivery/assets/$boot && ! -L $delivery/assets/$boot ]] || release_fail 'Missing shared boot image'
    shopt -s nullglob
    local entries=("$delivery/assets/"*) manifests=("$delivery/receipts/images/"*.json)
    ((${#manifests[@]} > 0 && ${#entries[@]} == ${#manifests[@]} + 1)) || release_fail 'Unexpected image or receipt count'
    for file in "${entries[@]}"; do
        name=${file##*/}
        [[ -f $file && ! -L $file ]] || release_fail "Unexpected release asset: $name"
        release_asset_name "$delivery/receipts/layout.json" "$name" || release_fail "Unexpected release asset: $name"
    done
    for manifest in "${manifests[@]}"; do
        [[ -f $manifest && ! -L $manifest ]] || release_fail 'Unsafe image receipt'
        release_manifest "$manifest"
        cohort=$(release_cohort "$manifest")
        [[ $cohort == "$(cat "$delivery/receipts/cohort.json")" ]] || release_fail 'Incompatible kernel/module/DT/root cohort'
        name=${manifest##*/}; name=${name%.json}
        local names
        names=$(release_names "$manifest" "$(jq -er .date "$delivery/receipts/layout.json")" "$(jq -er .revision "$delivery/receipts/layout.json")")
        [[ $name == "$(jq -er .system <<< "$names")" && $(jq -Sc 'del(.system)' <<< "$names") == "$(jq -Sc . "$delivery/receipts/layout.json")" ]] || release_fail 'Image names do not match their receipts'
        [[ -f $delivery/assets/$name && ! -L $delivery/assets/$name ]] || release_fail 'Root image receipt has no asset'
        expected=$(jq -er .boot_sha256 "$manifest")
        sha=$(sha256sum "$delivery/assets/$boot"); [[ ${sha%% *} == "$expected" ]] || release_fail 'Shared boot hash mismatch'
        if [[ $name == *.zst ]]; then sha=$(zstd -dc -- "$delivery/assets/$name" | sha256sum)
        else sha=$(sha256sum "$delivery/assets/$name"); fi
        [[ ${sha%% *} == "$(jq -er .root_sparse_sha256 "$manifest")" ]] || release_fail 'Root image hash mismatch'
        count=$((count + 1))
    done
    ((count > 0))
}
release_inventory() {
    local delivery=$1 file sha
    shopt -s nullglob
    for file in "$delivery/assets/"*; do
        sha=$(sha256sum "$file")
        printf '%s\t%s\t%s\n' "${file##*/}" "$(stat -c %s "$file")" "${sha%% *}"
    done | LC_ALL=C sort
}
release_desktop_set() {
    local delivery=$1 core=$2 policy=${3:-complete} manifest actual
    [[ $core =~ ^[0-9a-f]{64}$ ]] || release_fail 'Missing expected common core hash'
    release_verify "$delivery"
    local manifests=("$delivery/receipts/images/"*.json)
    case $policy in complete|cutefish-optional|gnome-plasma) ;; *) release_fail 'Unknown desktop publication policy';; esac
    actual=$(jq -sr 'map(.desktop)|sort|join(",")' "${manifests[@]}")
    if [[ $policy == gnome-plasma ]]; then
        [[ ${#manifests[@]} == 2 && $actual == gnome,kde ]] || release_fail 'Publication requires exactly GNOME and KDE Plasma'
    elif [[ $policy == cutefish-optional && $actual == gnome,kde,nextkde ]]; then
        [[ ${#manifests[@]} == 3 ]]
    else
        [[ ${#manifests[@]} == 4 && $actual == cutefish,gnome,kde,nextkde ]] || release_fail 'Publication requires KDE, GNOME and NextKDE; only Cutefish may be omitted explicitly'
    fi
    for manifest in "${manifests[@]}"; do
        jq -e --arg core "$core" '.shared_core_sha256==$core and .desktop_isolation_audited==true and
            .previous_desktop_image_input==false and .fedora_release=="rawhide" and .channel=="unstable" and .default_shell=="bash"' \
            "$manifest" >/dev/null || release_fail 'Desktop set has a different core, profile or unverified isolation'
        if [[ $policy == gnome-plasma ]]; then
            jq -e '.language_payload_verified==true and .translated_documentation_included==true and
                .serialized_language_payload_verified==true' "$manifest" >/dev/null ||
                release_fail 'Complete translated RPM and serialized-filesystem audits are required'
        fi
    done
}
release_stage() {
    local artifacts=$1 delivery=$2 day=$3 revision=$4 compressed=${5:-} names boot system cohort stage file
    release_manifest "$artifacts/manifest.json"
    for file in boot.img userdata.img; do
        [[ -f $artifacts/$file && ! -L $artifacts/$file ]] || release_fail "Missing regular input: $file"
    done
    [[ $(sha256sum "$artifacts/boot.img" | cut -d ' ' -f1) == "$(jq -er .boot_sha256 "$artifacts/manifest.json")" ]] || release_fail 'Input boot hash mismatch'
    [[ $(sha256sum "$artifacts/userdata.img" | cut -d ' ' -f1) == "$(jq -er .root_sparse_sha256 "$artifacts/manifest.json")" ]] || release_fail 'Input root hash mismatch'
    names=$(release_names "$artifacts/manifest.json" "$day" "$revision")
    boot=$(jq -er .boot <<< "$names"); system=$(jq -er .system <<< "$names")
    cohort=$(release_cohort "$artifacts/manifest.json")
    for file in "$delivery" "$delivery/assets" "$delivery/receipts" "$delivery/receipts/cohort.json" "$delivery/receipts/layout.json" "$delivery/assets/$boot" "$delivery/assets/$system"; do
        [[ ! -L $file ]] || release_fail 'Symlink in delivery layout'
    done
    mkdir -p "$delivery/assets" "$delivery/receipts/images" "$delivery/receipts/builds"
    if [[ -e $delivery/receipts/cohort.json ]]; then
        [[ $(cat "$delivery/receipts/cohort.json") == "$cohort" ]] || release_fail 'Use a separate revision for a different kernel cohort'
        [[ $(jq -Sc 'del(.system)' "$delivery/receipts/layout.json") == "$(jq -Sc 'del(.system)' <<< "$names")" ]] || release_fail 'Delivery name/revision mismatch'
    fi
    if [[ -e $delivery/assets/$boot ]]; then
        [[ ! -L $delivery/assets/$boot ]] || release_fail 'Symlink in shared boot path'
        cmp -s "$delivery/assets/$boot" "$artifacts/boot.img" || release_fail 'Desktop-independent boot name collision: boot bytes differ'
    fi
    if [[ -e $delivery/assets/$system ]]; then
        release_verify "$delivery"
        [[ $(jq -er .root_sparse_sha256 "$delivery/receipts/images/$system.json") == "$(jq -er .root_sparse_sha256 "$artifacts/manifest.json")" ]] || release_fail 'Root name collision: choose another revision'
        return
    fi
    stage=$(mktemp -d "$delivery/.stage.XXXXXXXX")
    if [[ -n $compressed ]]; then
        [[ -f $compressed && ! -L $compressed ]] || release_fail 'Compressed input is not a regular file'
        cp -- "$compressed" "$stage/$system"
    else
        zstd -T0 -10 --check --no-progress "$artifacts/userdata.img" -o "$stage/$system"
    fi
    [[ $(zstd -dc "$stage/$system" | sha256sum | cut -d ' ' -f1) == "$(jq -er .root_sparse_sha256 "$artifacts/manifest.json")" ]] || release_fail 'Compressed root mismatch'
    [[ -e $delivery/assets/$boot ]] || install -m644 "$artifacts/boot.img" "$delivery/assets/$boot"
    mv -- "$stage/$system" "$delivery/assets/$system"; rmdir "$stage"
    printf '%s\n' "$cohort" > "$delivery/receipts/cohort.json"
    jq 'del(.system)' <<< "$names" > "$delivery/receipts/layout.json"
    install -m644 "$artifacts/manifest.json" "$delivery/receipts/images/$system.json"
    local records=$delivery/receipts/builds/${system%.img.zst}
    mkdir -p "$records"
    for file in FLASHING.txt installed-rpms.tsv fedora-inputs.tsv desktop-inputs.tsv language-audit.json language-repair.json serialized-language-audit.json supported-locales.txt first-boot-policy.json fstab-generated-links.txt kio-admin-files.txt; do
        [[ ! -f $artifacts/$file ]] || install -m644 "$artifacts/$file" "$records/$file"
    done
    if [[ -d $artifacts/kernel ]]; then
        for file in packages.tsv RPM-SHA256SUMS kernel-info.json producer.json; do
            [[ ! -f $artifacts/kernel/$file ]] || install -m644 "$artifacts/kernel/$file" "$records/kernel-$file"
        done
    fi
    release_verify "$delivery"
    release_inventory "$delivery" > "$delivery/receipts/images.tsv"
}
release_title() {
    local delivery=$1 version day revision iso
    version=$(jq -er .version "$delivery/receipts/layout.json")
    day=$(jq -er .date "$delivery/receipts/layout.json")
    revision=$(jq -er .revision "$delivery/receipts/layout.json")
    [[ $version != rawhide ]] || version=Rawhide
    iso=20${day:4:2}-${day:2:2}-${day:0:2}
    date -d "$iso" +%F >/dev/null
    printf 'Fedora %s for Xiaomi Pad 7 and POCO Pad X1 - Senemos %s R%s (TESTING)' "$version" "$iso" "$revision"
}
# Markdown backticks are literal; printf supplies validated metadata fields.
# shellcheck disable=SC2016
release_body() {
    local delivery=$1 inventory=$2 file bytes sha boot revision day source example runs run manifest repo tag url desktops report boot_bytes
    repo=${GITHUB_REPOSITORY:-MCC45TR/uke-linux}
    [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || release_fail 'Invalid release repository'
    boot=$(jq -er .boot "$delivery/receipts/layout.json")
    tag=$(jq -er .tag "$delivery/receipts/layout.json")
    revision=$(jq -er .revision "$delivery/receipts/layout.json")
    day=$(jq -er .date "$delivery/receipts/layout.json")
    url=https://github.com/$repo/releases/download/$tag
    source=$(sha256sum "$delivery/receipts/cohort.json"); source=${source%% *}
    printf '# %s\n\n**Experimental Alpha · AArch64 · Linux `%s`**\n\n' "$(release_title "$delivery")" "$(jq -er .kernel_release "$delivery/receipts/cohort.json")"
    printf '<!-- uke-image-cohort-sha256: %s -->\n\n' "$source"
    runs=${UKE_RELEASE_BUILD_RUNS:-${GITHUB_RUN_ID:-}}
    if [[ -n $runs ]]; then
        [[ $runs =~ ^[0-9]+(,[0-9]+)*$ ]] || release_fail 'Invalid build record IDs'
        printf '<!-- uke-image-build-runs: %s -->\n\n' "$runs"
    fi
    desktops=$(jq -sr 'map(.desktop)|sort|join(",")' "$delivery/receipts/images/"*.json)
    if [[ $desktops == gnome,kde ]]; then
        printf 'Fedora Rawhide for Xiaomi Pad 7 and POCO Pad X1, with two independently composed desktop choices: **GNOME** and **KDE Plasma**. Both use the same verified core and byte-identical boot. NextKDE and Cutefish are suspended.\n\n'
    else printf 'Desktop choices in this verified delivery: `%s`. Install one root with its matching shared boot.\n\n' "$desktops"; fi
    printf '## Downloads\n\nChoose one desktop. Sizes are the actual compressed file sizes.\n\n| Desktop | Compressed image | Size (bytes) |\n| --- | --- | ---: |\n'
    while IFS=$'\t' read -r file bytes sha; do
        [[ $file != "$boot" ]] || continue
        case $file in *-kde-plasma-*) example='KDE Plasma';; *-gnome-*) example=GNOME;; *) example=Desktop;; esac
        printf '| %s | [%s](%s/%s) | %s |\n' "$example" "$file" "$url" "$file" "$bytes"
    done < "$inventory"
    boot_bytes=$(awk -F '\t' -v name="$boot" '$1==name {print $2}' "$inventory")
    printf '\n**Shared boot:** [%s](%s/%s) — %s bytes. Use it only with a root from this verified cohort.\n\n## SHA256\n\n| Image | Bytes | SHA256 |\n| --- | ---: | --- |\n' "$boot" "$url" "$boot" "$boot_bytes"
    while IFS=$'\t' read -r file bytes sha; do printf '| `%s` | %s | `%s` |\n' "$file" "$bytes" "$sha"; done < "$inventory"
    printf '\nCompare `sha256sum FILE` with the table before extraction or installation.\n\n## Advanced installation\n\n**Flashing userdata erases its existing Android or Linux system, apps, files and encryption metadata. Back up needed data first.** Keep your own matching backups and a working recovery route; changing slots does not restore userdata.\n\n'
    printf 'Read the [installation and recovery documentation](https://github.com/%s/blob/Fedora/README.md). Confirm the documented Uke product/variant, compatible stock **slot-B firmware**, and the intended boot target. Do not copy firmware or partition layouts from another device.\n\n' "$repo"
    printf 'In fastboot mode, inspect these values and stop if they do not match the documented device and installation plan:\n\n```sh\nfastboot getvar product\nfastboot getvar current-slot\nfastboot getvar partition-size:userdata\nfastboot getvar partition-size:boot_b\n```\n\n'
    printf 'Required userdata capacity: **%s bytes** or more; boot_b: **%s bytes** or more. Verify product `uke` against the documented Xiaomi/POCO variant mapping and compatible B firmware before writes.\n\n' "$(jq -er .root_raw_bytes "$delivery/receipts/cohort.json")" "$boot_bytes"
    example=$(awk -F '\t' '$1 ~ /-system-.*\.img\.zst$/ {print $1;exit}' "$inventory")
    [[ -n $example ]] || release_fail 'No system image in checksum inventory'
    printf 'After all checks, choose one desktop root. This example uses `%s`; extraction and each write must succeed before slot selection and reboot:\n\n```sh\n' "$example"
    printf 'zstd -d --keep %s -o system.img && \\\nfastboot flash userdata system.img && \\\nfastboot flash boot_b %s && \\\nfastboot set_active b && \\\nfastboot reboot\n```\n\n' "$example" "$boot"
    printf 'Do not run `fastboot -w` or format userdata afterwards. Preserve stock early firmware and calibration partitions. The builder performs no tablet writes.\n\nEXT4 initially occupies the image capacity. Original systemd-growfs expands it to the measured userdata capacity before setup; the independent capacity gate remains enforced. Disk swap uses half physical RAM, or a valid unique linux_swap partition. Fastboot itself does not resize EXT4. KDE uses Plasma Setup; GNOME uses GNOME Initial Setup. These two images contain no preset human account; SSH is disabled.\n\n## After installation\n\n```sh\nsudo dnf update --refresh\n```\n\nUse the configured signed Fedora/COPR repositories. Kernel updates must retain matched Uke kernel, modules, DT and boot packages. Do not mix a generic Fedora kernel or an unrelated boot image with these roots. Automatic kernel activation is disabled; follow the documented guarded updater procedure rather than assuming a package update has safely activated new boot bytes.\n\n## Testing status\n\nAutomated checks cover signatures, matching kernel/module/DT/boot payloads, complete RPM translations including Turkish/help/Qt catalogs, EXT4 contents, ownership and SELinux metadata. These checks do not certify device runtime, first-account setup, full-capacity growth, swap, input, graphics, firmware compatibility or rollback.\n\n'
    report=$(dirname -- "${BASH_SOURCE[0]}")/../../docs/release-testing/$day-r$revision.md
    if [[ -f $report && ! -L $report ]]; then cat "$report"; printf '\n'
    else printf 'No release-specific physical test report is recorded here. Report the device variant, desktop, exact hashes and logs; do not infer hardware acceptance from build success.\n\n'; fi
    if grep -q -- '-cutefish-uke-senemos-system-' "$inventory"; then
        printf '**Historical Cutefish image only:** public test account `senemos`, initial password `fedora`; GDM requires a password change. Automatic login, remote password login and passwordless sudo are disabled.\n\n'
    elif [[ ${UKE_ALLOW_MISSING_CUTEFISH:-0} == 1 ]]; then printf '**Cutefish is currently unavailable.** Its separate validation must pass before a compatible image is added.\n\n'; fi
    printf '## Build evidence and support\n\nKernel source: `%s`; signer: `%s`; COPR RPM version-release: `%s%s`.\n\n' "$(jq -er .kernel_source_commit "$delivery/receipts/cohort.json")" "$(jq -er .kernel_key_fingerprint "$delivery/receipts/cohort.json")" "$(jq -er .rpm_version_release "$delivery/receipts/cohort.json")" "$(jq -er .rpm_dist "$delivery/receipts/cohort.json")"
    for manifest in "$delivery/receipts/images/"*.json; do
        if jq -e '.shared_core_producer_run_id and .shared_core_producer_workspace_commit' "$manifest" >/dev/null; then
            printf 'Original core workspace `%s`, builder `%s`, archive SHA256 `%s`. Consumer revisions and exact inventories remain in Actions receipts; publication does not rebuild or upgrade the images.\n\n' "$(jq -er .shared_core_producer_workspace_commit "$manifest")" "$(jq -er .shared_core_producer_builder_commit "$manifest")" "$(jq -er .shared_core_sha256 "$manifest")"
            break
        fi
    done
    if [[ -n $runs ]]; then
        local -a run_ids=()
        IFS=, read -r -a run_ids <<< "$runs"
        for run in "${run_ids[@]}"; do printf '[Actions build/artifact evidence %s](https://github.com/%s/actions/runs/%s)\n\n' "$run" "$repo" "$run"; done
    fi
    printf '[README](https://github.com/%s/blob/Fedora/README.md) · [Report or follow issues](https://github.com/%s/issues)\n\nOnly image files are release assets. Manifests, inventories and diagnostics remain in Actions artifacts.\n' "$repo" "$repo"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    command=${1:-}; shift || :
    case $command in
        names) release_names "$@";; stage) release_stage "$@";; verify) release_verify "$@";;
        inventory) release_inventory "$@";; body) release_body "$@";; cohort) release_cohort "$@";; desktop-set) release_desktop_set "$@";;
        *) release_fail 'Expected names, stage, verify, inventory, body or cohort';;
    esac
fi
