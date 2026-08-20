#!/usr/bin/env bash
# ================================================================
# GKI 内核本地编译工具 - 功能模块
# 处理: KernelSU, ZRAM, Re-Kernel, Droidspaces 等
# ================================================================

# --- 从原始 build.yml 适配而来 ---

# 应用 KernelSU
apply_kernelsu() {
    local kernel_root="$1"
    local ksu_variant="$2"       # Official / ReSukiSU / None
    local ksu_branch="$3"        # Stable(标准) / Dev(开发)

    [ "$ksu_variant" = "None" ] && return 0

    log_step "$(txt "集成 KernelSU" "Integrate KernelSU") ($ksu_variant)"

    # 确定分支参数
    local branch_flag=""
    case "$ksu_variant" in
        ReSukiSU)
            branch_flag="-s main"
            ;;
        *)
            case "$ksu_branch" in
                "Stable(标准)"|"Stable(stable)"|"Stable")
                    case "$ksu_variant" in
                        Official) branch_flag="-s main" ;;
                        *)        branch_flag="-" ;;
                    esac
                    ;;
                "Dev(开发)"|"Dev(development)"|"Dev")
                    case "$ksu_variant" in
                        Official) branch_flag="-s main" ;;
                    esac
                    ;;
            esac
            ;;
    esac

    cd "$kernel_root"

    # 设置 Git 镜像，确保 KernelSU setup.sh 内部的 git clone 也走镜像
    load_mirror_config
    local git_cfg=""
    if [ "${use_custom_mirror:-false}" = "true" ] && [ -n "${CUSTOM_GITHUB_MIRROR:-}" ]; then
        git_cfg="$PROJECT_ROOT/config/.gitconfig_mirror"
        cat > "$git_cfg" << EOF
[url "${CUSTOM_GITHUB_MIRROR}https://github.com/"]
    insteadOf = https://github.com/
EOF
        export GIT_CONFIG_GLOBAL="$git_cfg"
    fi

    case "$ksu_variant" in
        Official)
            log_info "$(txt "集成 KernelSU 官方版..." "Integrating official KernelSU...")"
            curl -LSs "$(mirror_github "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh")" | bash $branch_flag || {
                log_error "$(txt "KernelSU 官方版 setup.sh 执行失败" "Official KernelSU setup.sh failed")"
                return 1
            }
            ;;
        ReSukiSU)
            log_info "$(txt "集成 ReSukiSU..." "Integrating ReSukiSU...")"
            curl -LSs "$(mirror_github "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh")" | bash $branch_flag || {
                log_error "$(txt "ReSukiSU setup.sh 执行失败" "ReSukiSU setup.sh failed")"
                return 1
            }
            ;;
        *)
            log_error "$(txt "未知 KernelSU 变体" "Unknown KernelSU variant"): $ksu_variant"
            return 1
            ;;
    esac

    # 清理 Git 镜像配置
    [ -n "$git_cfg" ] && rm -f "$git_cfg"
    unset GIT_CONFIG_GLOBAL

    # 修复 KernelSU setup.sh 可能产生的递归符号链接
    for dir in "." "common/drivers/kernelsu"; do
        [ -d "$dir" ] && find "$dir" -maxdepth 3 -type l -name kernel -exec sh -c '
            t=$(readlink -f "$1" 2>/dev/null) || { rm -f "$1"; exit 0; }
            # 检测自引用: 如果目标路径包含自身则删除
            case "$t" in
                *"$1"*) rm -f "$1" ;;
            esac
        ' _ {} \; 2>/dev/null || true
    done

    # 计算并保存 KSU 版本号 (所有变体)
    if [ -d "KernelSU/.git" ]; then
        local ksu_git_ver=$(git -C KernelSU rev-list --count HEAD)
        local ksu_ver
        case "$ksu_variant" in
            Official) ksu_ver=$((20000 + ksu_git_ver)) ;;
            ReSukiSU) ksu_ver=$((30700 + ksu_git_ver)) ;;
        esac
        echo "$ksu_ver" > "KernelSU/.ksu_version"
        log_info "$(txt "KernelSU 版本" "KernelSU version"): $ksu_ver"
        echo "KSU_VERSION=$ksu_ver"

        # Official 需要更新 Kbuild 中的版本号
        if [ "$ksu_variant" = "Official" ] && [ -f "KernelSU/kernel/Kbuild" ]; then
            sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${ksu_ver}/" KernelSU/kernel/Kbuild
        fi
    fi

    if [ -d "KernelSU/.git" ]; then
        local ksu_date=$(git -C KernelSU log -1 --date=format:'%Y-%m-%d %H:%M:%S %z' --format='%cd')
        log_info "$(txt "KernelSU 最新提交日期" "KernelSU latest commit date"): $ksu_date"
    fi

    log_info "$(txt "KernelSU 集成完成" "KernelSU integration completed")"
}

# 应用 ZRAM LZ4 增强
apply_zram() {
    local kernel_root="$1"
    local kernel_ver="$2"
    local sukisu_patches="$3"
    local zzh_patches="$PROJECT_ROOT"

    log_step "$(txt "集成 ZRAM LZ4 增强算法" "Integrate ZRAM LZ4 enhancement")"

    local common_dir="$kernel_root/common"
    cd "$common_dir"

    log_info "$(txt "升级 LZ4 模块..." "Updating LZ4 module...")"
    rm -f lib/lz4/lz4_compress.c lib/lz4/lz4_decompress.c lib/lz4/lz4defs.h lib/lz4/lz4hc_compress.c

    cp -r "$zzh_patches/zram/lz4/"* ./lib/lz4/ 2>/dev/null || true
    cp -r "$zzh_patches/zram/include/linux/"* ./include/linux/ 2>/dev/null || true
    bash "$zzh_patches/zram/apply_lz4_neon.sh" 2>/dev/null || true

    if [ -f "fs/f2fs/Makefile" ] && ! grep -qF "f2fs-\$(CONFIG_F2FS_IOSTAT) += iostat.o" "fs/f2fs/Makefile"; then
        echo "f2fs-\$(CONFIG_F2FS_IOSTAT) += iostat.o" >> "fs/f2fs/Makefile"
    fi

    if [ -d "$sukisu_patches" ]; then
        cp -r "$sukisu_patches/other/zram/lz4k/include/linux/"* ./include/linux/ 2>/dev/null || true
        cp -r "$sukisu_patches/other/zram/lz4k/lib/"* ./lib/ 2>/dev/null || true
        cp -r "$sukisu_patches/other/zram/lz4k/crypto/"* ./crypto/ 2>/dev/null || true
        cp -r "$sukisu_patches/other/zram/lz4k_oplus" ./lib/ 2>/dev/null || true

        if [ -f "$sukisu_patches/other/zram/zram_patch/${kernel_ver}/lz4kd.patch" ]; then
            patch -p1 -F 3 -N < "$sukisu_patches/other/zram/zram_patch/${kernel_ver}/lz4kd.patch" || true
        fi
        if [ -f "$sukisu_patches/other/zram/zram_patch/${kernel_ver}/lz4k_oplus.patch" ]; then
            patch -p1 -F 3 -N < "$sukisu_patches/other/zram/zram_patch/${kernel_ver}/lz4k_oplus.patch" || true
        fi
    fi

    log_info "$(txt "ZRAM 增强集成完成" "ZRAM enhancement integration completed")"
}


# 应用 Re-Kernel 驱动
apply_rekernel() {
    local kernel_root="$1"
    local kernel_ver="$2"

    log_step "$(txt "集成 Re-Kernel 驱动" "Integrate Re-Kernel driver")"

    local tmp_rekernel="/tmp/rekernel"
    rm -rf "$tmp_rekernel"
    git_clone "https://github.com/Sakion-Team/Re-Kernel.git" "$tmp_rekernel" --depth 1 || {
        log_error "$(txt "Re-Kernel 仓库克隆失败" "Failed to clone Re-Kernel repository")"
        return 1
    }

    local common_dir="$kernel_root/common"
    local drv_dir="$common_dir/drivers/rekernel"
    mkdir -p "$drv_dir"

    cp "$tmp_rekernel/LKM-Source/rekernel.c" "$drv_dir/"
    cp "$tmp_rekernel/LKM-Source/rekernel.h" "$drv_dir/"

    cat > "$drv_dir/Kconfig" << 'KCONFIG_EOF'
menu "Re:Kernel"
config REKERNEL
    bool "Re:Kernel support (GKI Vendor Hooks)"
    default y
    help
      Enable Re-Kernel support via GKI Vendor Hooks.
config REKERNEL_NETWORK
    bool "Re:Kernel NetReceive unfreeze support"
    depends on REKERNEL
    default n
endmenu
KCONFIG_EOF

    cat > "$drv_dir/Makefile" << 'MAKEFILE_EOF'
obj-$(CONFIG_REKERNEL) += rekernel.o
ccflags-$(CONFIG_REKERNEL_NETWORK) += -DNETWORK_FILTER
MAKEFILE_EOF

    # 挂载到驱动树
    if ! grep -qF 'source "drivers/rekernel/Kconfig"' "$common_dir/drivers/Kconfig"; then
        sed -i '/^endmenu$/i source "drivers/rekernel/Kconfig"' "$common_dir/drivers/Kconfig"
    fi
    if ! grep -qF 'obj-$(CONFIG_REKERNEL) += rekernel/' "$common_dir/drivers/Makefile"; then
        echo 'obj-$(CONFIG_REKERNEL) += rekernel/' >> "$common_dir/drivers/Makefile"
    fi

    # 启用内核版本宏
    local ver_macro="KERNEL_$(echo "$kernel_ver" | tr '.' '_')"
    if grep -q "^// #define ${ver_macro}$" "$drv_dir/rekernel.h"; then
        sed -i "s|^// #define ${ver_macro}$|#define ${ver_macro}|" "$drv_dir/rekernel.h"
    fi

    # 修正 include 路径
    sed -i 's|#include <../android/binder_internal.h>|#include "../../drivers/android/binder_internal.h"|g' "$drv_dir/rekernel.c"
    grep -qF '#include <linux/seq_file.h>' "$drv_dir/rekernel.c" || \
        sed -i '/#include <trace\/hooks\/signal.h>/a #include <linux/seq_file.h>' "$drv_dir/rekernel.c"

    local defconfig="$common_dir/arch/arm64/configs/gki_defconfig"
    grep -q '^CONFIG_REKERNEL=y$' "$defconfig" || echo "CONFIG_REKERNEL=y" >> "$defconfig"
    grep -q '^CONFIG_REKERNEL_NETWORK=y$' "$defconfig" || echo "CONFIG_REKERNEL_NETWORK=y" >> "$defconfig"

    rm -rf "$tmp_rekernel"
    log_info "$(txt "Re-Kernel 集成完成" "Re-Kernel integration completed")"
}

# 应用 CVE-2026-43499 / CVE-2026-53163 rtmutex 修复链
apply_cve_2026_43499() {
    local kernel_root="$1"
    local kernel_ver="$2"
    local actual_sub="$3"

    log_step "$(txt "应用 CVE-2026-43499 rtmutex 修复链" "Apply CVE-2026-43499 rtmutex fix chain")"

    local patch_dir="$PROJECT_ROOT/security_patch"
    local script="$patch_dir/apply_cve_2026_43499.sh"
    local common_dir="$kernel_root/common"
    [ -d "$common_dir" ] || common_dir="$kernel_root"

    if [ ! -f "$script" ]; then
        log_error "$(txt "未找到 CVE 修复脚本" "CVE fix script not found"): $script"
        return 1
    fi
    if [ ! -f "$common_dir/kernel/locking/rtmutex.c" ]; then
        log_error "$(txt "未找到 rtmutex.c" "rtmutex.c not found"): $common_dir/kernel/locking/rtmutex.c"
        return 1
    fi

    (cd "$common_dir" && bash "$script" "$kernel_ver" "$actual_sub" "$patch_dir") || {
        log_error "$(txt "CVE-2026-43499 rtmutex 修复链应用失败" "Failed to apply CVE-2026-43499 rtmutex fix chain")"
        return 1
    }

    log_info "$(txt "CVE-2026-43499 rtmutex 修复链处理完成" "CVE-2026-43499 rtmutex fix chain completed")"
}

# 应用 Droidspaces 容器支持
apply_droidspaces() {
    local kernel_root="$1"
    local android_ver="$2"
    local kernel_ver="$3"
    local slot="$4"       # off / 678 / 123 / 345
    local defconfig="$5"

    [ "$slot" = "off" ] && return 0

    log_step "$(txt "集成 Droidspaces 容器支持" "Integrate Droidspaces container support") ($(txt "槽位" "slot"): $slot)"

    local tmp_ds="/tmp/Droidspaces-OSS"
    git_clone "https://github.com/ravindu644/Droidspaces-OSS.git" "$tmp_ds" --depth 1 || {
        log_error "$(txt "克隆 Droidspaces 仓库失败，终止编译" "Failed to clone Droidspaces repository; aborting build")"
        return 1
    }

    local patch_dir="$tmp_ds/Documentation/resources/kernel-patches/GKI"
    local common_dir="$kernel_root/common"
    cd "$common_dir"

    # SYSVIPC kABI 修复
    local slot_name=$(echo "$slot" | sed 's/\(.\)/\1_/g; s/_$//')
    local patch_file=""
    case "$kernel_ver" in
        6.12|6.18) patch_file="$patch_dir/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch" ;;
        5.10|5.15|6.1|6.6) patch_file="$patch_dir/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_${slot_name}.patch" ;;
    esac
    [ -f "$patch_file" ] && patch -p1 --forward < "$patch_file" || true

    # 5.10 POSIX_MQUEUE 修复
    if [ "$kernel_ver" = "5.10" ]; then
        local posix_patch="$patch_dir/below-kernel-6.12/002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch"
        [ -f "$posix_patch" ] && patch -p1 --forward < "$posix_patch" || true
    fi

    # Android 16+ / 6.12+ IPC_NS 符号导出
    if [ "$kernel_ver" = "6.12" ] || [ "$kernel_ver" = "6.18" ]; then
        grep -qF 'EXPORT_SYMBOL(init_ipc_ns);' ipc/msgutil.c || \
            sed -i '/^struct msg_msgseg {/i EXPORT_SYMBOL(init_ipc_ns);' ipc/msgutil.c
        grep -qF 'EXPORT_SYMBOL(put_ipc_ns);' ipc/namespace.c || \
            sed -i '/^static struct ns_common \*ipcns_get(/i EXPORT_SYMBOL(put_ipc_ns);' ipc/namespace.c
    fi

    # 配置内核选项
    enable_config() {
        local cfg="$1"
        if grep -q "^${cfg}=y" "$defconfig"; then
            : # 已启用
        elif grep -q "^# ${cfg} is not set" "$defconfig"; then
            sed -i "s/^# ${cfg} is not set$/${cfg}=y/" "$defconfig"
        else
            echo "${cfg}=y" >> "$defconfig"
        fi
    }

    enable_config CONFIG_SYSVIPC
    enable_config CONFIG_POSIX_MQUEUE
    enable_config CONFIG_IPC_NS
    enable_config CONFIG_PID_NS
    enable_config CONFIG_USER_NS
    enable_config CONFIG_DEVTMPFS

    for cfg in CONFIG_NETFILTER_XT_MATCH_ADDRTYPE CONFIG_NETFILTER_XT_TARGET_LOG \
               CONFIG_NETFILTER_XT_MATCH_RECENT CONFIG_IP_SET CONFIG_IP_SET_HASH_IP \
               CONFIG_IP_SET_HASH_NET CONFIG_NETFILTER_XT_SET; do
        if grep -RqsE --include='Kconfig*' "^[[:space:]]*(menuconfig|config)[[:space:]]+${cfg#CONFIG_}$" .; then
            enable_config "$cfg"
        fi
    done

    rm -rf "$tmp_ds"
    log_info "$(txt "Droidspaces 集成完成" "Droidspaces integration completed")"
}

# 添加NTsync
apply_ntsync() {

    local kernel_root="$1"
    local android_ver="$2"
    local kernel_ver="$3"
    local defconfig="$4"

    log_step "$(txt "集成NTsync支持" "Integrate NTsync support")"

    # 克隆NTsync补丁仓库
    local tmp_ntsync="/tmp/ntsync"
    git_clone "https://github.com/404-GCross/Droidspaces_Kernel_patch.git" "$tmp_ntsync" --depth 1 || {
        log_warn "$(txt "克隆 Droidspaces_Kernel_patch 仓库失败，跳过" "Failed to clone Droidspaces_Kernel_patch repository; skipping")"
        return 0
    }

    local patch_dir="$tmp_ntsync/NTsync"
    local common_dir="$kernel_root/common"
    cd "$common_dir"

    # 打上NTsync补丁
    patch -p1 --forward < "$patch_dir/ntsync_base.patch" || true
    local patch_file=""
    case "$kernel_ver" in
        6.18) patch_file="$patch_dir/ntsync_compat_android17-6.18.patch" ;;
        6.12) patch_file="$patch_dir/ntsync_compat_android16-6.12.patch" ;;
        6.6)  patch_file="$patch_dir/ntsync_compat_android15-6.6.patch" ;;
        6.1)  patch_file="$patch_dir/ntsync_compat_android14-6.1.patch" ;;
        5.15) patch_file="$patch_dir/ntsync_compat_android13-5.15.patch" ;;
        5.10) patch_file="$patch_dir/ntsync_compat_android12-5.10.patch" ;;
    esac
    [ -f "$patch_file" ] && patch -p1 --forward < "$patch_file" || true

    # 启用 NTsync 内核配置
    if grep -q "^CONFIG_NTSYNC=y" "$defconfig"; then
        : # 已启用
    elif grep -q "^# CONFIG_NTSYNC is not set" "$defconfig"; then
        sed -i "s/^# CONFIG_NTSYNC is not set/CONFIG_NTSYNC=y/" "$defconfig"
    else
        echo "CONFIG_NTSYNC=y" >> "$defconfig"
    fi

    rm -rf "$tmp_ntsync"
    log_info "$(txt "NTsync 集成完成" "NTsync integration completed")"
}
