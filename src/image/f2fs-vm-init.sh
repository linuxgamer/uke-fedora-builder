#!/bin/bash
# Host composition guest only; never included in the Fedora tablet root.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=src/image/filesystem-policy.sh
source /uke-filesystem-policy
fail() {
    echo "UKE_USERDATA_COMPOSE_FAILED:${filesystem:-unknown}"
    [[ ${filesystem:-f2fs} != f2fs ]] || echo 'UKE_F2FS_COMPOSE_FAILED'
    sync
    stty -F /dev/ttyS0 -echo || true
    echo b > /proc/sysrq-trigger
}
trap fail ERR
[[ $$ == 1 ]]
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /run /share /target
mount -t tmpfs tmpfs /run
grep -Eq '(^| )uke\.(f2fs|userdata)-compose=1( |$)' /proc/cmdline
[[ -b /dev/vda && ! -e /dev/vdb ]]
filesystem=f2fs
seen=0
read -r -a kernel_arguments < /proc/cmdline
for argument in "${kernel_arguments[@]}"; do
    case $argument in
        uke.userdata-filesystem=*)
            ((seen == 0)); seen=1
            filesystem=$(userdata_filesystem "${argument#*=}");;
    esac
done
modprobe "$filesystem"
check_filesystem() {
    case $filesystem:${1:-0} in
        f2fs:1) fsck.f2fs -f --dry-run /dev/vda;;
        f2fs:0) fsck.f2fs -f /dev/vda;;
        ext4:1) e2fsck -f -n /dev/vda;;
        ext4:0) e2fsck -f -p /dev/vda;;
        xfs:*) xfs_repair -n /dev/vda;;
        btrfs:*) btrfs check --readonly /dev/vda;;
    esac
}
modprobe 9pnet_virtio
modprobe 9p
mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576,ro compose /share
if grep -Eq '(^| )uke\.(f2fs|userdata)-xattr-audit=1( |$)' /proc/cmdline; then
    [[ $(cat /sys/class/block/vda/ro) == 1 ]]
    case $filesystem in
        f2fs) options=ro,disable_roll_forward;;
        ext4) options=ro,noload;;
        xfs) options=ro,norecovery;;
        btrfs) options=ro,rescue=nologreplay;;
    esac
    mount -t "$filesystem" -o "$options" /dev/vda /target
    /uke-metadata-manifest /target /run/xattrs.actual.tsv
    cmp /share/xattrs.expected.tsv /run/xattrs.actual.tsv
    umount /target
    check_filesystem 1
    echo "UKE_USERDATA_XATTR_AUDIT_PASSED:$filesystem"
    echo "UKE_USERDATA_READONLY_CHECK_PASSED:$filesystem"
    [[ $filesystem != f2fs ]] || echo 'UKE_F2FS_XATTR_AUDIT_PASSED'
    stty -F /dev/ttyS0 -echo
    echo b > /proc/sysrq-trigger
    exit 1
fi
archive=rootfs.tar
[[ ! -f /share/rootfs.tar.zst ]] || archive=rootfs.tar.zst
[[ -f /share/$archive && -f /share/$archive.sha256 ]]
(cd /share; sha256sum -c "$archive.sha256")
grow=0
patch=0
if grep -Fq 'uke.f2fs-patch=1' /proc/cmdline; then
    [[ $filesystem == f2fs ]]
    if grep -Eq '(^| )uke\.(f2fs|userdata)-grow=1( |$)' /proc/cmdline; then
        echo 'UKE_USERDATA_COMPOSE_FAILED:patch-grow-conflict' >&2
        false
    fi
    [[ -s /share/fsuuid.expected ]]
    [[ $(blkid -s TYPE -o value /dev/vda) == f2fs ]]
    [[ $(blkid -s LABEL -o value /dev/vda) == UKE_LINUX ]]
    [[ $(blkid -s UUID -o value /dev/vda) == "$(cat /share/fsuuid.expected)" ]]
    patch=1
    check_filesystem
elif grep -Eq '(^| )uke\.(f2fs|userdata)-grow=1( |$)' /proc/cmdline; then
    grow=1
    [[ $(blkid -s TYPE -o value /dev/vda) == "$filesystem" ]]
    [[ $(blkid -s LABEL -o value /dev/vda) == UKE_LINUX ]]
    before_uuid=$(blkid -s UUID -o value /dev/vda)
    [[ -n $before_uuid ]]
    check_filesystem
    [[ $filesystem != f2fs ]] || resize.f2fs /dev/vda
else
    case $filesystem in
        f2fs) mkfs.f2fs -f -l UKE_LINUX -O extra_attr,inode_checksum,sb_checksum /dev/vda;;
        ext4) mkfs.ext4 -F -b 4096 -L UKE_LINUX -E lazy_itable_init=0,lazy_journal_init=0 /dev/vda;;
        xfs) mkfs.xfs -f -b size=4096 -L UKE_LINUX /dev/vda;;
        btrfs) mkfs.btrfs -f -s 4096 -L UKE_LINUX /dev/vda;;
    esac
fi
mount -t "$filesystem" /dev/vda /target
if ((grow)); then
    [[ $filesystem == f2fs ]] || /usr/lib/systemd/systemd-growfs /target
    [[ $(blkid -s UUID -o value /dev/vda) == "$before_uuid" ]]
fi
# File labels are generated from this root's original Fedora policy.
contexts=/target/etc/selinux/targeted/contexts/files/file_contexts
if (( patch )); then
    [[ ! -e /target/.uke-staged-root && ! -L /target/.uke-staged-root ]]
    mkdir -m700 /target/.uke-staged-root
    tar --extract --numeric-owner --same-owner --acls --xattrs --xattrs-include=security.capability \
        -f "/share/$archive" -C /target/.uke-staged-root
    # Stage on the existing disk; only changed files replace their old inodes.
    rsync -aHAXc --numeric-ids --delete --exclude=/.uke-staged-root/ \
        /target/.uke-staged-root/ /target/
    rm -rf -- /target/.uke-staged-root
    setfiles -F -r /target "$contexts" /target
elif (( ! grow )); then
    tar --extract --numeric-owner --same-owner --acls --xattrs --xattrs-include=security.capability \
        -f "/share/$archive" -C /target
    setfiles -F -r /target "$contexts" /target
fi
[[ -s $contexts ]]
tar --compare --numeric-owner --acls --xattrs --xattrs-include=security.capability \
    -f "/share/$archive" -C /target
setfiles -n -v -r /target "$contexts" /target > /run/relabel-check.log
[[ ! -s /run/relabel-check.log ]]
/uke-metadata-manifest /target /run/xattrs.actual.tsv
cmp /share/xattrs.expected.tsv /run/xattrs.actual.tsv
if (( patch )); then
    [[ $(blkid -s UUID -o value /dev/vda) == "$(cat /share/fsuuid.expected)" ]]
    sync
    fstrim /target
fi
sync
umount /target
check_filesystem
echo "UKE_USERDATA_COMPOSE_PASSED:$filesystem"
[[ $filesystem != f2fs ]] || echo 'UKE_F2FS_COMPOSE_PASSED'
sync
stty -F /dev/ttyS0 -echo
echo b > /proc/sysrq-trigger
