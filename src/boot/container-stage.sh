#!/usr/bin/env bash
# Frozen host stages. Never executes tablet binaries or donor scripts.
set -Eeuo pipefail
[[ $# == 2 && -d /job/inputs ]]
stage=$1 owner=$2
trap 'if [[ $owner != none ]]; then chown -R "$owner" /job; fi' EXIT
profile=/job/inputs/profile.json
release=$(jq -r .kernel_release "$profile")
verify() { [[ $(sha256sum "$1" | cut -d ' ' -f1) == "$2" ]]; }
verify /job/inputs/kernel.spec "$(jq -r .kernel_rpm_spec_sha256 "$profile")"
case $stage in
prepare)
    verify /job/inputs/kernel-manifest.json "$(jq -r .kernel_manifest_sha256 "$profile")"
    verify /job/inputs/core-initramfs.img "$(jq -r .initramfs_sha256 "$profile")"
    verify /job/inputs/stock-boot.img "$(jq -r .stock_boot_sha256 "$profile")"
    verify /job/inputs/modules.rpm "$(jq -r '.packages[]|select(.file|contains("-modules-"))|.sha256' /job/inputs/kernel-manifest.json)"
    verify /job/inputs/core.rpm "$(jq -r '.packages[]|select(.file|contains("-core-"))|.sha256' /job/inputs/kernel-manifest.json)"
    g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/src/boot/boot-image.cpp -o /job/boot-image
    bash /builder/tests/boot-image-contract.sh /job/boot-image
    /job/boot-image inspect /job/inputs/stock-boot.img > /job/stock-header.json
    jq -e '.header_version==4 and .ramdisk_bytes==0 and .signature_bytes==0 and .image_bytes==100663296' /job/stock-header.json >/dev/null
    rm -rf /job/initramfs-root /job/modules-payload
    mkdir /job/initramfs-root /job/modules-payload
    (cd /job/modules-payload; rpm2cpio /job/inputs/modules.rpm | cpio -idm --quiet --no-absolute-filenames)
    (cd /job/modules-payload; rpm2cpio /job/inputs/core.rpm | cpio -idm --quiet --no-absolute-filenames)
    (cd /job/initramfs-root; gzip -cd /job/inputs/core-initramfs.img | cpio -idm --quiet --no-absolute-filenames)
    module_root=/job/initramfs-root/usr/lib/modules/$release
    # Retain dracut's dependency-closed module selection, replacing every
    # module by the bytes from the qualified full 44-patch build.
    while IFS= read -r -d '' file; do
        relative=${file#"$module_root/"}
        source=/job/modules-payload/usr/lib/modules/$release/$relative
        [[ -f $source && ! -L $source ]]
        cp "$source" "$file"
        [[ $(modinfo -F vermagic "$file") == "$release "* ]]
    done < <(find "$module_root/kernel" -type f -name '*.ko*' -print0)
    for name in modules.builtin modules.builtin.modinfo; do
        cp "/job/modules-payload/usr/lib/modules/$release/$name" "$module_root/$name"
    done
    depmod -b /job/initramfs-root -m /usr/lib/modules -a "$release"
    install -m644 /builder/src/boot/uke-boot-debug.target /job/initramfs-root/usr/lib/systemd/system/
    install -m644 /builder/src/image/dracut/91uke-bringup/*.service /job/initramfs-root/usr/lib/systemd/system/
    install -m644 /builder/src/boot/uke-boot-debug-status.service /job/initramfs-root/usr/lib/systemd/system/
    install -m755 /builder/src/boot/debug-status.sh /job/initramfs-root/usr/libexec/uke-boot-debug-status
    # Do not retain the Core recipe's root= arguments in dracut's separate
    # userspace command-line file after selecting the standalone debug mode.
    rm -f /job/initramfs-root/etc/cmdline.d/10-default.conf
    [[ -x /job/initramfs-root/usr/lib/systemd/systemd && -x /job/initramfs-root/usr/bin/uke-boot-status ]]
    # The debug target does not pull in initrd.target or switch-root. Mask
    # automatic storage jobs as a second explicit no-root-mount boundary.
    for name in initrd-root-fs.target initrd-root-device.target initrd-fs.target initrd-parse-etc.service \
        initrd-switch-root.target initrd-switch-root.service dracut-mount.service; do
        ln -sfn /dev/null "/job/initramfs-root/usr/lib/systemd/system/$name"
    done
    bash /builder/src/audit/check-target-elf.sh /job/initramfs-root
    bash /builder/src/audit/check-target-privacy.sh /job/initramfs-root
    while IFS= read -r -d '' file; do
        if [[ $(od -An -tx1 -N4 "$file" | tr -d ' \n') == 7f454c46 ]]; then
            readelf -h "$file" | grep -E 'Machine:.*AArch64' >/dev/null
        fi
    done < <(find /job/initramfs-root -type f -print0)
    find /job/initramfs-root -exec touch -h -d '@1791024250' {} +
    (cd /job/initramfs-root; find . -print0 | sort -z | cpio --null --quiet --reproducible --owner=0:0 -o -H newc) | gzip -n > /job/initramfs.cpio.gz
    printf '%s\n' 'Pinned template, initramfs, 44-patch module selection and native payload verified'
    ;;
kernel)
    # Keep the original Kbuild absolute paths so qualified cached objects can
    # be reused. /work/kernel resolves only inside this disposable container.
    [[ -d /work/kernel ]]
    # A prior qualified boot cache may use /job/kernel. Both bind paths refer
    # to the isolated copy; retain the recorded path instead of invalidating
    # every compiler command. Reject every other source prefix.
    cached_source=$(readlink /work/kernel/build/fedora-44/7.2.9/rpmbuild/kernel-out/source)
    suffix=build/fedora-44/7.2.9/rpmbuild/BUILD/senemos-uke-linux-kernel-mainline-7.2.9-build/linux-7.2.9
    case $cached_source in
        /work/kernel/"$suffix") top=/work/kernel/build/fedora-44/7.2.9/rpmbuild;;
        /job/kernel/"$suffix") top=/job/kernel/build/fedora-44/7.2.9/rpmbuild;;
        *) echo 'Unrecognized cached Kbuild source path' >&2; exit 1;;
    esac
    out=$top/kernel-out
    mkdir -p "$top/SOURCES" "$top/SPECS"
    cp /job/inputs/SOURCES/* "$top/SOURCES/"
    cp /job/inputs/kernel.spec "$top/SPECS/kernel.spec"
    rpmbuild --nodeps -bp --target=aarch64 --define "_topdir $top" "$top/SPECS/kernel.spec"
    source=$top/BUILD/senemos-uke-linux-kernel-mainline-7.2.9-build/linux-7.2.9
    cmp "$source/senemos-applied-patches.txt" /job/inputs/applied-patches.txt
    cmp "$out/senemos-applied-patches.txt" /job/inputs/applied-patches.txt
    jq -S . "$source/senemos-adaptation/source-lock.json" > /job/prepared-source.json
    jq -S .source /job/inputs/kernel-manifest.json > /job/qualified-source.json
    cmp /job/prepared-source.json /job/qualified-source.json
    # On resume the original base config is restored before applying only
    # the three reviewed built-in initramfs/command-line requirements.
    if [[ ! -f /job/base.config ]]; then
        verify "$out/.config" "$(jq -r .kernel_config_sha256 "$profile")"
        cp "$out/.config" /job/base.config
        bash /builder/src/boot/vmlinux-exports.sh "$out/Module.symvers" > /job/base-vmlinux.symvers
    fi
    cp /job/base.config "$out/.config"
    export ARCH=arm64 LLVM=1 KBUILD_BUILD_USER=senemos KBUILD_BUILD_HOST=uke-builder
    export KBUILD_BUILD_TIMESTAMP='2026-10-03 10:44:10 UTC' KBUILD_BUILD_VERSION=1 SOURCE_DATE_EPOCH=1791024250
    cd "$source"
    scripts/config --file "$out/.config" --set-str INITRAMFS_SOURCE /job/initramfs.cpio.gz \
        --enable INITRAMFS_FORCE --enable CMDLINE_FORCE --disable CMDLINE_FROM_BOOTLOADER \
        --set-str CMDLINE "$(jq -r .kernel_command_line "$profile")"
    make O="$out" LOCALVERSION=-senemos-uke olddefconfig
    grep -Fx 'CONFIG_INITRAMFS_SOURCE="/job/initramfs.cpio.gz"' "$out/.config"
    grep -Fx CONFIG_INITRAMFS_FORCE=y "$out/.config"
    grep -Fx CONFIG_CMDLINE_FORCE=y "$out/.config"
    grep -Fx '# CONFIG_BOOT_CONFIG is not set' "$out/.config"
    grep '^CONFIG_' /job/base.config | grep -Ev '^CONFIG_(INITRAMFS_(SOURCE|FORCE|ROOT_UID|ROOT_GID|COMPRESSION_[A-Z0-9_]+)|CMDLINE|CMDLINE_FORCE|CMDLINE_FROM_BOOTLOADER)=' | sort > /job/base-module.config
    grep '^CONFIG_' "$out/.config" | grep -Ev '^CONFIG_(INITRAMFS_(SOURCE|FORCE|ROOT_UID|ROOT_GID|COMPRESSION_[A-Z0-9_]+)|CMDLINE|CMDLINE_FORCE|CMDLINE_FROM_BOOTLOADER)=' | sort > /job/boot-module.config
    cmp /job/base-module.config /job/boot-module.config
    diff -u /job/base.config "$out/.config" > /job/config-delta.txt || [[ $? == 1 ]]
    # All existing requirements remain enabled after Kconfig resolution.
    for fragment in "$source"/senemos-adaptation/configs/{uke,fedora}.config; do
        while IFS= read -r item; do
            case $item in CONFIG_*=*) grep -Fx "$item" "$out/.config" >/dev/null;; esac
        done < "$fragment"
    done
    make O="$out" LOCALVERSION=-senemos-uke -j"$(cat /job/inputs/jobs)" Image modules
    [[ $(make -s O="$out" LOCALVERSION=-senemos-uke kernelrelease) == "$release" ]]
    # These changes affect built-in startup only. Reuse of qualified modules
    # is admitted only if every exported core symbol CRC remains identical.
    bash /builder/src/boot/vmlinux-exports.sh "$out/Module.symvers" > /job/boot-vmlinux.symvers
    cmp /job/base-vmlinux.symvers /job/boot-vmlinux.symvers
    cp "$out/.config" /job/boot.config
    cp "$out/arch/arm64/boot/Image" /job/Image
    cp "$out/arch/arm64/boot/dts/qcom/sm7675-xiaomi-uke.dtb" /job/independent-uke.dtb
    cp "$out/Module.symvers" /job/Module.symvers
    # The final linker merges .init.ramfs into .init.data. Read the linked
    # start and stored 64-bit length rather than assuming a separate section.
    llvm-objcopy --dump-section .init.data=/job/init-data.bin "$out/vmlinux" /job/ramfs-inspection.elf
    base=$(llvm-readelf -SW "$out/vmlinux" | awk '$2==".init.data" {print $4}')
    start=$(llvm-nm "$out/vmlinux" | awk '$3=="__initramfs_start" {print $1}')
    length_address=$(llvm-nm "$out/vmlinux" | awk '$3=="__initramfs_size" {print $1}')
    [[ $base =~ ^[a-f0-9]{16}$ && $start =~ ^[a-f0-9]{16}$ && $length_address =~ ^[a-f0-9]{16}$ ]]
    offset=$((16#$start - 16#$base)); size_offset=$((16#$length_address - 16#$base))
    length=$(od -An -tu8 -j "$size_offset" -N8 /job/init-data.bin | tr -d ' \n')
    ((offset >= 0 && length > 0 && offset + length <= $(stat -c %s /job/init-data.bin)))
    dd if=/job/init-data.bin of=/job/embedded-initramfs.cpio.gz bs=1M skip="$offset" count="$length" iflag=skip_bytes,count_bytes status=none
    cmp /job/initramfs.cpio.gz /job/embedded-initramfs.cpio.gz
    rm /job/ramfs-inspection.elf /job/init-data.bin
    printf '%s\n' 'Image compiled; built-in initramfs bytes and complete core export ABI verified'
    ;;
pack)
    [[ -s /job/Image && -s /job/boot.config ]]
    rm -f /job/fedora_boot.img.part /job/roundtrip-Image
    /job/boot-image pack /job/inputs/stock-boot.img /job/Image /job/fedora_boot.img.part "$(jq -r .boot_partition_bytes "$profile")"
    /job/boot-image inspect /job/fedora_boot.img.part > /job/boot-header.json
    jq -e '.header_version==4 and .ramdisk_bytes==0 and .signature_bytes==0 and .avb_footer_present==false and .image_bytes==100663296' /job/boot-header.json >/dev/null
    /job/boot-image extract /job/fedora_boot.img.part /job/roundtrip-Image
    cmp /job/Image /job/roundtrip-Image
    mv /job/fedora_boot.img.part /job/fedora_boot.img
    cp "$profile" /job/profile.json
    (cd /job; sha256sum Image boot.config initramfs.cpio.gz fedora_boot.img independent-uke.dtb Module.symvers boot-header.json profile.json inputs/kernel-manifest.json inputs/applied-patches.txt > SHA256SUMS)
    jq -n --slurpfile profile /job/profile.json --slurpfile header /job/boot-header.json \
        --arg image "$(sha256sum /job/fedora_boot.img | cut -d ' ' -f1)" \
        --arg kernel "$(sha256sum /job/Image | cut -d ' ' -f1)" \
        --arg initramfs "$(sha256sum /job/initramfs.cpio.gz | cut -d ' ' -f1)" \
        --arg config "$(sha256sum /job/boot.config | cut -d ' ' -f1)" \
        --arg recipe "$(cat /job/inputs/recipe-sha256)" \
        --arg codec "$(sha256sum /job/boot-image | cut -d ' ' -f1)" \
        '{schema_version:1,product:"fedora_boot.img",status:"boot-format-and-payload-candidate",recipe_sha256:$recipe,host_codec_sha256:$codec,profile:$profile[0],header:$header[0],sha256:{boot:$image,kernel:$kernel,initramfs:$initramfs,config:$config},checks:{android_v4_roundtrip:true,pinned_source_preparation:true,applied_patch_count:44,embedded_initramfs_byte_match:true,core_export_abi_match:true,module_payload_reused:true,native_aarch64_payload:true,privacy:true},qemu_tested:false,boot_tested:false,hardware_tested:false,flash_executed:false}' > /job/manifest.json
    (cd /job; sha256sum manifest.json >> SHA256SUMS; sha256sum -c SHA256SUMS)
    ;;
*) exit 2;;
esac
