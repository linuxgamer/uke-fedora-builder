#!/usr/bin/env bash
# Real filesystems on disposable VM disks; the ARM64 boot file is a parser fixture only.
set -Eeuo pipefail
[[ $# == 4 && $2 =~ ^localhost/[a-zA-Z0-9._:/-]+$ ]]
vm=$(realpath "$1") sdk=$2 policy=$(realpath "$3") output=$(realpath -m "$4")
repo=$(cd "$(dirname "$0")/.." && pwd)
[[ -f $policy && ! -e $output && ! -L $output ]]
[[ -f $vm/vmlinuz && -f $vm/initramfs.cpio.gz && -f $vm/inputs.sha256 ]]
(cd "$vm"; sha256sum -c inputs.sha256)
cmp "$vm/init" "$repo/src/image/f2fs-vm-init.sh"
cmp "$vm/filesystem-policy" "$repo/src/image/filesystem-policy.sh"
mkdir -m700 "$output"
sha256sum "$repo/src/image/f2fs-vm-init.sh" "$repo/src/image/filesystem-policy.sh" \
    "$repo/src/image/check-userdata-payload.cpp" "$repo/src/image/metadata-manifest.sh" "$0" > "$output/source-inputs.sha256"
podman run --rm --pull=never --network=none --security-opt label=disable \
    -v "$repo:/builder:ro" -v "$output:/work:rw" -v "$policy:/policy:ro" \
    --entrypoint /bin/bash "$sdk" -c '
        set -Eeuo pipefail
        root=/work/fixture
        mkdir -p "$root/etc/selinux/targeted/contexts/files" "$root/usr/bin" "$root/usr/share" /work/tools
        cp /policy "$root/etc/selinux/targeted/contexts/files/file_contexts"
        printf "Filesystem growth fixture\n" > "$root/etc/fixture.txt"
        head -c 1048576 /dev/urandom > "$root/usr/share/data"
        cp /usr/bin/true "$root/usr/bin/probe"
        ln "$root/usr/bin/probe" "$root/usr/bin/probe-link"
        ln -s etc/fixture.txt "$root/fixture-link"
        setfacl -m u:123:r-- "$root/etc/fixture.txt"
        setfacl -d -m u:123:rx "$root/usr/share"
        setcap cap_net_bind_service=ep "$root/usr/bin/probe"
        bash /builder/src/image/metadata-manifest.sh "$root" /work/xattrs.expected.tsv
        test -s /work/xattrs.expected.tsv
        tar --create --numeric-owner --one-file-system --sort=name --acls --xattrs \
            --xattrs-include=security.capability -f /work/rootfs.tar -C "$root" .
        c++ -std=c++17 -O2 -Wall -Wextra -Werror /builder/src/image/check-userdata-payload.cpp \
            -o /work/tools/check $(pkg-config --cflags --libs openssl libzstd)
        c++ -std=c++17 -O2 -Wall -Wextra -Werror /builder/src/boot/boot-image.cpp -o /work/tools/codec
        truncate -s 4096 /work/Image
        printf "\000\020\000\000\000\000\000\000" | dd of=/work/Image bs=1 seek=16 conv=notrunc status=none
        printf "\101\122\115\144" | dd of=/work/Image bs=1 seek=56 conv=notrunc status=none
        { printf "\004\000\000\000\104\000\000\000\001\105\113\125UKE\000";
          printf "root-selector-v2;userdata=f2fs,ext4,xfs,btrfs;slot=a,b;vrr-min=0,30\000"; } \
            | dd of=/work/Image bs=1 seek=256 conv=notrunc status=none
        /work/tools/codec create /work/Image /work/fixture-boot.img userdata
    ' > "$output/fixture.log" 2>&1
run_vm() {
    local directory=$1 filesystem=$2 phase=$3 readonly=$4 arguments=$5
    podman run --rm --pull=never --network=none --security-opt label=disable --cpus=2 --memory=3g --device /dev/kvm \
        -v "$vm:/vm:ro" -v "$directory:/job:rw" "$sdk" \
        /usr/bin/timeout 900 qemu-system-x86_64 \
        -machine q35,accel=kvm -cpu host -smp 2 -m 2048 -nodefaults -display none -monitor none -serial stdio \
        -no-reboot -nic none -kernel /vm/vmlinuz -initrd /vm/initramfs.cpio.gz \
        -append "console=ttyS0 rdinit=/uke-compose-init selinux=0 panic=1 uke.userdata-compose=1 uke.userdata-filesystem=$filesystem $arguments" \
        -drive "if=none,id=target,format=raw,file=/job/root.img,cache=none,readonly=$readonly" \
        -device virtio-blk-pci,drive=target,logical_block_size=4096,physical_block_size=4096 \
        -virtfs local,path=/job,mount_tag=compose,security_model=none,readonly=on \
        > "$directory/$phase.log" 2>&1
    if [[ $phase == refused-patch-grow ]]; then
        grep -Fq 'UKE_USERDATA_COMPOSE_FAILED:patch-grow-conflict' "$directory/$phase.log"
    elif grep -Eq 'UKE_USERDATA_COMPOSE_FAILED|Kernel panic' "$directory/$phase.log"; then
        return 1
    fi
}
for filesystem in f2fs ext4 xfs btrfs; do
    directory=$output/$filesystem
    mkdir "$directory"
    ln "$output/rootfs.tar" "$directory/rootfs.tar"
    ln "$output/xattrs.expected.tsv" "$directory/xattrs.expected.tsv"
    (cd "$directory"; sha256sum rootfs.tar > rootfs.tar.sha256)
    truncate -s 1G "$directory/root.img"
    run_vm "$directory" "$filesystem" create off ''
    grep -Eq "^UKE_USERDATA_COMPOSE_PASSED:$filesystem"$'\r?$' "$directory/create.log"
    if [[ $filesystem == f2fs ]]; then
        before=$(sha256sum "$directory/root.img" | cut -d ' ' -f1)
        run_vm "$directory" "$filesystem" refused-patch-grow on 'uke.f2fs-patch=1 uke.userdata-grow=1'
        [[ $(sha256sum "$directory/root.img" | cut -d ' ' -f1) == "$before" ]]
    fi
    uuid=$(blkid -p -s UUID -o value "$directory/root.img")
    [[ -n $uuid ]]
    truncate -s 2G "$directory/root.img"
    run_vm "$directory" "$filesystem" grow off uke.userdata-grow=1
    grep -Eq "^UKE_USERDATA_COMPOSE_PASSED:$filesystem"$'\r?$' "$directory/grow.log"
    [[ $(blkid -p -s UUID -o value "$directory/root.img") == "$uuid" ]]
    before=$(sha256sum "$directory/root.img" | cut -d ' ' -f1)
    run_vm "$directory" "$filesystem" readonly on uke.userdata-xattr-audit=1
    grep -Eq "^UKE_USERDATA_READONLY_CHECK_PASSED:$filesystem"$'\r?$' "$directory/readonly.log"
    [[ $(sha256sum "$directory/root.img" | cut -d ' ' -f1) == "$before" ]]
    zstd -q -T1 -3 "$directory/root.img" -o "$directory/root.img.zst"
    podman run --rm --pull=never --network=none --security-opt label=disable -v "$output:/work:ro" \
        --entrypoint /work/tools/check "$sdk" \
        "/work/$filesystem/root.img.zst" 2147483648 "$before" /work/fixture-boot.img \
        "$(sha256sum "$output/fixture-boot.img" | cut -d ' ' -f1)" "$filesystem" > "$directory/payload.json"
    printf '%s: create, grow, contents/ACL/capability/SELinux preservation, UUID, read-only hash and geometry passed.\n' "$filesystem"
done
sha256sum -c "$output/source-inputs.sha256"
echo 'Four-filesystem VM data preservation passed; native Uke boot and repeated-boot acceptance remain untested.'
