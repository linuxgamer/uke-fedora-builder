#!/usr/bin/env bash
# Host-only admission of the owner's original Fedora KDE dependency exception.
set -Eeuo pipefail
[[ $# == 2 && -d $1 && ! -e $2 ]]
builder=$(cd "$(dirname "$0")/../.." && pwd)
transaction=$(realpath -- "$1")
out=$(realpath -m -- "$2")
plan=$transaction/transaction.json
plan_sha=$(sha256sum "$plan" | cut -d ' ' -f1)
jq -e '
  (.rpms | type=="array" and length>0 and length<=1024) and
  ([.rpms[].package_path] | length == (unique|length)) and
  all(.rpms[]; .action=="Install" and
    (.package_path|test("^\\./packages/[A-Za-z0-9+_.~^-]+\\.rpm$")) and
    (.repo_id=="@stored_transaction(rawhide)" or
     .repo_id=="@stored_transaction(fedora-cisco-openh264)" or
     .repo_id=="@stored_transaction(copr-uke-development)")) and
  ([.rpms[]|select(.reason=="User")|.nevra|capture("^(?<name>.+)-[0-9][^-]*-[^-]+\\.(aarch64|noarch)$").name]|sort)
    == ["konsole","kwin","plasma-desktop","plasma-workspace","sddm"]
' "$plan" >/dev/null
mkdir -p "$out/original" "$out/native" "$out/fedora-keydb" "$out/copr-keydb"
rpmkeys --dbpath "$out/fedora-keydb" --import "$builder/configs/keys/fedora-46.asc"
rpmkeys --dbpath "$out/copr-keydb" --import "$builder/configs/keys/uke-copr.asc"
while IFS=$'\t' read -r relative expected repo; do
  package=$transaction/$relative
  [[ -f $package && ! -L $package ]]
  [[ $(rpm -qp --qf '%{NEVRA}' "$package") == "$expected" ]]
  [[ $(rpm -qp --qf '%{ARCH}' "$package") =~ ^(aarch64|noarch)$ ]]
  destination=$out/original
  keydb=$out/fedora-keydb
  name=$(rpm -qp --qf '%{NAME}' "$package")
  if [[ $repo == '@stored_transaction(copr-uke-development)' ]]; then
    # Admit only the reviewed native support packages from the COPR transaction.
    case $name in atk|at-spi2-core|at-spi2-atk|libwacom|libwacom-data|libaccounts-glib) :;; *) exit 1;; esac
    destination=$out/native
    keydb=$out/copr-keydb
  elif [[ $repo == '@stored_transaction(fedora-cisco-openh264)' ]]; then
    [[ $name == openh264 ]]
  fi
  signature=$(rpmkeys --dbpath "$keydb" --checksig "$package") || { printf '%s\n' "$signature" >&2; exit 1; }
  grep -F 'signatures OK' <<< "$signature"
  (cd "$destination"; rpm2cpio "$package" | cpio -idm --quiet --no-absolute-filenames)
  jq -nc --arg file "$relative" --arg nevra "$expected" --arg repo "$repo" \
    --arg sha "$(sha256sum "$package" | cut -d ' ' -f1)" \
    '{file:$file,nevra:$nevra,repository:$repo,sha256:$sha}' >> "$out/packages.jsonl"
done < <(jq -r '.rpms[]|[.package_path,.nevra,.repo_id]|@tsv' "$plan")
[[ $(sha256sum "$plan" | cut -d ' ' -f1) == "$plan_sha" ]]
[[ $(wc -l < "$out/packages.jsonl") == "$(jq '.rpms|length' "$plan")" ]]
bash "$builder/src/audit/check-target-elf.sh" "$out/native"
jq -s --arg plan "$plan_sha" \
  '{purpose:"original-Fedora-KDE-dependency-closure",transaction_sha256:$plan,packages:.}' \
  "$out/packages.jsonl" > "$out/receipt.json"
echo 'Original Fedora KDE closure signatures and separate native-support payload passed'
