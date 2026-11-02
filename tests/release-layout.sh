#!/usr/bin/env bash
# Tiny byte fixtures and a fake GitHub CLI; no image build or publication.
set -Eeuo pipefail
builder=$(cd -- "$(dirname -- "$0")/.." && pwd)
tool=$builder/src/public/release-layout.sh
publisher=$builder/scripts/publish-image-release.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/kde/kernel" "$work/bin"
printf 'identical boot fixture\n' > "$work/kde/boot.img"
printf 'KDE root fixture\n' > "$work/kde/userdata.img"
boot_sha=$(sha256sum "$work/kde/boot.img" | cut -d ' ' -f1)
root_sha=$(sha256sum "$work/kde/userdata.img" | cut -d ' ' -f1)
jq -n --arg boot "$boot_sha" --arg root "$root_sha" '{distribution:"fedora",architecture:"aarch64",fedora_release:"rawhide",release:"rawhide",
 image_built:true,rpm_transaction_validated:true,source_checked:true,mode:"singleboot",partition:"userdata",filesystem:"ext4",desktop:"kde",
 language_payload_verified:true,translated_documentation_included:true,serialized_language_payload_verified:true,
 size_mib:8192,root_raw_bytes:8589934592,device_private_data_included:false,credentials_included:false,ssh_enabled:false,automatic_kernel_activation:false,
 kernel_rpm_signature:"verified COPR signature",kernel_rpms_locally_built:false,filesystem_contents_readback:true,filesystem_metadata_readback:true,
 selinux_policy_contexts_verified:true,independent_aosp_decoder_verified:true,sparse_roundtrip_verified:true,
 cohort_validation:{source:"matched-request-and-producer",packages:"matched-producer-rpm-identities",final_filesystem_hashes_verified:true,kernel_modules_config_dt:"matched-producer-payload-bytes",boot_kernel:"extracted-and-matched",root_selector:"matched-fstab"},
 kernel_profile:"normal",kernel_family:"senemos-uke-linux-kernel-mainline",kernel_version:"7.3.1",kernel_release:"7.3.1-115",
 kernel_commit:("a"*40),kernel_source_commit:("a"*40),rpm_dist:".fc46",rpm_version_release:"7.3.1-115",
 kernel_repository:"mcc45tr/uke-linux-unstable",kernel_key_fingerprint:("B"*40),payload_sha256:("c"*64),boot_sha256:$boot,root_sparse_sha256:$root}' > "$work/kde/manifest.json"
for file in FLASHING.txt installed-rpms.tsv kernel/packages.tsv kernel/RPM-SHA256SUMS; do printf 'fixture receipt\n' > "$work/kde/$file"; done
cp -a "$work/kde" "$work/gnome"
printf 'GNOME root fixture\n' > "$work/gnome/userdata.img"
jq --arg sha "$(sha256sum "$work/gnome/userdata.img" | cut -d ' ' -f1)" '.desktop="gnome"|.root_sparse_sha256=$sha' "$work/kde/manifest.json" > "$work/gnome/manifest.json"
reject() { if "$@" > "$work/rejected" 2>&1; then echo "Invalid release accepted: $*" >&2; exit 1; fi; }
names=$(bash "$tool" names "$work/kde/manifest.json" 011126 0)
[[ $(jq -r .boot <<< "$names") == fedora-rawhide-uke-senemos-boot-011126-r0.img ]]
[[ $(jq -r .system <<< "$names") == fedora-rawhide-kde-plasma-uke-senemos-system-011126-r0.img.zst ]]
reject bash "$tool" names "$work/kde/manifest.json" 311126 0
reject bash "$tool" names "$work/kde/manifest.json" 011126 r0
reject bash "$tool" names "$work/kde/manifest.json" 011126 00
reject bash "$tool" names "$work/kde/manifest.json" 011126 '0;touch bad'
cp -a "$work/kde" "$work/cutefish"
jq '.desktop="cutefish"|.credentials_included=true|.public_test_account="senemos"|
    .account_setup="gdm-expired-public-test-account"|.password_change_required=true|.password_change_backend_tested=true|
    .autologin_enabled=false|.remote_password_login=false|.passwordless_sudo=false' \
    "$work/kde/manifest.json" > "$work/cutefish/manifest.json"
bash "$tool" names "$work/cutefish/manifest.json" 011126 1 > /dev/null
for key in password_change_required password_change_backend_tested autologin_enabled remote_password_login passwordless_sudo; do
    jq --arg key "$key" '.[$key]=(.[$key]|not)' "$work/cutefish/manifest.json" > "$work/invalid-account.json"
    reject bash "$tool" names "$work/invalid-account.json" 011126 1
done
jq '.credentials_included=true' "$work/kde/manifest.json" > "$work/invalid-account.json"
reject bash "$tool" names "$work/invalid-account.json" 011126 1
bash "$tool" stage "$work/kde" "$work/delivery" 011126 0
bash "$tool" stage "$work/gnome" "$work/delivery" 011126 0
bash "$tool" stage "$work/kde" "$work/delivery" 011126 0
[[ $(find "$work/delivery/assets" -type f | wc -l) == 3 ]]
[[ $(find "$work/delivery/assets" -name '*-boot-*' | wc -l) == 1 ]]
bash "$tool" verify "$work/delivery"
cp -a "$work/gnome" "$work/different-boot"
printf 'different boot fixture\n' > "$work/different-boot/boot.img"
jq --arg sha "$(sha256sum "$work/different-boot/boot.img" | cut -d ' ' -f1)" '.boot_sha256=$sha' "$work/gnome/manifest.json" > "$work/different-boot/manifest.json"
reject bash "$tool" stage "$work/different-boot" "$work/delivery" 011126 0
grep -F 'boot bytes differ' "$work/rejected" >/dev/null
cp -a "$work/gnome" "$work/different-cohort"
jq '.payload_sha256=("d"*64)' "$work/gnome/manifest.json" > "$work/different-cohort/manifest.json"
reject bash "$tool" stage "$work/different-cohort" "$work/delivery" 011126 0
grep -F 'different kernel cohort' "$work/rejected" >/dev/null
printf 'not an image\n' > "$work/delivery/assets/manifest.json"
reject bash "$tool" verify "$work/delivery"
rm "$work/delivery/assets/manifest.json"
cp "$work/kde/manifest.json" "$work/valid.json"
jq '.image_built="true"' "$work/valid.json" > "$work/kde/manifest.json"
reject bash "$tool" names "$work/kde/manifest.json" 011126 0
cp "$work/valid.json" "$work/kde/manifest.json"
mkdir -p "$work/unsafe/assets"
ln -s "$work/not-created" "$work/unsafe/assets/fedora-rawhide-uke-senemos-boot-011126-r0.img"
reject bash "$tool" stage "$work/kde" "$work/unsafe" 011126 0
[[ ! -e $work/not-created ]]
# Four independent roots must converge before the one publisher is allowed.
core_sha=$(printf 'f%.0s' {1..64})
for desktop in kde gnome cutefish nextkde; do
    cp -a "$work/kde" "$work/set-$desktop"
    printf '%s independent root\n' "$desktop" > "$work/set-$desktop/userdata.img"
    jq --arg desktop "$desktop" --arg core "$core_sha" --arg sha "$(sha256sum "$work/set-$desktop/userdata.img" | cut -d ' ' -f1)" \
        '.desktop=$desktop|.shared_core_sha256=$core|.desktop_isolation_audited=true|.previous_desktop_image_input=false|
         .channel="unstable"|.default_shell="bash"|.builder_commit=("b"*40)|.root_sparse_sha256=$sha|
         if $desktop=="cutefish" then .credentials_included=true|.public_test_account="senemos"|
           .account_setup="gdm-expired-public-test-account"|.password_change_required=true|.password_change_backend_tested=true|
           .autologin_enabled=false|.remote_password_login=false|.passwordless_sudo=false else . end' \
        "$work/kde/manifest.json" > "$work/set-$desktop/manifest.json"
    bash "$tool" stage "$work/set-$desktop" "$work/set-delivery-$desktop" 011126 1
    printf 'workspace %s\n' "$(printf 'a%.0s' {1..40})" > "$work/set-delivery-$desktop/receipts/SOURCE.txt"
done
merge=$builder/scripts/merge-desktop-deliveries.sh
bash "$merge" "$work/complete-set" "$core_sha" "$work/set-delivery-"{kde,gnome,cutefish,nextkde}
[[ $(find "$work/complete-set/assets" -type f | wc -l) == 5 ]]
env UKE_DESKTOP_SET_POLICY=gnome-plasma bash "$merge" "$work/two-desktops" "$core_sha" "$work/set-delivery-"{kde,gnome}
[[ $(find "$work/two-desktops/assets" -type f | wc -l) == 3 ]]
# The current template derives names/date/kernel from this delivery and retains
# partial user testing and an unresolved device report without a blanket claim.
bash "$tool" stage "$work/set-kde" "$work/r4-template" 021126 4
bash "$tool" stage "$work/set-gnome" "$work/r4-template" 021126 4
env GITHUB_REPOSITORY=MCC45TR/uke-linux UKE_RELEASE_BUILD_RUNS=41430801872 bash "$tool" body "$work/r4-template" "$work/r4-template/receipts/images.tsv" > "$work/r4-template.md"
grep -Fq 'Senemos 2026-11-02 R4 (TESTING)' "$work/r4-template.md"
grep -Fq 'two independently composed desktop choices: **GNOME** and **KDE Plasma**' "$work/r4-template.md"
grep -Fq "Linux \`7.3.1-115\`" "$work/r4-template.md"
grep -Fq 'releases/download/fedora-rawhide-uke-senemos-021126-r4/fedora-rawhide-gnome-uke-senemos-system-021126-r4.img.zst' "$work/r4-template.md"
grep -Fq 'stopping at the Mi logo and returning to recovery' "$work/r4-template.md"
grep -Fq 'positive user report, not complete hardware qualification' "$work/r4-template.md"
grep -Fq 'unpublished Qt/Kirigami application work is not included' "$work/r4-template.md"
reject env UKE_DESKTOP_SET_POLICY=gnome-plasma bash "$merge" "$work/wrong-two-desktops" "$core_sha" "$work/set-delivery-"{kde,nextkde}
reject bash "$merge" "$work/incomplete-set" "$core_sha" "$work/set-delivery-"{kde,gnome,cutefish}
reject bash "$merge" "$work/duplicate-set" "$core_sha" "$work/set-delivery-"{kde,gnome,cutefish,kde}
reject bash "$tool" desktop-set "$work/complete-set" "$(printf 'e%.0s' {1..64})"
env UKE_ALLOW_MISSING_CUTEFISH=1 bash "$merge" "$work/without-cutefish" "$core_sha" "$work/set-delivery-"{kde,gnome,nextkde}
[[ $(find "$work/without-cutefish/assets" -type f | wc -l) == 4 ]]
UKE_ALLOW_MISSING_CUTEFISH=1 reject bash "$merge" "$work/without-nextkde" "$core_sha" "$work/set-delivery-"{kde,gnome,cutefish}
cp -a "$work/set-gnome" "$work/set-conflicting-cohort"
jq '.payload_sha256=("e"*64)' "$work/set-gnome/manifest.json" > "$work/set-conflicting-cohort/manifest.json"
bash "$tool" stage "$work/set-conflicting-cohort" "$work/conflicting-cohort-delivery" 011126 1
reject bash "$merge" "$work/conflicting-complete-set" "$core_sha" "$work/set-delivery-kde" "$work/conflicting-cohort-delivery" "$work/set-delivery-cutefish" "$work/set-delivery-nextkde"
# Preserve a validated delivery from a completed/cancelled series without rebuilding.
mkdir -p "$work/reuse-bin" "$work/reuse-state"
reuse_state=$work/reuse-state
(cd "$work/set-delivery-kde"; zip -q -r "$reuse_state/delivery.zip" .)
jq -n '{repository:{full_name:"MCC45TR/fixture"},event:"workflow_dispatch",head_branch:"Fedora",
    path:".github/workflows/desktop-images.yml",status:"completed",head_sha:("a"*40)}' > "$reuse_state/run.json"
printf '[{"jobs":[{"name":"kde / compose","conclusion":"success"}]}]\n' > "$reuse_state/jobs.json"
jq -n '{tree:[{path:"uke-fedora-builder",mode:"160000",sha:("b"*40)}]}' > "$reuse_state/tree.json"
jq -n --arg sha "sha256:$(sha256sum "$reuse_state/delivery.zip" | cut -d ' ' -f1)" \
    '[{artifacts:[{id:456,name:"desktop-delivery-kde",expired:false,digest:$sha}]}]' > "$reuse_state/artifacts.json"
cat > "$work/reuse-bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
[[ $1 == api ]]
case $2 in
 */actions/runs/123) cat "$UKE_REUSE_STATE/run.json";;
 */actions/runs/123/jobs*) cat "$UKE_REUSE_STATE/jobs.json";;
 */git/trees/*) cat "$UKE_REUSE_STATE/tree.json";;
 */actions/runs/123/artifacts*) cat "$UKE_REUSE_STATE/artifacts.json";;
 */actions/artifacts/456/zip) cat "$UKE_REUSE_STATE/delivery.zip";;
 *) exit 99;;
esac
SH
chmod +x "$work/reuse-bin/gh"
reuse_request() {
    env PATH="$work/reuse-bin:$PATH" UKE_REUSE_STATE="$reuse_state" GITHUB_REPOSITORY=MCC45TR/fixture GITHUB_OUTPUT="$work/reuse-outputs" \
        RUNNER_TEMP="$1" REUSE_DESKTOP_RUN_ID=123 IMAGE_DESKTOP=kde IMAGE_CORE_SHA="$2" IMAGE_BUILD_DATE=011126 IMAGE_REVISION=1 \
        bash "$builder/scripts/reuse-validated-desktop.sh"
}
reuse_request "$work/reuse-positive" "$core_sha"
cmp "$work/set-delivery-kde/assets/$(jq -er .boot "$work/set-delivery-kde/receipts/layout.json")" \
    "$work/reuse-positive/verified-desktop-reuse/delivery/assets/$(jq -er .boot "$work/set-delivery-kde/receipts/layout.json")"
reject reuse_request "$work/reuse-wrong-core" "$(printf 'e%.0s' {1..64})"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
state=$UKE_GH_STATE
mkdir -p "$state/assets"
printf '%s\n' "$*" >> "$state/calls"
option() { local key=$1; shift; while (($#)); do if [[ $1 == "$key" ]]; then printf '%s\n' "$2"; return; fi; shift; done; return 1; }
if [[ $1 == api ]]; then
 if [[ $2 == */releases && $(option --method "$@" || :) == POST ]]; then
  input=$(option --input "$@")
  jq '. + {id:430000001,assets:[]}' "$input" > "$state/release.json"
  cat "$state/release.json"
 elif [[ $2 == https://uploads.github.com/*/assets\?name=* ]]; then
  [[ ${UKE_FAIL_UPLOAD:-0} == 0 ]] || exit 45
  file=$(option --input "$@"); name=${2#*name=}
  cp "$file" "$state/assets/$name"
  sha=$(sha256sum "$file"); sha=${sha%% *}
  jq --arg name "$name" --arg sha "sha256:$sha" --argjson size "$(stat -c %s "$file")" '.assets += [{name:$name,digest:$sha,size:$size,state:"uploaded"}]' "$state/release.json" > "$state/new.json"
  mv "$state/new.json" "$state/release.json"
  jq --arg name "$name" '.assets[]|select(.name==$name)' "$state/release.json"
 elif [[ $2 == */releases/430000001 && $(option --method "$@" || :) == PATCH ]]; then
  input=$(option --input "$@")
  jq --slurpfile update "$input" '. + $update[0] + {published_at:"2026-11-01T00:00:00Z",html_url:"https://example.invalid/release"}' "$state/release.json" > "$state/new.json"
  mv "$state/new.json" "$state/release.json"; cat "$state/release.json"
 elif [[ $2 == *'/releases?per_page=100' ]]; then
  if [[ ${UKE_HIDE_DRAFT_LIST:-0} == 1 && -f $state/release.json ]] && jq -e .draft "$state/release.json" >/dev/null; then printf '[]\n'; exit; fi
  if [[ -f $state/release.json ]]; then jq '[[.]]' "$state/release.json"; else printf '[]\n'; fi
 elif [[ $2 == *'/releases/tags/'* ]]; then
  if [[ -f $state/release.json ]] && jq -e '.draft==false' "$state/release.json" >/dev/null; then cat "$state/release.json"
  else printf '{"status":"404"}\n'; exit 1; fi
 elif [[ -f $state/release.json ]]; then cat "$state/release.json"
 else exit 99; fi
elif [[ $1 == release && $2 == create ]]; then
 notes=$(option --notes-file "$@")
 jq -n --rawfile body "$notes" --arg tag "$3" '{id:430000001,tag_name:$tag,body:$body,assets:[],draft:true}' > "$state/release.json"
elif [[ $1 == release && $2 == upload ]]; then
 shift 3
 while (($#)) && [[ $1 != --* ]]; do
  file=$1 name=${1##*/}; cp "$file" "$state/assets/$name"
  sha=$(sha256sum "$file"); sha=${sha%% *}
  jq --arg name "$name" --arg sha "sha256:$sha" --argjson size "$(stat -c %s "$file")" '.assets += [{name:$name,digest:$sha,size:$size,state:"uploaded"}]' "$state/release.json" > "$state/new.json"
  mv "$state/new.json" "$state/release.json"; shift
 done
elif [[ $1 == release && $2 == download ]]; then
 name=$(option --pattern "$@"); directory=$(option --dir "$@")
 cp "$state/assets/$name" "$directory/$name"
elif [[ $1 == release && $2 == edit ]]; then
 notes=$(option --notes-file "$@")
 jq --rawfile body "$notes" '.body=$body|.draft=false' "$state/release.json" > "$state/new.json"
 mv "$state/new.json" "$state/release.json"
elif [[ $1 == release && $2 == view ]]; then printf 'https://example.invalid/release\n'
else exit 99; fi
SH
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GITHUB_REPOSITORY=MCC45TR/fixture SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_RUN_ID=123 UKE_GH_STATE=$work/remote
env UKE_GH_STATE="$work/remote-two-desktops" UKE_REQUIRE_DESKTOP_SET=1 UKE_DESKTOP_SET_POLICY=gnome-plasma UKE_EXPECTED_CORE_SHA="$core_sha" bash "$publisher" "$work/two-desktops"
jq -e '.prerelease and (.assets|length==3)' "$work/remote-two-desktops/release.json" >/dev/null
bash "$tool" stage "$work/kde" "$work/kde-only" 011126 0
UKE_REQUIRE_DESKTOP_SET=1 UKE_EXPECTED_CORE_SHA=$core_sha reject bash "$publisher" "$work/kde-only"
[[ ! -e $UKE_GH_STATE/calls ]]
UKE_HIDE_DRAFT_LIST=1 bash "$publisher" "$work/kde-only"
jq -e '.draft==false and (.assets|length==2) and all(.assets[]; .name|test("[.]img([.]zst)?$")) and (.body|contains("| Image | Bytes | SHA256 |"))' "$work/remote/release.json" >/dev/null
jq -e '.name=="Fedora Rawhide for Xiaomi Pad 7 and POCO Pad X1 - Senemos 2026-11-01 R0 (TESTING)"' "$work/remote/release.json" >/dev/null
jq -e '(.body|contains("fastboot set_active b &&")) and (.body|contains("fastboot reboot")) and (.body|contains("fastboot flash boot_b")) and (.body|contains("sudo dnf update --refresh")) and (.body|contains("Experimental Alpha"))' "$work/remote/release.json" >/dev/null
bash "$tool" stage "$work/gnome" "$work/gnome-only" 011126 0
export GITHUB_RUN_ID=456
jq '.draft=true' "$work/remote/release.json" > "$work/draft.json"
mv "$work/draft.json" "$work/remote/release.json"
UKE_HIDE_DRAFT_LIST=1 UKE_RELEASE_ID=430000001 bash "$publisher" "$work/gnome-only"
jq -e '(.assets|length==3) and ([.assets[]|select(.name|contains("-boot-"))]|length==1)' "$work/remote/release.json" >/dev/null
jq -e '.body|contains("<!-- uke-image-build-runs: 123,456 -->")' "$work/remote/release.json" >/dev/null
grep -F 'release download' "$work/remote/calls" >/dev/null
cp "$work/remote/release.json" "$work/remote.good"
printf 'corrupt published boot\n' > "$work/remote/assets/fedora-rawhide-uke-senemos-boot-011126-r0.img"
reject bash "$publisher" "$work/gnome-only"
grep -F 'Published shared boot bytes differ' "$work/rejected" >/dev/null
cp "$work/kde/boot.img" "$work/remote/assets/fedora-rawhide-uke-senemos-boot-011126-r0.img"
jq '.body="unrecorded cohort"' "$work/remote.good" > "$work/remote/release.json"
reject bash "$publisher" "$work/gnome-only"
cp "$work/remote.good" "$work/remote/release.json"
cp -a "$work/gnome" "$work/root-collision"
printf 'changed GNOME fixture\n' > "$work/root-collision/userdata.img"
jq --arg sha "$(sha256sum "$work/root-collision/userdata.img" | cut -d ' ' -f1)" '.root_sparse_sha256=$sha' "$work/gnome/manifest.json" > "$work/root-collision/manifest.json"
bash "$tool" stage "$work/root-collision" "$work/collision-delivery" 011126 0
reject bash "$publisher" "$work/collision-delivery"
grep -F 'Published image collision' "$work/rejected" >/dev/null
jq '.assets += [{name:"manifest.json",state:"uploaded",digest:("sha256:"+("e"*64)),size:10}]' "$work/remote.good" > "$work/remote/release.json"
before=$(wc -l < "$work/remote/calls")
reject bash "$publisher" "$work/gnome-only"
[[ $(wc -l < "$work/remote/calls") == $((before + 1)) ]]
env UKE_GH_STATE="$work/remote-complete-set" UKE_REQUIRE_DESKTOP_SET=1 UKE_EXPECTED_CORE_SHA="$core_sha" bash "$publisher" "$work/complete-set"
jq -e '.draft==false and (.assets|length==5) and ([.assets[]|select(.name|contains("-boot-"))]|length==1)' "$work/remote-complete-set/release.json" >/dev/null
env UKE_GH_STATE="$work/remote-optional-cutefish" UKE_REQUIRE_DESKTOP_SET=1 UKE_ALLOW_MISSING_CUTEFISH=1 UKE_EXPECTED_CORE_SHA="$core_sha" bash "$publisher" "$work/without-cutefish"
jq -e '.draft==false and (.assets|length==4) and (.body|contains("Cutefish is currently unavailable"))' "$work/remote-optional-cutefish/release.json" >/dev/null
env UKE_GH_STATE="$work/remote-optional-cutefish" UKE_REQUIRE_DESKTOP_SET=1 UKE_ALLOW_MISSING_CUTEFISH=1 UKE_EXPECTED_CORE_SHA="$core_sha" bash "$publisher" "$work/complete-set"
jq -e '(.assets|length==5) and (.body|contains("Cutefish is currently unavailable")|not)' "$work/remote-optional-cutefish/release.json" >/dev/null
# The positional parameters are expanded by the child shell running the pipe.
# shellcheck disable=SC2016
if env UKE_GH_STATE="$work/remote-upload-failure" UKE_FAIL_UPLOAD=1 bash -e -o pipefail -c \
    'bash "$1" "$2" | tee "$3"' fixture "$publisher" "$work/kde-only" "$work/failure-summary" > "$work/failure-output" 2>&1; then
    echo 'A failed upload was hidden by tee' >&2; exit 1
fi
[[ $(jq '.assets|length' "$work/remote-upload-failure/release.json") == 0 ]]
echo 'Image names, shared boot byte/cohort gates, collisions, image-only publication and legacy-release preservation passed; no GitHub writes ran'
