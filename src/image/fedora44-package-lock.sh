#!/usr/bin/env bash
# Source this file to use one set of Fedora 44 package identities throughout the image build.
lock_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
lock_file=$lock_root/configs/fedora44-package-lock.json
jq -e '.schema_version == 1 and .kernel_version == "7.2.11" and
       (.kernel_release | type == "string" and test("^[1-9][0-9]*$")) and
       .boot_integration_version == "1.5.2" and
       (.boot_integration_release | type == "string" and test("^[1-9][0-9]*$"))' \
    "$lock_file" >/dev/null || { echo 'Invalid Fedora 44 package lock' >&2; return 1; }
uke_kernel_krel=$(jq -er '.kernel_version + "-" + .kernel_release' "$lock_file")
uke_kernel_rpm_release=$uke_kernel_krel.fc44
uke_boot_rpm_release=$(jq -er '.boot_integration_version + "-" + .boot_integration_release + ".fc44"' "$lock_file")
