#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cp /bin/true "$fixture/valid-elf"
printf '#!/usr/bin/python3\nprint("fixture")\n' > "$fixture/allowed.py"
bash "$root/src/audit/check-target-elf.sh" "$fixture"
printf '\177ELF' > "$fixture/truncated-elf"
if bash "$root/src/audit/check-target-elf.sh" "$fixture" >"$fixture/output" 2>&1; then
  echo 'Truncated ELF accepted' >&2; exit 1
fi
grep -F 'Unreadable target ELF rejected: truncated-elf' "$fixture/output"
echo 'Valid ELF and Python script admitted; truncated ELF rejected'
