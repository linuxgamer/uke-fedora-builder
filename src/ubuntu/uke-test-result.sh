#!/bin/sh
# Noninteractive status display; accepts no commands, input or credentials.
set -eu
report=/var/lib/uke-ubuntu-test/result.txt
temporary=$(mktemp /var/lib/uke-ubuntu-test/result.XXXXXX)
trap 'rm -f "$temporary"' EXIT HUP INT TERM
probe_state=$(systemctl show --property=ActiveState --value uke-apparmor-verify.service)
probe_result=$(systemctl show --property=Result --value uke-apparmor-verify.service)
probe_status=$(systemctl show --property=ExecMainStatus --value uke-apparmor-verify.service)
policy_result=$(systemctl show --property=Result --value apparmor.service)
{
 printf '\n\nUKE UBUNTU 27.04 TEST RESULT\n\n'
 printf 'Kernel: %s\nRoot filesystem: %s\n' "$(uname -r)" "$(findmnt -n -o FSTYPE /)"
 if [ "$probe_state:$probe_result:$probe_status:$policy_result" = active:success:0:success ]; then
  printf 'AppArmor: PASS - enforcing profile allowed and denied the expected reads\n'
 else
  printf 'AppArmor: FAIL - normal system startup was not admitted\n'
 fi
 printf 'Probe state/result/exit: %s / %s / %s\nPolicy loader: %s\n' "$probe_state" "$probe_result" "$probe_status" "$policy_result"
 printf '\nConsole diagnostic only. No desktop, login or remote shell.\n'
 printf 'Photograph this result. No keyboard is required.\n'
 printf 'Stored report: /var/lib/uke-ubuntu-test/result.txt\n'
 printf 'Hardware functions, firmware and rollback remain unqualified.\n'
} > "$temporary"
chmod 644 "$temporary"
mv -f "$temporary" "$report"
cat "$report"
