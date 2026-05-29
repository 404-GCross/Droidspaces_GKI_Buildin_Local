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
BUILD_CFG[use_kpm]="disabled (关闭)"
BUILD_CFG[use_rekernel]="false"
BUILD_CFG[droidspaces]="off"
BUILD_CFG[kernel_source]=""
BUILD_CFG[output_dir]=""
BUILD_CFG[package_boot]="true"
BUILD_CFG[fetch_manager]="false"

run_build() {
    log_step "开始内核构建"

    local android_ver="${BUILD_CFG[android_version]}"
    local kernel_ver="${BUILD_CFG[kernel_version]}"
    local sub_level="${BUILD_CFG[sub_level]}"
    local os_patch="${BUILD_CFG[os_patch_level]}"
    local ksu_variant="${BUILD_CFG[ksu_variant]}"
    local ksu_branch="${BUILD_CFG[ksu_branch]}"
    local use_zram="${BUILD_CFG[use_zram]}"
    local use_kpm="${BUILD_CFG[use_kpm]}"
    local use_rekernel="${BUILD_CFG[use_rekernel]}"
    local droidspaces="${BUILD_CFG[droidspaces]}"
    local kernel_source="${BUILD_CFG[kernel_source]}"
    local custom_version="${BUILD_CFG[custom_version]}"
    local build_time="${BUILD_CFG[build_time]}"

    local package_boot="${BUILD_CFG[package_boot]:-true}"
    local fetch_manager="${BUILD_CFG[fetch_manager]:-false}"

    local config_id="${android_ver}-${kernel_ver}-${sub_level}"

    # ==================== 构建目录 ====================
    local build_dir="${BUILD_CFG[output_dir]:-$PROJECT_ROOT/build/$config_id}"
    mkdir -p "$build_dir"
    log_info "构建目录: $build_dir"

    # ==================== 准备内核源码 ====================
    if [ -n "$kernel_source" ] && [ -d "$kernel_source" ]; then
        log_info "使用本地内核源码: $kernel_source"

        # 检查是否是完整的内核源码目录
        if [ -d "$kernel_source/common" ]; then
            # 已经是 GKI repo 结构
            local kernel_root="$build_dir/kernel"
            mkdir -p "$kernel_root"
            log_info "检测到 GKI repo 结构，创建符号链接..."
            ln -sf "$kernel_source" "$kernel_root"
            kernel_root="$kernel_source"
        elif [ -f "$kernel_source/Makefile" ]; then
            # 单一内核源码树
            local kernel_root="$kernel_source"
        else
            log_error "无效的内核源码目录: $kernel_source (未找到 Makefile 或 common/ 目录)"
            return 1
        fi
    else
        log_error "请先指定本地内核源码路径!"
        return 1
    fi

    # ==================== 环境变量 ====================
    local common_dir="$kernel_root/common"
    [ -d "$common_dir" ] || common_dir="$kernel_root"

    local defconfig="${common_dir}/arch/arm64/configs/gki_defconfig"
    if [ ! -f "$defconfig" ]; then
        log_error "未找到 gki_defconfig: $defconfig"
        log_info "请确认内核源码路径正确，且包含 GKI defconfig"
        return 1
    fi

    # ==================== 打印构建摘要 ====================
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}       内核构建配置摘要${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "Android 版本  : ${GREEN}$android_ver${NC}"
    echo -e "内核版本      : ${GREEN}$kernel_ver${NC}"
    echo -e "子版本号      : ${GREEN}$sub_level${NC}"
    echo -e "补丁级别      : ${GREEN}$os_patch${NC}"
    echo -e "KSU 变体      : ${GREEN}$ksu_variant${NC}"
    echo -e "KSU 分支      : ${GREEN}$ksu_branch${NC}"
    echo -e "ZRAM 增强     : ${GREEN}$use_zram${NC}"
    echo -e "KPM 功能      : ${GREEN}$use_kpm${NC}"
    echo -e "Re-Kernel     : ${GREEN}$use_rekernel${NC}"
    echo -e "Droidspaces   : ${GREEN}$droidspaces${NC}"
    echo -e "内核源码      : ${GREEN}$kernel_source${NC}"
    echo -e "构建目录      : ${GREEN}$build_dir${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    if ! confirm "是否继续编译?" "y"; then
        log_info "用户取消编译"
        return 0
    fi

    # ==================== 克隆依赖仓库 ====================
    log_step "准备依赖仓库"
    cd "$build_dir"

    local anykernel_dir="$build_dir/AnyKernel3"

    # AnyKernel3
    if [ ! -d "$anykernel_dir" ]; then
        git_clone "https://github.com/404-GCross/AnyKernel3.git" "$anykernel_dir" -b "gki-2.0" || {
            log_error "AnyKernel3 克隆失败，终止编译"
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
        local extracted=$(grep '^SUBLEVEL = ' "$common_dir/Makefile" | awk '{print $3}')
        [ -n "$extracted" ] && actual_sub="$extracted"
    fi
    log_info "实际子版本号: $actual_sub"

    # ==================== 修复 glibc 2.38 兼容性 ====================
    local current_sub="$actual_sub"
    [[ ! "$current_sub" =~ ^[0-9]+$ ]] && current_sub=99999

    local needs_fix=false
    if [ "$android_ver" = "android13" ] && [ "$kernel_ver" = "5.10" ] && [ "$current_sub" -le 186 ]; then needs_fix=true; fi
    if [ "$android_ver" = "android13" ] && [ "$kernel_ver" = "5.15" ] && [ "$current_sub" -le 119 ]; then needs_fix=true; fi
    if [ "$android_ver" = "android14" ] && [ "$kernel_ver" = "6.1" ] && [ "$current_sub" -le 43 ]; then needs_fix=true; fi

    if [ "$needs_fix" = true ]; then
        local glibc_ver=$(ldd --version 2>/dev/null | head -n 1 | awk '{print $NF}')
        if [ "$(printf '%s\n' "2.38" "$glibc_ver" | sort -V | head -n1)" = "2.38" ]; then
            log_info "应用 glibc 2.38 兼容性修复..."
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
        log_info "跳过 KernelSU (纯GKI内核)"
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
    log_step "配置内核选项"
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
                log_info "已启用 KPM"
            else
                log_warn "当前 KernelSU 代码未定义 CONFIG_KPM，跳过"
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

    sed -i 's/check_defconfig//' "$common_dir/build.config.gki"

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
                log_warn "ZRAM LZ4K 补丁未成功应用，跳过增强配置（内核版本可能不兼容）"
            fi
        fi
    fi

    # ==================== 配置内核名称 ====================
    log_step "配置内核版本名称"

    cd "$work_kernel"
    sed -i 's/${scm_version}//' "$common_dir/scripts/setlocalversion"

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
    log_info "构建时间: $KBUILD_BUILD_TIMESTAMP"

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
    log_step "编译内核"
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
        log_info "使用 Bazel 编译..."

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

        cd "$work_kernel"
        tools/bazel build --disk_cache="$HOME/.cache/bazel" --config=fast --lto=thin $frag_flag //common:kernel_aarch64_dist || {
            log_error "Bazel 编译失败"
            return 1
        }
        strings ./bazel-bin/common/kernel_aarch64/Image | grep 'Linux version' || true
    elif [ -f "build/build.sh" ]; then
        log_info "使用 build.sh 编译..."
        LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh CC="/usr/bin/ccache clang" || {
            log_error "内核编译失败"
            return 1
        }
        strings "out/${android_ver}-${kernel_ver}/dist/Image" | grep 'Linux version' || true
    else
        log_error "未找到支持的构建系统 (tools/bazel 或 build/build.sh)"
        return 1
    fi

    log_info "内核编译成功!"

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
        log_info "跳过打包，仅输出内核镜像"
    else
        # ==================== AnyKernel3 打包 ====================
        if [ -d "$anykernel_dir" ]; then
            log_step "创建 AnyKernel3 刷入包"
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
            log_info "AnyKernel3 包: $build_dir/$zip_name"
            cd "$build_dir"

            # 下载 Root 管理器 APK (来自 GitHub Actions CI 产物)
            if [ "$fetch_manager" = "true" ] && [ "$ksu_variant" != "None" ]; then
                log_info "获取 ${ksu_variant} 管理器..."
                local manager_repo=""
                local manager_workflow=""
                case "$ksu_variant" in
                    ReSukiSU) manager_repo="ReSukiSU/ReSukiSU"; manager_workflow="build-manager.yml" ;;
                    Official) manager_repo="tiann/KernelSU"; manager_workflow="build-manager.yml" ;;
                esac
                # 读取内核集成的 KSU 版本号
                local ksu_ver=""
                [ -f "$work_kernel/KernelSU/.ksu_version" ] && ksu_ver=$(cat "$work_kernel/KernelSU/.ksu_version")
                if [ -n "$manager_repo" ]; then
                    # 尝试匹配与内核相同 KSU 版本的 manager (最多查询 30 个历史 run)
                    local artifact_name=""
                    local matched_run=""
                    local page=1
                    while [ $page -le 3 ] && [ -z "$artifact_name" ]; do
                        local run_ids=$(curl -LSs "$(mirror_github "https://api.github.com/repos/${manager_repo}/actions/workflows/${manager_workflow}/runs?status=success&per_page=10&page=${page}")" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' || true)
                        for rid in $run_ids; do
                            local all_artifacts=$(curl -LSs "$(mirror_github "https://api.github.com/repos/${manager_repo}/actions/runs/${rid}/artifacts")" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' || true)
                            # 优先匹配版本号且非 debug
                            if [ -n "$ksu_ver" ]; then
                                artifact_name=$(echo "$all_artifacts" | grep -F "$ksu_ver" | grep -iv 'debug' | head -1)
                            fi
                            # 无版本号匹配则取第一个非 debug
                            [ -z "$artifact_name" ] && artifact_name=$(echo "$all_artifacts" | grep -iv 'debug' | head -1)
                            if [ -n "$artifact_name" ]; then
                                matched_run="$rid"
                                break
                            fi
                        done
                        page=$((page + 1))
                    done
                    if [ -n "$artifact_name" ]; then
                        local zip_name="${ksu_variant}-manager.zip"
                        local encoded_name=$(printf '%s' "$artifact_name" | sed 's/(/\%28/g; s/)/\%29/g; s/ /\%20/g')
                        local dl_url="https://nightly.link/${manager_repo}/actions/runs/${matched_run}/${encoded_name}.zip"
                        log_info "下载: ${artifact_name}"
                        if [ -n "$ksu_ver" ] && ! echo "$artifact_name" | grep -qF "$ksu_ver"; then
                            log_warn "管理器版本可能与内核 KSU v${ksu_ver} 不匹配"
                        fi
                        curl -LSs -o "$build_dir/$zip_name" "$dl_url" && {
                            log_info "管理器: $build_dir/$zip_name"
                        } || log_warn "管理器下载失败"
                    else
                        log_warn "未找到 ${ksu_variant} 管理器构建产物"
                    fi
                else
                    log_warn "${ksu_variant} 暂不支持管理器下载"
                fi
            fi
        else
            log_warn "未找到 AnyKernel3，跳过打包"
        fi
    fi

    # ==================== 收集补丁冲突 ====================
    local rejects_dir="$build_dir/patch-rejects"
    mkdir -p "$rejects_dir"

    mapfile -t rej_files < <(find "$work_kernel" -type f -name '*.rej' 2>/dev/null || true)
    if [ ${#rej_files[@]} -gt 0 ]; then
        log_warn "发现 ${#rej_files[@]} 个补丁冲突文件"
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
    echo -e "${GREEN}${BOLD}       内核构建完成!${NC}"
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo ""
    echo -e "输出目录: ${CYAN}$build_dir${NC}"
    echo ""
    echo -e "产物列表:"
    if [ "$package_boot" = "true" ]; then
        ls -lh "$build_dir"/*.zip 2>/dev/null || true
    fi
    ls -lh "$build_dir"/Image 2>/dev/null || true
    echo ""

    if [ ${#rej_files[@]} -gt 0 ]; then
        echo -e "${YELLOW}警告: 存在 ${#rej_files[@]} 个补丁冲突文件，参见: $rejects_dir${NC}"
    fi
}
