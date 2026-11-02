#!/bin/bash
# Static integration/refusal checks, without executing package/target code.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.."; pwd)
here=$root/src/ubuntu
bash -n "$here/configure-root.sh"
grep -Fxq 'Requires=apparmor.service' "$here/uke-apparmor-verify.service"
grep -Fxq 'After=apparmor.service local-fs.target' "$here/uke-apparmor-verify.service"
grep -Fxq 'RequiredBy=multi-user.target' "$here/uke-apparmor-verify.service"
grep -Fxq 'OnFailure=emergency.target' "$here/uke-apparmor-verify.service"
grep -Fxq 'ExecStart=/usr/libexec/uke-apparmor-probe' "$here/uke-apparmor-verify.service"
grep -Fq 'context != "uke-apparmor-probe (enforce)\n"' "$here/apparmor-probe.cpp"
grep -Fq 'errno != EACCES' "$here/apparmor-probe.cpp"
grep -Fxq '  audit deny /etc/uke-test/denied r,' "$here/uke-apparmor-probe.profile"
! grep -Eq 'flags=.*complain|apparmor=0|selinux=0|setenforce|aa-complain|--disable|--unconfined|--autologin|NOPASSWD' "$here/"*
! grep -Fq -- '--vm-policy-test' "$here/uke-apparmor-verify.service"
! grep -Eq 'useradd|chpasswd|passwd -|ssh-keygen|bootctl|fastboot|efibootmgr|/dev/(sd|nvme|block)' "$here/configure-root.sh"
echo 'Ubuntu root policy loader, denial probe, exact-cohort and credential-free contracts pass; runtime remains separate.'
