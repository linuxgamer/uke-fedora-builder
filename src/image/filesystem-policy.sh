#!/bin/bash
# Shared host/composition-VM policy; never installed on the tablet.
userdata_filesystem() {
    case "$1" in
        f2fs|ext4|xfs|btrfs) printf '%s\n' "$1";;
        *) echo 'Unsupported userdata filesystem' >&2; return 2;;
    esac
}
userdata_profile_filesystem() {
    local value
    value=$(jq -er 'select(.root_partition=="userdata" and .root_label=="UKE_LINUX") | .root_filesystem | select(type=="string")' "$1") || return 2
    userdata_filesystem "$value"
}
