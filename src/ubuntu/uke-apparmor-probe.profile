# SPDX-License-Identifier: MIT
abi <abi/4.0>,
include <tunables/global>

profile uke-apparmor-probe /usr/libexec/uke-apparmor-probe {
  include <abstractions/base>
  /sys/module/apparmor/parameters/enabled r,
  /sys/kernel/security/lsm r,
  /proc/*/attr/apparmor/current r,
  /etc/uke-test/allowed r,
  /etc/uke-test/denied r,
  audit deny /etc/uke-test/denied r,
}
