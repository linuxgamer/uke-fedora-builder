#!/usr/bin/env bash
# Host-only byte-admission fixtures; no Python is executed.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/original/usr/bin" "$fixture/payload/usr/bin" "$fixture/outside"
audit=$root/src/audit/check-target-payload.sh
reject() { if bash "$audit" "$@" > "$fixture/rejected.log" 2>&1; then echo 'Unapproved Python accepted' >&2; exit 1; fi; }
printf '#!/usr/bin/python3\nprint("fixture")\n' > "$fixture/original/usr/bin/migrate"
ln -s python3.15 "$fixture/original/usr/bin/python3"
cp -a "$fixture/original/usr/bin/." "$fixture/payload/usr/bin/"
reject "$fixture/payload"
bash "$audit" --original-kde-payload "$fixture/original" "$fixture/payload"
printf '# Changed\n' >> "$fixture/payload/usr/bin/migrate"
reject --original-kde-payload "$fixture/original" "$fixture/payload"
cp "$fixture/original/usr/bin/migrate" "$fixture/payload/usr/bin/migrate"
cp "$fixture/payload/usr/bin/migrate" "$fixture/payload/usr/bin/project-helper.py"
reject --original-kde-payload "$fixture/original" "$fixture/payload"
rm "$fixture/payload/usr/bin/project-helper.py"
ln -sfn python3.16 "$fixture/payload/usr/bin/python3"
reject --original-kde-payload "$fixture/original" "$fixture/payload"
ln -sfn python3.15 "$fixture/payload/usr/bin/python3"
cp "$fixture/payload/usr/bin/migrate" "$fixture/outside/escape.py"
ln -s "$fixture/outside" "$fixture/original/escaped"
mkdir "$fixture/payload/escaped"
cp "$fixture/outside/escape.py" "$fixture/payload/escaped/escape.py"
reject --original-kde-payload "$fixture/original" "$fixture/payload"
reject --original-kde-payload "$fixture/payload" "$fixture/payload"
mkdir "$fixture/header"
printf '\000#!/usr/bin/python3\n' > "$fixture/header/binary"
bash "$audit" "$fixture/header"
printf '#!/usr/bin/pypy3\n' > "$fixture/header/hidden-helper"
reject "$fixture/header"
rm "$fixture/header/hidden-helper"
printf '#!/bin/sh\necho python\n' > "$fixture/header/shell"
bash "$audit" "$fixture/header"
echo 'Original bytes pass; default, changed, added, retargeted and escaping Python reject'
