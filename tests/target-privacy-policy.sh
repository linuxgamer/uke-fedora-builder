#!/usr/bin/env bash
# Host-only fixtures for explicit, immutable SELinux namespace exceptions.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/payload/etc/selinux/targeted/contexts/files" "$fixture/payload/usr/share/records"
audit=$root/src/audit/check-target-privacy.sh
policy=$fixture/policy.json
file=$fixture/payload/etc/selinux/targeted/contexts/files/file_contexts
reject() { if bash "$audit" "$@" > "$fixture/rejected.log" 2>&1; then echo 'Privacy fixture unexpectedly accepted' >&2; exit 1; fi; }
printf '/%s/(unconfined_u|system_u)/.+ system_u:object_r:user_home_t:s0\n' home > "$file"
sha=$(sha256sum "$file" | cut -d ' ' -f1)
jq -n --arg sha "$sha" '{schema_version:1,files:[{path:"etc/selinux/targeted/contexts/files/file_contexts",sha256:$sha}]}' > "$policy"
reject "$fixture/payload"
bash "$audit" --namespace-policy "$policy" "$fixture/payload" >/dev/null
cp "$file" "$fixture/payload/usr/share/records/unapproved"
reject --namespace-policy "$policy" "$fixture/payload"
rm "$fixture/payload/usr/share/records/unapproved"
printf 'Altered policy\n' >> "$file"
reject --namespace-policy "$policy" "$fixture/payload"
sed -i '$d' "$file"
reject_env=$(printf '/%s/(unconfined_u|system_u)' home)
if SENEMOS_PRIVATE_HOST_HOME=$reject_env bash "$audit" --namespace-policy "$policy" "$fixture/payload" >/dev/null 2>&1; then exit 1; fi
rm "$file"
printf 'Relative source filename: src/%s/fixture/include.hpp\n' home > "$fixture/payload/usr/share/records/relative"
bash "$audit" "$fixture/payload" >/dev/null
printf 'fixture:x:1000:1000::/%s/fixture:/usr/bin/bash\n' home > "$fixture/payload/etc/passwd"
bash "$audit" "$fixture/payload" >/dev/null
printf 'Absolute build filename: /%s/fixture/source.cpp\n' home >> "$fixture/payload/etc/passwd"
reject "$fixture/payload"
rm "$fixture/payload/etc/passwd"
printf 'Absolute build filename: \0/%s/fixture/include.hpp\0\n' home > "$fixture/payload/usr/share/records/absolute"
reject "$fixture/payload"
rm "$fixture/payload/usr/share/records/absolute"
printf 'Public upstream example: /home/example/project\n' > "$fixture/payload/usr/share/records/public"
bash "$audit" --private-home /home/stast "$fixture/payload" >/dev/null
printf 'Private build path: /home/stast/project\n' > "$fixture/payload/usr/share/records/private"
reject --private-home /home/stast "$fixture/payload"
printf '%s\n' 'Privacy fixtures passed; immutable namespace exceptions do not admit modified files, foreign paths or host identity'
