#!/usr/bin/env bash
# Frozen, offline host stages. Every write stays below the disposable job.
set -Eeuo pipefail
[[ $# == 2 && -d /job/inputs ]]
stage=$1 owner=$2
trap 'if [[ $owner != none ]]; then chown -R "$owner" /job; fi' EXIT
profile=/job/inputs/profile.json
release=7.2.9-senemos-uke
verify() { [[ $(sha256sum "$1" | cut -d ' ' -f1) == "$2" ]]; }
(cd /job/inputs; sha256sum -c SHA256SUMS)
case $stage in
source)
    top=/job/kernel/build/fedora-44/7.2.9/rpmbuild
    mkdir -p "$top/SOURCES" "$top/SPECS" /job/dt
    cp /job/inputs/SOURCES/* "$top/SOURCES/"
    cp /job/inputs/kernel.spec "$top/SPECS/kernel.spec"
    verify "$top/SPECS/kernel.spec" "$(jq -r .kernel_rpm_spec_sha256 "$profile")"
    rpmbuild --nodeps -bp --target=aarch64 --define "_topdir $top" "$top/SPECS/kernel.spec"
    source=$top/BUILD/senemos-uke-linux-kernel-mainline-7.2.9-build/linux-7.2.9
    cmp "$source/senemos-applied-patches.txt" /job/inputs/applied-patches.txt
    jq -S . "$source/senemos-adaptation/source-lock.json" > /job/prepared-source.json
    jq -S .source /job/inputs/kernel-manifest.json > /job/qualified-source.json
    cmp /job/prepared-source.json /job/qualified-source.json
    bash /kernel-recipe/src/boot/prepare-abl-source.sh "$source" /job/dt
    bash /kernel-recipe/tests/boot-supplier-contract.sh "$source/drivers/regulator/qcom-rpmh-regulator-uke.c" \
        "$source/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c"
    # The host test uses the exact same transform and vendored libfdt C code
    # as the kernel. It does not execute scripts from the source donor.
    gcc -std=gnu11 -O2 -Wall -Wextra -Werror -I "$source/scripts/dtc/libfdt" \
        -c /kernel-recipe/src/boot/uke-abl.c -o /job/dt/uke-abl-host.o
    objects=()
    for name in fdt fdt_ro fdt_wip fdt_rw fdt_sw fdt_strerror fdt_empty_tree fdt_addresses fdt_overlay fdt_check; do
        gcc -std=gnu11 -O2 -I "$source/scripts/dtc/libfdt" -c "$source/scripts/dtc/libfdt/$name.c" -o "/job/dt/$name.o"
        objects+=("/job/dt/$name.o")
    done
    g++ -std=c++20 -O2 -Wall -Wextra -Werror -I "$source/scripts/dtc/libfdt" \
        /kernel-recipe/tests/abl-dt-check.cpp /job/dt/uke-abl-host.o "${objects[@]}" -o /job/dt/abl-dt-check
    printf '%s\n' 'Qualified source preparation and stock-ABL patch applied; host transform compiled'
    # The native root tool intentionally has no JSON parser; emit a checksummed catalog.
    jq -r '"#archive-sha256 "+.archive_sha256, (.files[]|.sha256+"  "+.path)' /builder/configs/firmware/uke-adsp-early.json > /job/early-firmware.sha256
    ;;
dt-test)
    [[ -s /private/live-fdt.dtb ]]
    (cd /private; sha256sum -c live-fdt.sha256)
    if [[ -e /private/abl-fixture ]]; then
        mv /private/abl-fixture "/private/abl-fixture-failed-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    bash /kernel-recipe/tests/abl-dt-contract.sh /job/dt/abl-dt-check /private/live-fdt.dtb \
        /job/dt/ufs.dtbo /job/dt/usb.dtbo /private/abl-fixture
    ;;
audit-initramfs)
    verify /job/inputs/prepared-root.tar "$(jq -r .core_prepared_root_sha256 "$profile")"
    rm -rf /job/initramfs-root
    mkdir /job/initramfs-root
    (cd /job/initramfs-root; gzip -cd /job/initramfs.cpio.gz | cpio -idm --quiet --no-absolute-filenames)
    [[ -s /job/initramfs-root/usr/lib/systemd/system/initrd-switch-root.service ]]
    [[ -L /job/initramfs-root/usr/lib/systemd/system/sysroot.mount.requires/uke-root-guard.service ]]
    [[ ! -e /job/initramfs-root/etc/uke-boot-pair.uuid ]]
    grep -F "root=PARTLABEL=$(jq -r .root_partlabel "$profile") " /job/initramfs-root/etc/cmdline.d/*.conf
    [[ -s /job/initramfs-root/usr/lib/systemd/system/uke-cdc-acm.service ]]
    [[ -L /job/initramfs-root/usr/lib/systemd/system/initrd.target.wants/uke-cdc-shell.service ]]
    [[ -s /job/initramfs-root/usr/lib/systemd/system/uke-cdc-shell.service.d/initrd.conf ]]
    [[ -x /job/initramfs-root/usr/libexec/uke-root-guard ]]
    # g_serial requests ACM dynamically, so its module dependencies omit this function.
    for name in ufs_qcom phy_qcom_qmp_ufs dwc3_qcom phy_msm_snps_eusb2_uke repeater_qti_pmic_eusb2_uke g_serial usb_f_acm u_serial; do
        modinfo -b /job/initramfs-root -k "$release" "$name" >/dev/null
    done
    bash /builder/src/boot-pair/check-initramfs-modules.sh /job/initramfs-root /job/root "$release"
    privacy=()
    if [[ -s /job/inputs/early-firmware.tar ]]; then
        cmp /job/early-firmware.sha256 <(jq -r '"#archive-sha256 "+.archive_sha256, (.files[]|.sha256+"  "+.path)' /builder/configs/firmware/uke-adsp-early.json)
        bash /builder/src/boot-pair/check-early-firmware.sh /job/initramfs-root /job/early-firmware.sha256
        for name in qrtr_smd qcom_pd_mapper; do
            modinfo -b /job/initramfs-root -k "$release" "$name" >/dev/null
        done
        # Dracut processes these synchronous preloads before udev coldplug.
        # Presence alone did not establish readiness in the rejected trial.
        preloads=$(cat /job/initramfs-root/etc/cmdline.d/*.conf | sed -n 's/^rd.driver.pre=//p' | head -2)
        [[ $preloads == $'qrtr_smd\nqcom_pd_mapper' ]]
        # Preserve authenticated vendor blobs; exact hashes admit their OEM build paths only.
        privacy=(--namespace-policy /builder/configs/firmware/uke-adsp-early.json)
    fi
    bash /builder/src/audit/check-target-elf.sh /job/initramfs-root
    bash /builder/src/audit/check-target-privacy.sh "${privacy[@]}" /job/initramfs-root
    for unit in uke-usb-network uke-usb-network-shell; do
        [[ ! -e /job/root/etc/systemd/system/multi-user.target.wants/$unit.service ]]
    done
    for unit in uke-cdc-acm uke-cdc-shell; do
        [[ ! -e /job/root/etc/systemd/system/multi-user.target.wants/$unit.service ]]
    done
    cmp /job/root/usr/share/senemos/boot/uke/usb-network-managed.conf /job/root/etc/NetworkManager/conf.d/90-uke-usb-debug.conf
    cmp /job/root/usr/share/senemos/boot/uke/uke-coresight-bringup.conf /job/root/usr/lib/modprobe.d/uke-coresight-bringup.conf
    root_policy=/builder/configs/images/selinux-namespace-policy.json
    if [[ -s /job/inputs/early-firmware.tar ]]; then
        jq -s '{files:([.[].files[]])}' "$root_policy" /builder/configs/firmware/uke-adsp-early.json > /job/root-privacy-policy.json
        root_policy=/job/root-privacy-policy.json
    fi
    bash /builder/src/audit/check-target-elf.sh /job/root
    bash /builder/src/audit/check-target-privacy.sh --namespace-policy "$root_policy" /job/root
    while IFS= read -r -d '' file; do
        if [[ $(od -An -tx1 -N4 "$file" | tr -d ' \n') == 7f454c46 ]]; then
            if [[ -s /job/inputs/early-firmware.tar ]] && jq -e --arg path "${file#/job/initramfs-root/}" 'any(.files[]; .path==$path)' /builder/configs/firmware/uke-adsp-early.json >/dev/null; then
                continue # The exact DSP payload was checked above; it is not AArch64 userspace.
            fi
            readelf -h "$file" | grep -E 'Machine:.*AArch64' >/dev/null
        fi
    done < <(find /job/initramfs-root -type f -print0)
    ;;
kernel)
    top=/job/kernel/build/fedora-44/7.2.9/rpmbuild
    out=$top/kernel-out
    source=$top/BUILD/senemos-uke-linux-kernel-mainline-7.2.9-build/linux-7.2.9
    cp /job/inputs/base.config "$out/.config"
    export ARCH=arm64 LLVM=1 KBUILD_BUILD_USER=senemos KBUILD_BUILD_HOST=uke-builder
    export KBUILD_BUILD_TIMESTAMP='2026-10-03 10:44:10 UTC' KBUILD_BUILD_VERSION=1 SOURCE_DATE_EPOCH=1791024250
    clang --version > /job/toolchain.txt
    cd "$source"
    scripts/config --file "$out/.config" --set-str INITRAMFS_SOURCE /job/initramfs.cpio.gz \
        --enable INITRAMFS_FORCE --enable CMDLINE_FORCE --disable CMDLINE_FROM_BOOTLOADER \
        --enable QCOM_UKE_ABL_DT --enable GUNYAH_WATCHDOG \
        --set-str CMDLINE "$(jq -r .kernel_command_line "$profile")"
    make O="$out" LOCALVERSION=-senemos-uke olddefconfig
    grep -Fx CONFIG_QCOM_UKE_ABL_DT=y "$out/.config"
    grep -Fx CONFIG_GUNYAH_WATCHDOG=y "$out/.config"
    grep -Fx CONFIG_FRAMEBUFFER_CONSOLE=y "$out/.config"
    grep -Fx '# CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER is not set' "$out/.config"
    # Built-in Gunyah watchdog handles the firmware timer; module bytes and exports still must match.
    bash /builder/src/boot-pair/check-kernel-config.sh /job/inputs/base.config "$out/.config"
    diff -u /job/inputs/base.config "$out/.config" > /job/config-delta.txt || [[ $? == 1 ]]
    make O="$out" LOCALVERSION=-senemos-uke -j"$(cat /job/inputs/jobs)" Image modules dtbs
    [[ $(make -s O="$out" LOCALVERSION=-senemos-uke kernelrelease) == "$release" ]]
    bash /builder/src/boot/vmlinux-exports.sh "$out/Module.symvers" > /job/boot-vmlinux.symvers
    cmp /job/inputs/base-vmlinux.symvers /job/boot-vmlinux.symvers
    # Module-byte equality is stronger than comparing zero CRCs when
    # MODVERSIONS is off. Every freshly built module must match its installed
    # qualified RPM byte for byte; otherwise composition stops for repackaging.
    count=0
    while IFS= read -r module; do
        [[ -n $module ]]
        # Linux 7.2 Kbuild records the module object in modules.order;
        # the installed payload and final linker product use .ko.
        case $module in *.o) module=${module%.o}.ko;; *.ko) :;; *) exit 1;; esac
        installed=/job/root/usr/lib/modules/$release/kernel/$module.zst
        [[ -s $installed && -s $out/$module ]]
        cp "$out/$module" /job/module-compare.ko
        llvm-strip -g /job/module-compare.ko
        zstd -dc "$installed" | cmp - /job/module-compare.ko
        count=$((count + 1))
    done < "$out/modules.order"
    [[ $count == "$(jq -er .module_count /job/inputs/kernel-manifest.json)" ]]
    rm /job/module-compare.ko
    printf '%s\n' "$count" > /job/module-byte-match-count
    cp "$out/.config" /job/boot.config
    cp "$out/arch/arm64/boot/Image" /job/Image
    cp "$out/Module.symvers" /job/Module.symvers
    # Extract the linked initramfs by actual ELF symbol/section addresses.
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
    ;;
compose)
    count=$(cat /job/module-byte-match-count)
    [[ $count == "$(jq -er .module_count /job/inputs/kernel-manifest.json)" ]]
    (cd /job; sha256sum -c pair-root.sha256)
    # Restore numeric owners/capabilities from the ARM64 archive, including
    # when a rootful Docker host needed chown for intermediate job access.
    rm -rf /job/root
    mkdir /job/root
    tar --numeric-owner --same-owner --xattrs --xattrs-include='security.capability' -xf /job/pair-root.tar -C /job/root
    # Resume a failed composition without trusting a partial image. Completed
    # candidates are returned by the host entry before reaching this stage.
    for file in fedora_boot.img roundtrip-Image system.raw.img system.img system.roundtrip.img; do
        [[ ! -e /job/$file ]] || { [[ -f /job/$file && ! -L /job/$file ]]; rm "/job/$file"; }
    done
    rm -rf /job/ext4-readback /job/sparse-fixtures
    root=/job/root
    # Keep RPM-owned vmlinuz/config intact. The stock-ABL entry is a separate
    # built-in-initramfs image, with verified identical module bytes.
    install -Dm644 /job/boot.config "$root/usr/lib/uke-boot-pair/boot.config"
    install -m644 /job/Image "$root/usr/lib/uke-boot-pair/Image"
    install -m644 /job/inputs/profile.json "$root/usr/lib/uke-boot-pair/profile.json"
    g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/src/boot/boot-image.cpp -o /job/boot-image
    bash /builder/tests/boot-image-contract.sh /job/boot-image
    /job/boot-image pack /job/inputs/stock-boot.img /job/Image /job/fedora_boot.img "$(jq -r .boot_partition_bytes "$profile")"
    /job/boot-image inspect /job/fedora_boot.img > /job/boot-header.json
    /job/boot-image extract /job/fedora_boot.img /job/roundtrip-Image
    cmp /job/Image /job/roundtrip-Image
    jq -e '.header_version==4 and .ramdisk_bytes==0 and .signature_bytes==0 and .avb_footer_present==false' /job/boot-header.json >/dev/null
    root_bytes=$(($(jq -r .root_size_mib "$profile") * 1024 * 1024))
    truncate -s "$root_bytes" /job/system.raw.img
    root_uid=$(stat -c %u "$root") root_gid=$(stat -c %g "$root") root_mode=$(stat -c %a "$root")
    [[ $root_uid == 0 && $root_gid =~ ^[0-9]+$ && $root_mode =~ ^[0-7]{3,4}$ ]]
    mkfs.ext4 -q -F -b 4096 -L UKE_LINUX -U "$(jq -r .root_uuid "$profile")" -m 0 \
        -E "lazy_itable_init=0,lazy_journal_init=0,root_owner=$root_uid:$root_gid,root_perms=$root_mode" \
        -d "$root" /job/system.raw.img
    g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/src/image/ext4-labels.cpp -o /job/ext4-labels -lext2fs -lcom_err -lselinux
    contexts=$root/etc/selinux/targeted/contexts/files/file_contexts
    /job/ext4-labels apply /job/system.raw.img "$root" "$contexts"
    /job/ext4-labels verify /job/system.raw.img "$root" "$contexts"
    e2fsck -fn /job/system.raw.img
    g++ -std=c++20 -O2 -Wall -Wextra -Werror /builder/src/boot-pair/android-sparse.cpp -o /job/android-sparse
    bash /builder/tests/android-sparse-contract.sh /job/android-sparse /job/sparse-fixtures
    /job/android-sparse encode /job/system.raw.img /job/system.img
    /job/android-sparse decode /job/system.img /job/system.roundtrip.img
    cmp /job/system.raw.img /job/system.roundtrip.img
    rm /job/system.roundtrip.img
    mkdir /job/ext4-readback
    debugfs -R 'rdump / /job/ext4-readback' /job/system.raw.img
    bash /builder/src/audit/check-target-elf.sh /job/ext4-readback
    bash /builder/src/audit/check-target-privacy.sh --namespace-policy /builder/configs/images/selinux-namespace-policy.json /job/ext4-readback
    cmp "$root/etc/fstab" /job/ext4-readback/etc/fstab
    cmp /job/Image /job/ext4-readback/usr/lib/uke-boot-pair/Image
    cmp /job/initramfs.cpio.gz "/job/ext4-readback/boot/initramfs-$release.img"
    (cd /job; sha256sum fedora_boot.img system.img system.raw.img Image boot.config initramfs.cpio.gz Module.symvers boot-header.json inputs/profile.json installed-rpms.tsv toolchain.txt > SHA256SUMS)
    jq -n --slurpfile profile "$profile" --arg recipe "$(cat /job/inputs/recipe-sha256)" \
        --arg boot "$(sha256sum /job/fedora_boot.img | cut -d ' ' -f1)" \
        --arg system "$(sha256sum /job/system.img | cut -d ' ' -f1)" \
        --arg raw "$(sha256sum /job/system.raw.img | cut -d ' ' -f1)" \
        --argjson modules "$count" --argjson patches "$(jq -er .patch_count "$profile")" \
        '{schema_version:1,status:"host-validated-stock-ABL-pair-candidate",recipe_sha256:$recipe,profile:$profile[0],sha256:{boot:$boot,system:$system,decoded_ext4:$raw},checks:{source_preparation:true,base_patches:$patches,abl_adaptation_patch:1,embedded_initramfs_byte_match:true,module_byte_match:$modules,android_v4_roundtrip:true,full_sparse_logical_coverage:true,sparse_roundtrip:true,all_inode_selinux_labels:true,ext4_readback:true,privacy:true},qemu_tested:false,boot_tested:false,hardware_tested:false,flash_executed:false}' > /job/manifest.json
    (cd /job; sha256sum manifest.json >> SHA256SUMS; sha256sum -c SHA256SUMS)
    ;;
qemu-prepare)
    if [[ -e /job/qemu ]]; then mv /job/qemu "/job/qemu-failed-$(date -u +%Y%m%dT%H%M%SZ)"; fi
    bash /builder/tests/boot-pair-qemu-prepare.sh /job /job/qemu
    ;;
*) exit 2;;
esac
