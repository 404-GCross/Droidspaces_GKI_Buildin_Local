#!/usr/bin/env bash
# ================================================================
# GKI 内核本地编译工具 - 核心构建流程
# 从 .github/workflows/build.yml 适配而来
# ================================================================

# --- 全局编译配置 ---
declare -A BUILD_CFG
BUILD_CFG[android_version]=""
BUILD_CFG[kernel_version]=""
BUILD_CFG[sub_level]=""
BUILD_CFG[os_patch_level]=""
BUILD_CFG[revision]=""
BUILD_CFG[ksu_variant]="None"
BUILD_CFG[ksu_branch]="Stable(标准)"
BUILD_CFG[custom_version]=""
BUILD_CFG[build_time]=""
BUILD_CFG[use_zram]="false"
BUILD_CFG[use_kpm]="disabled"
BUILD_CFG[use_rekernel]="false"
BUILD_CFG[cve_2026_43499_patch]="false"
BUILD_CFG[droidspaces]="off"
BUILD_CFG[kernel_source]=""
BUILD_CFG[output_dir]=""
BUILD_CFG[package_boot]="true"
run_build() {
    log_step "$(txt "开始内核构建" "Start kernel build")"

    local android_ver="${BUILD_CFG[android_version]}"
    local kernel_ver="${BUILD_CFG[kernel_version]}"
    local sub_level="${BUILD_CFG[sub_level]}"
    local os_patch="${BUILD_CFG[os_patch_level]}"
    local ksu_variant="${BUILD_CFG[ksu_variant]}"
    local ksu_branch="${BUILD_CFG[ksu_branch]}"
    local use_zram="${BUILD_CFG[use_zram]}"
    local use_kpm="${BUILD_CFG[use_kpm]}"
    local use_rekernel="${BUILD_CFG[use_rekernel]}"
    local cve_patch="${BUILD_CFG[cve_2026_43499_patch]:-false}"
    local droidspaces="${BUILD_CFG[droidspaces]}"
    local kernel_source="${BUILD_CFG[kernel_source]}"
    local custom_version="${BUILD_CFG[custom_version]}"
    local build_time="${BUILD_CFG[build_time]}"

    local package_boot="${BUILD_CFG[package_boot]:-true}"

    local config_id="${android_ver}-${kernel_ver}-${sub_level}"

    if [ "$kernel_ver" = "6.12" ] && [ "$use_zram" = "true" ]; then
        log_warn "$(txt "参考项目在 6.12 构建中禁用 ZRAM 增强，已自动关闭" "The reference project disables ZRAM enhancement for 6.12 builds; it has been turned off automatically")"
        use_zram="false"
        BUILD_CFG[use_zram]="false"
    fi

    # ==================== 构建目录 ====================
    local build_dir="${BUILD_CFG[output_dir]:-$PROJECT_ROOT/build/$config_id}"
    mkdir -p "$build_dir"
    log_info "$(txt "构建目录" "Build directory"): $build_dir"

    # 清理旧编译产物
    rm -f "$build_dir"/*.zip "$build_dir"/Image "$build_dir"/Image.* 2>/dev/null || true

    # ==================== 准备内核源码 ====================
    if [ -n "$kernel_source" ] && [ -d "$kernel_source" ]; then
        log_info "$(txt "使用本地内核源码" "Using local kernel source"): $kernel_source"

        # 检查是否是完整的内核源码目录
        if [ -d "$kernel_source/common" ]; then
            # 已经是 GKI repo 结构
            local kernel_root="$build_dir/kernel"
            mkdir -p "$kernel_root"
            log_info "$(txt "检测到 GKI repo 结构，创建符号链接..." "Detected GKI repo layout; creating symlink...")"
            ln -sf "$kernel_source" "$kernel_root"
            kernel_root="$kernel_source"
        elif [ -f "$kernel_source/Makefile" ]; then
            # 单一内核源码树
            local kernel_root="$kernel_source"
        else
            log_error "$(txt "无效的内核源码目录" "Invalid kernel source directory"): $kernel_source ($(txt "未找到 Makefile 或 common/ 目录" "Makefile or common/ was not found"))"
            return 1
        fi
    else
        log_error "$(txt "请先指定本地内核源码路径!" "Please specify the local kernel source path first!")"
        return 1
    fi

    # ==================== 环境变量 ====================
    local common_dir="$kernel_root/common"
    [ -d "$common_dir" ] || common_dir="$kernel_root"

    local defconfig="${common_dir}/arch/arm64/configs/gki_defconfig"
    if [ ! -f "$defconfig" ]; then
        log_error "$(txt "未找到 gki_defconfig" "gki_defconfig not found"): $defconfig"
        log_info "$(txt "请确认内核源码路径正确，且包含 GKI defconfig" "Confirm the kernel source path is correct and contains the GKI defconfig")"
        return 1
    fi

    # ==================== 打印构建摘要 ====================
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}       $(txt "内核构建配置摘要" "Kernel Build Configuration Summary")${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "$(txt "Android 版本" "Android version")  : ${GREEN}$android_ver${NC}"
    echo -e "$(txt "内核版本" "Kernel version")      : ${GREEN}$kernel_ver${NC}"
    echo -e "$(txt "子版本号" "Sublevel")      : ${GREEN}$sub_level${NC}"
    echo -e "$(txt "补丁级别" "Patch level")      : ${GREEN}$os_patch${NC}"
    echo -e "$(txt "KSU 变体" "KSU variant")      : ${GREEN}$ksu_variant${NC}"
    echo -e "$(txt "KSU 分支" "KSU branch")      : ${GREEN}$(display_ksu_branch "$ksu_branch")${NC}"
    echo -e "$(txt "ZRAM 增强" "ZRAM enhancement")     : ${GREEN}$(status_bool "$use_zram")${NC}"
    echo -e "$(txt "KPM 功能" "KPM feature")      : ${GREEN}$(display_kpm "$use_kpm")${NC}"
    echo -e "Re-Kernel     : ${GREEN}$(status_bool "$use_rekernel")${NC}"
    echo -e "$(txt "CVE 修复链" "CVE fix chain")    : ${GREEN}$(status_bool "$cve_patch")${NC}"
    echo -e "Droidspaces   : ${GREEN}$droidspaces${NC}"
    echo -e "$(txt "内核源码" "Kernel source")      : ${GREEN}$kernel_source${NC}"
    echo -e "$(txt "构建目录" "Build directory")      : ${GREEN}$build_dir${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    if ! confirm "$(txt "是否继续编译?" "Continue building?")" "y"; then
        log_info "$(txt "用户取消编译" "Build cancelled by user")"
        return 0
    fi

    # ==================== 克隆依赖仓库 ====================
    log_step "$(txt "准备依赖仓库" "Prepare dependency repositories")"
    cd "$build_dir"

    local anykernel_dir="$build_dir/AnyKernel3"

    # AnyKernel3
    if [ ! -d "$anykernel_dir" ]; then
        git_clone "https://github.com/404-GCross/AnyKernel3.git" "$anykernel_dir" -b "gki-2.0" || {
            log_error "$(txt "AnyKernel3 克隆失败，终止编译" "Failed to clone AnyKernel3; aborting build")"
            return 1
        }
        rm -rf "$anykernel_dir/.git" 2>/dev/null || true
    fi

    # ==================== 在 build 目录中准备内核源码工作副本 ====================
    local work_kernel="$kernel_source"

    # ==================== 备份 defconfig ====================
    cp "$defconfig" "$defconfig.orig"

    # ==================== 提取实际子版本号 ====================
    local actual_sub="$sub_level"
    if [ -f "$common_dir/Makefile" ]; then
        local extracted=$(grep '^SUBLEVEL = ' "$common_dir/Makefile" | awk '{print $3}' || true)
        [ -n "$extracted" ] && actual_sub="$extracted"
    fi
    log_info "$(txt "实际子版本号" "Actual sublevel"): $actual_sub"

    local current_sub="$actual_sub"
    [[ ! "$current_sub" =~ ^[0-9]+$ ]] && current_sub=99999

    # ==================== CVE-2026-43499 rtmutex 修复链 ====================
    if [ "$cve_patch" = "true" ]; then
        apply_cve_2026_43499 "$work_kernel" "$kernel_ver" "$actual_sub" || return 1
    fi

    # ==================== 修复 glibc 2.38 兼容性 ====================

    local needs_fix=false
    if [ "$android_ver" = "android13" ] && [ "$kernel_ver" = "5.10" ] && [ "$current_sub" -le 186 ]; then needs_fix=true; fi
    if [ "$android_ver" = "android13" ] && [ "$kernel_ver" = "5.15" ] && [ "$current_sub" -le 119 ]; then needs_fix=true; fi
    if [ "$android_ver" = "android14" ] && [ "$kernel_ver" = "6.1" ] && [ "$current_sub" -le 43 ]; then needs_fix=true; fi

    if [ "$needs_fix" = true ]; then
        local glibc_ver=$(ldd --version 2>/dev/null | head -n 1 | awk '{print $NF}')
        if [ "$(printf '%s\n' "2.38" "$glibc_ver" | sort -V | head -n1)" = "2.38" ]; then
            log_info "$(txt "应用 glibc 2.38 兼容性修复..." "Applying glibc 2.38 compatibility fix...")"
            cd "$common_dir"
            sed -i '/\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))\/ \$(abspath \$@)/s//$(Q)$(MAKE) -C $(SUBCMD_SRC) EXTRA_CFLAGS="$(CFLAGS)" OUTPUT=$(abspath $(dir $@))\/ $(abspath $@)/' tools/bpf/resolve_btfids/Makefile 2>/dev/null || true

            if [ "$kernel_ver" = "5.10" ] || [ "$kernel_ver" = "5.15" ]; then
                sed -i '/char \*buf = NULL;/a int i;' tools/lib/subcmd/parse-options.c 2>/dev/null || true
                sed -i 's/for (int i = 0; subcommands\[i\]; i++) {/for (i = 0; subcommands[i]; i++) {/' tools/lib/subcmd/parse-options.c 2>/dev/null || true
                sed -i '/if (subcommands) {/a int i;' tools/lib/subcmd/parse-options.c 2>/dev/null || true
                sed -i 's/for (int i = 0; subcommands\[i\]; i++)/for (i = 0; subcommands[i]; i++)/' tools/lib/subcmd/parse-options.c 2>/dev/null || true
            fi
            cd "$build_dir"
        fi
    fi

    # ==================== 应用 KernelSU ====================
    if [ "$ksu_variant" = "None" ]; then
        log_info "$(txt "跳过 KernelSU (纯GKI内核)" "Skipping KernelSU (pure GKI kernel)")"
    else
        cd "$work_kernel"
        apply_kernelsu "$work_kernel" "$ksu_variant" "$ksu_branch"
    fi

    # ==================== 应用功能补丁 ====================
    cd "$work_kernel"

    # ZRAM
    if [ "$use_zram" = "true" ]; then
        local sukisu_patches="$build_dir/SukiSU_patch"
        [ ! -d "$sukisu_patches" ] && git_clone "https://github.com/ShirkNeko/SukiSU_patch.git" "$sukisu_patches" || true
        apply_zram "$work_kernel" "$kernel_ver" "$sukisu_patches"
    fi

    # Re-Kernel
    if [ "$use_rekernel" = "true" ]; then
        apply_rekernel "$work_kernel" "$kernel_ver"
    fi

    # Droidspaces
    if [ "$droidspaces" != "off" ]; then
        apply_droidspaces "$work_kernel" "$android_ver" "$kernel_ver" "$droidspaces" "$defconfig" || return 1
    fi

    # NTsync
    apply_ntsync "$work_kernel" "$android_ver" "$kernel_ver" "$defconfig"

    # ==================== 配置内核选项 ====================
    log_step "$(txt "配置内核选项" "Configure kernel options")"
    cd "$work_kernel"

    if [ "$ksu_variant" != "None" ]; then
        cat >> "$defconfig" << 'EOF'
CONFIG_KSU=y
EOF
    fi
    cat >> "$defconfig" << 'EOF'
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
EOF

    # 6.12 内核需要 Rust 支持
    if [ "$kernel_ver" = "6.12" ]; then
        cat >> "$defconfig" << 'EOF'
CONFIG_RUST=y
CONFIG_ANDROID_BINDER_IPC_RUST=m
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_HEADERS_INSTALL=n
CONFIG_MODULE_SIG=n
EOF
    fi

    # KPM 配置 — 仅 KernelSU 变体可用
    if [ "$ksu_variant" = "ReSukiSU" ]; then
        if [[ "$use_kpm" == enabled* ]] || [[ "$use_kpm" == patched* ]]; then
            if grep -RqsE '^[[:space:]]*config[[:space:]]+KPM([[:space:]]|$)' "$common_dir" "KernelSU" 2>/dev/null; then
                echo "CONFIG_KPM=y" >> "$defconfig"
                log_info "$(txt "已启用 KPM" "KPM enabled")"
            else
                log_warn "$(txt "当前 KernelSU 代码未定义 CONFIG_KPM，跳过" "Current KernelSU source does not define CONFIG_KPM; skipping")"
            fi
        fi
    fi

    # ReSukiSU + 特定版本 KALLSYMS 修复
    if [ "$ksu_variant" = "ReSukiSU" ] && [ "$android_ver" = "android13" ] && [ "$kernel_ver" = "5.15" ] \
        && [ "$current_sub" -ge 74 ] && [ "$current_sub" -le 137 ]; then
        echo "CONFIG_KALLSYMS=y" >> "$defconfig"
        echo "CONFIG_KALLSYMS_ALL=y" >> "$defconfig"
        local kallsyms="$common_dir/kernel/kallsyms.c"
        if [ -f "$kallsyms" ] \
            && grep -qF 'int kallsyms_on_each_symbol' "$kallsyms" \
            && grep -qF '#endif /* CONFIG_LIVEPATCH */' "$kallsyms"; then
            sed -i '/^#ifdef CONFIG_LIVEPATCH$/,/^int kallsyms_on_each_symbol/ { /^#ifdef CONFIG_LIVEPATCH$/d }' "$kallsyms"
            sed -i '/^int kallsyms_on_each_symbol/,/^#endif \/\* CONFIG_LIVEPATCH \*\// { /^#endif \/\* CONFIG_LIVEPATCH \*\//d }' "$kallsyms"
        fi
    fi

    [ -f "$common_dir/build.config.gki" ] && sed -i 's/check_defconfig//' "$common_dir/build.config.gki" || true

    # ZRAM 配置
    if [ "$use_zram" = "true" ]; then
        if [ "$kernel_ver" = "5.10" ]; then
            cat >> "$defconfig" << 'EOF'
CONFIG_ZSMALLOC=y
CONFIG_ZRAM=y
CONFIG_MODULE_SIG=n
CONFIG_CRYPTO_LZO=y
CONFIG_ZRAM_DEF_COMP_LZ4KD=y
EOF
        fi

        if [ "$kernel_ver" != "6.6" ] && [ "$kernel_ver" != "5.10" ]; then
            grep -q "CONFIG_ZSMALLOC" "$defconfig" && sed -i 's/CONFIG_ZSMALLOC=m/CONFIG_ZSMALLOC=y/g' "$defconfig" || echo "CONFIG_ZSMALLOC=y" >> "$defconfig"
            sed -i 's/CONFIG_ZRAM=m/CONFIG_ZRAM=y/g' "$defconfig"
        fi

        if [ "$kernel_ver" = "6.6" ]; then
            echo "CONFIG_ZSMALLOC=y" >> "$defconfig"
            sed -i 's/CONFIG_ZRAM=m/CONFIG_ZRAM=y/g' "$defconfig"
        fi

        if [ "$android_ver" = "android14" ] || [ "$android_ver" = "android15" ]; then
            sed -i 's/"drivers\/block\/zram\/zram\.ko",//g; s/"mm\/zsmalloc\.ko",//g' "$common_dir/modules.bzl"
        fi

        if grep -q "CONFIG_ZSMALLOC=y" "$defconfig" && grep -q "CONFIG_ZRAM=y" "$defconfig"; then
            # 验证 LZ4K 补丁是否成功应用到内核源码（Kconfig 中存在对应配置项）
            if grep -Rqs 'config CRYPTO_LZ4K' "$common_dir"; then
                cat "$PROJECT_ROOT/config/zram.config" >> "$defconfig"
            else
                log_warn "$(txt "ZRAM LZ4K 补丁未成功应用，跳过增强配置（内核版本可能不兼容）" "ZRAM LZ4K patch was not applied successfully; skipping enhanced config (kernel version may be incompatible)")"
            fi
        fi
    fi

    # ==================== 配置内核名称 ====================
    log_step "$(txt "配置内核版本名称" "Configure kernel version name")"

    cd "$work_kernel"
    if [ -f "build/build.sh" ]; then
        sed -i 's/-dirty//' "$common_dir/scripts/setlocalversion"
    else
        sed -i '/^[[:space:]]*"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' "$common_dir/BUILD.bazel"
        sed -i '/kmi_symbol_list_strict_mode/d' "$common_dir/BUILD.bazel"
        rm -rf "$common_dir/android/abi_gki_protected_exports_"*
        sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" "$build_dir/build/kernel/kleaf/impl/stamp.bzl" 2>/dev/null || true
    fi

    if [ -n "$custom_version" ]; then
        local clean_ver=$(echo "$custom_version" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+//')
        # 转义 Perl 双引号上下文中的特殊字符 (@ → 数组, $ → 变量)
        local perl_ver=$(echo "$clean_ver" | sed 's/@/\\@/g; s/\$/\\$/g')
        perl -i -0777 -pe 's/(.*)echo "\$\{KERNELVERSION\}\$\{file_localversion\}\$\{config_localversion\}\$\{LOCALVERSION\}\$\{scm_version\}"/$1echo "\$\{KERNELVERSION\}'"${perl_ver}"'"/s' "$common_dir/scripts/setlocalversion" 2>/dev/null || true
        sed -i "\$s|echo \"\$res\"|echo \"${clean_ver}\"|" "$common_dir/scripts/setlocalversion" 2>/dev/null || true
        sed -i '/^CONFIG_LOCALVERSION=/ s/="\([^"]*\)"/="'"$clean_ver"'"/' "$common_dir/arch/arm64/configs/gki_defconfig"
    fi

    # ==================== 设置构建时间 ====================
    if [ -n "$build_time" ] && [ "$build_time" != "N" ] && [ "$build_time" != "n" ]; then
        export KBUILD_BUILD_TIMESTAMP="$build_time"
    else
        export KBUILD_BUILD_TIMESTAMP="$(TZ='UTC' date +'%a %b %d %T %Z %Y')"
    fi
    export KBUILD_BUILD_VERSION=1
    log_info "$(txt "构建时间" "Build timestamp"): $KBUILD_BUILD_TIMESTAMP"

    # mkcompile_h 补丁
    local mkcompile="$common_dir/scripts/mkcompile_h"
    if [ -f "$mkcompile" ]; then
        if [ "$kernel_ver" = "5.10" ] || [ "$kernel_ver" = "5.15" ]; then
            perl -pi -e "s{UTS_VERSION=\"\\\$\(echo \\\$UTS_VERSION \\\$CONFIG_FLAGS \\\$TIMESTAMP \\| cut -b -\\\$UTS_LEN\)\"}{UTS_VERSION=\"#1 SMP PREEMPT $KBUILD_BUILD_TIMESTAMP\"}" "$mkcompile"
        else
            if grep -q 'UTS_VERSION=' "$mkcompile"; then
                perl -pi -e "s{UTS_VERSION=\"\\\$\\\(.*?\\\)\"}{UTS_VERSION=\"#1 SMP PREEMPT $KBUILD_BUILD_TIMESTAMP\"}" "$mkcompile"
            else
                perl -0777 -pi -e "s{cat <<EOF}{cat <<EOF\n#undef UTS_VERSION\n#define UTS_VERSION \"#1 SMP PREEMPT $KBUILD_BUILD_TIMESTAMP\" } unless /UTS_VERSION/" "$mkcompile"
            fi
        fi
    fi

    # ==================== 编译内核 ====================
    log_step "$(txt "编译内核" "Build kernel")"
    cd "$work_kernel"

    sed -i 's/BUILD_SYSTEM_DLKM=1/BUILD_SYSTEM_DLKM=0/' "$common_dir/build.config.gki.aarch64" 2>/dev/null || true
    sed -i '/MODULES_ORDER=android\/gki_aarch64_modules/d' "$common_dir/build.config.gki.aarch64" 2>/dev/null || true
    sed -i '/KMI_SYMBOL_LIST_STRICT_MODE/d' "$common_dir/build.config.gki.aarch64" 2>/dev/null || true

    # 统一 KCFLAGS
    KCFLAGS+=" -O2"
    KCFLAGS+=" -no-canonical-prefixes"
    KCFLAGS+=" -pipe"
    KCFLAGS+=" -Wno-error"
    KCFLAGS+=" -fno-stack-protector"
    KCFLAGS+=" -D__ANDROID_COMMON_KERNEL__"
    export KCFLAGS

    if [ -f "tools/bazel" ]; then
        log_info "$(txt "使用 Bazel 编译..." "Building with Bazel...")"

        # modules_install 创建 build/source → 源码树的符号链接，
        # Bazel 处理产物时递归遍历 .git 目录导致 IOException。
        # 修复：将 ln 创建符号链接替换为 mkdir 创建空目录。
        sed -i 's|@ln -sf $(srctree) $(MODLIB)/source|@mkdir -p $(MODLIB)/source|' "$common_dir/Makefile" 2>/dev/null || true
        sed -i 's|$(Q)ln -sf $(srctree) $$@|mkdir -p $$@|' "$common_dir/scripts/Makefile.modinst" 2>/dev/null || true

        local frag="$common_dir/arch/arm64/configs/ksu.fragment"
        diff "$defconfig.orig" "$defconfig" | grep '^>' | sed 's/^> //; s/^[[:space:]]*//' > "$frag" || true
        cp "$defconfig.orig" "$defconfig"

        log_info "KSU Fragment:"
        cat "$frag" 2>/dev/null || true
        echo ""

        local frag_flag=""
        [ -s "$frag" ] && frag_flag="--defconfig_fragment=//common:arch/arm64/configs/ksu.fragment"
        local lto_flag="--lto=thin"
        [ "$kernel_ver" = "6.12" ] && lto_flag="--lto=none"

        cd "$work_kernel"
        tools/bazel build --disk_cache="$HOME/.cache/bazel" --config=fast "$lto_flag" $frag_flag //common:kernel_aarch64_dist || {
            log_error "$(txt "Bazel 编译失败" "Bazel build failed")"
            return 1
        }
        strings ./bazel-bin/common/kernel_aarch64/Image | grep 'Linux version' || true
    elif [ -f "build/build.sh" ]; then
        log_info "$(txt "使用 build.sh 编译..." "Building with build.sh...")"
        LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh CC="/usr/bin/ccache clang" || {
            log_error "$(txt "内核编译失败" "Kernel build failed")"
            return 1
        }
        strings "out/${android_ver}-${kernel_ver}/dist/Image" | grep 'Linux version' || true
    else
        log_error "$(txt "未找到支持的构建系统 (tools/bazel 或 build/build.sh)" "No supported build system found (tools/bazel or build/build.sh)")"
        return 1
    fi

    log_info "$(txt "内核编译成功!" "Kernel build succeeded!")"

    # ==================== 复制编译产物到输出目录 ====================
    cd "$build_dir"

    local image_path=""
    if [ -f "$work_kernel/tools/bazel" ]; then
        image_path="$work_kernel/bazel-bin/common/kernel_aarch64/Image"
    else
        image_path="$work_kernel/out/${android_ver}-${kernel_ver}/dist/Image"
    fi

    cp "$image_path" "$build_dir/" 2>/dev/null || true

    if [ "$package_boot" != "true" ]; then
        log_info "$(txt "跳过打包，仅输出内核镜像" "Skipping package step; outputting kernel image only")"
    else
        # ==================== AnyKernel3 打包 ====================
        if [ -d "$anykernel_dir" ]; then
            log_step "$(txt "创建 AnyKernel3 刷入包" "Create AnyKernel3 flash package")"
            cd "$anykernel_dir"
            local tag=""
            if [ "$ksu_variant" = "None" ]; then
                tag="NoRoot"
            else
                case "$ksu_variant" in
                    Official) tag="KernelSU" ;;
                    *) tag="$ksu_variant" ;;
                esac
                local ksu_ver=""
                [ -f "$work_kernel/KernelSU/.ksu_version" ] && ksu_ver=$(cat "$work_kernel/KernelSU/.ksu_version")
                [ -n "$ksu_ver" ] && tag="${tag}(${ksu_ver})"
            fi
            local zip_name="${android_ver}-${kernel_ver}.${sub_level}"
            [ -n "$tag" ] && zip_name="${zip_name}-${tag}"
            zip_name="${zip_name}-AnyKernel3.zip"
            cp "$build_dir/Image" ./Image 2>/dev/null || true
            zip -r "../$zip_name" ./* -x ".git/*"
            log_info "$(txt "AnyKernel3 包" "AnyKernel3 package"): $build_dir/$zip_name"
            cd "$build_dir"

            # 提示用户手动获取管理器
            if [ "$ksu_variant" != "None" ]; then
                local ksu_ver=""
                [ -f "$work_kernel/KernelSU/.ksu_version" ] && ksu_ver=$(cat "$work_kernel/KernelSU/.ksu_version")
                local manager_url=""
                case "$ksu_variant" in
                    ReSukiSU) manager_url="https://github.com/ReSukiSU/ReSukiSU/actions/workflows/build-manager.yml" ;;
                    Official) manager_url="https://github.com/tiann/KernelSU/actions/workflows/build-manager.yml" ;;
                esac
                echo ""
                echo -e "  ${YELLOW}$(txt "提示: 请手动下载 ${ksu_variant} 管理器 APK" "Note: download the ${ksu_variant} manager APK manually")${NC}"
                [ -n "$ksu_ver" ] && echo -e "  ${YELLOW}$(txt "KSU 版本" "KSU version"): ${ksu_ver}${NC}"
                [ -n "$manager_url" ] && echo -e "  ${YELLOW}$(txt "Actions 页面" "Actions page"): ${manager_url}${NC}"
                echo -e "  ${YELLOW}$(txt "(需登录 GitHub，找到 name 含版本号的 run → Artifacts 下载 manager zip)" "(Sign in to GitHub, find the run whose name contains the version, then download the manager zip from Artifacts)")${NC}"
                echo -e "  ${YELLOW}$(txt "注：选择 main 分支最新的即可" "Note: choose the latest run on the main branch")${NC}"
                echo ""
            fi
        else
            log_warn "$(txt "未找到 AnyKernel3，跳过打包" "AnyKernel3 was not found; skipping package step")"
        fi
    fi

    # ==================== 收集补丁冲突 ====================
    local rejects_dir="$build_dir/patch-rejects"
    mkdir -p "$rejects_dir"

    mapfile -t rej_files < <(find "$work_kernel" -type f -name '*.rej' 2>/dev/null || true)
    if [ ${#rej_files[@]} -gt 0 ]; then
        log_warn "$(txt "发现" "Found") ${#rej_files[@]} $(txt "个补丁冲突文件" "patch reject file(s)")"
        for rej in "${rej_files[@]}"; do
            local rel="${rej#"$work_kernel"/}"
            local dest="$rejects_dir/$rel"
            mkdir -p "$(dirname "$dest")"
            cp "$rej" "$dest"
            echo "$rel" >> "$rejects_dir/index.txt"
        done
    fi

    # ==================== 构建完成 ====================
    echo ""
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo -e "${GREEN}${BOLD}       $(txt "内核构建完成!" "Kernel build completed!")${NC}"
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo ""
    echo -e "$(txt "输出目录" "Output directory"): ${CYAN}$build_dir${NC}"
    echo ""
    echo -e "$(txt "产物列表:" "Artifacts:")"
    if [ "$package_boot" = "true" ]; then
        ls -lh "$build_dir"/*.zip 2>/dev/null || true
    fi
    ls -lh "$build_dir"/Image 2>/dev/null || true
    echo ""

    if [ ${#rej_files[@]} -gt 0 ]; then
        echo -e "${YELLOW}$(txt "警告: 存在" "Warning:") ${#rej_files[@]} $(txt "个补丁冲突文件，参见" "patch reject file(s), see"): $rejects_dir${NC}"
    fi
}
