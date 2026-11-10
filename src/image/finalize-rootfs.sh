#!/usr/bin/env bash
# Run after native systemd-hwdb has populated the composed Fedora installroot.
set -Eeuo pipefail
root=/workspace/root
[[ -d $root && -s $root/etc/udev/hwdb.bin ]] || { echo 'Missing composed root or hwdb' >&2; exit 1; }
phase_start=$SECONDS
phase_done() {
    printf '%s\t%s\n' "$1" "$((SECONDS - phase_start))" >> /workspace/timing.tsv
    phase_start=$SECONDS
}
hwdb_bytes=$(stat -c %s "$root/etc/udev/hwdb.bin")
((hwdb_bytes > 10000000)) || { echo "Incomplete hwdb.bin ($hwdb_bytes bytes)" >&2; exit 1; }
root_mib=$(cat /workspace/ROOT-MIB)
chmod 0755 "$root"
local_contexts=$root/etc/selinux/targeted/contexts/files/file_contexts.local
expected_context='/mnt/vendor/persist -d system_u:object_r:mnt_t:s0'
[[ -f $local_contexts ]] || { echo 'Missing local SELinux file contexts' >&2; exit 1; }
[[ ! -s $local_contexts || $(cat "$local_contexts") == "$expected_context" ]] || {
    echo 'Unexpected local SELinux file contexts' >&2; exit 1;
}
printf '%s\n' "$expected_context" > "$local_contexts"
for name in tm/normal.bin tm/config.ini csot/normal.bin csot/config.ini reference.bin; do
    [[ -f $root/var/lib/uke-touch/$name && ! -L $root/var/lib/uke-touch/$name ]] || {
        echo "Missing private touch input: $name" >&2; exit 1;
    }
done
sha256sum "$root/var/lib/uke-touch/tm/normal.bin" \
    "$root/var/lib/uke-touch/tm/config.ini" \
    "$root/var/lib/uke-touch/csot/normal.bin" \
    "$root/var/lib/uke-touch/csot/config.ini" \
    "$root/var/lib/uke-touch/reference.bin" | \
    sed "s|  $root/var/lib/uke-touch/|  |" > /workspace/TOUCH-INSTALLED.sha256
truncate -s "$((root_mib * 1024 * 1024))" /workspace/userdata.raw.img
mkfs.ext4 -q -F -b 4096 -L UKE_LINUX -m 0 \
    -E lazy_itable_init=0,lazy_journal_init=0 -d "$root" /workspace/userdata.raw.img
phase_done ext4-population
g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/ext4-labels.cpp \
    -o /workspace/ext4-labels -lext2fs -lcom_err -lselinux
contexts=$root/etc/selinux/targeted/contexts/files/file_contexts
[[ -s $contexts ]] || { echo 'Fedora SELinux file contexts are missing' >&2; exit 1; }
/workspace/ext4-labels apply /workspace/userdata.raw.img "$root" "$contexts"
/workspace/ext4-labels verify /workspace/userdata.raw.img "$root" "$contexts"
e2fsck -fn /workspace/userdata.raw.img >/workspace/ext4-check.txt
phase_done labeling-and-fsck
g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/android-sparse.cpp -o /workspace/android-sparse
/workspace/android-sparse encode /workspace/userdata.raw.img /workspace/userdata.img
/workspace/android-sparse decode /workspace/userdata.img /workspace/userdata.readback.img
cmp /workspace/userdata.raw.img /workspace/userdata.readback.img
phase_done sparse-roundtrip
rm /workspace/userdata.readback.img /workspace/ext4-labels /workspace/android-sparse
(cd "$root"; tar --numeric-owner --xattrs --acls -cpf - .) | zstd -T2 -3 -o /workspace/rootfs.tar.zst
phase_done rootfs-archive
sha256sum /workspace/rootfs.tar.zst /workspace/userdata.raw.img \
    /workspace/userdata.img /workspace/packages.tsv /workspace/PROFILE \
    /workspace/PROFILE-ID /workspace/ROOT-MIB \
    /workspace/KERNEL-RPMS.sha256 /workspace/CORE-RPM.sha256 \
    /workspace/HARDWARE-RPMS.sha256 /workspace/LOCAL-BLOBS.sha256 \
    /workspace/TOUCH-PANEL /workspace/TOUCH-INSTALLED.sha256 \
    /workspace/timing.tsv | \
    sed 's|/workspace/||' > /workspace/SHA256SUMS
