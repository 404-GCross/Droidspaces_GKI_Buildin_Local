#!/usr/bin/env bash
# ================================================================
# GKI 内核本地编译工具 - 主入口
# ================================================================
# 用法:
#   ./build_kernel.sh              # 交互式菜单
#   ./build_kernel.sh --help       # 显示帮助
#   ./build_kernel.sh --quick      # 使用上次配置快速构建
#   ./build_kernel.sh --config     # 仅配置，不编译
# ================================================================

set -euo pipefail

# --- 加载公共库 ---
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/lib/common.sh"
source "$ROOT_DIR/scripts/lib/setup_env.sh"
source "$ROOT_DIR/scripts/lib/features.sh"
source "$ROOT_DIR/scripts/lib/build_core.sh"

# --- 配置保存路径 ---
BUILD_CONFIG_FILE="$PROJECT_ROOT/.build_config"

# --- 帮助信息 ---
show_help() {
    echo "GKI 内核本地编译工具"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --help       显示此帮助信息"
    echo "  --quick      使用上次保存的配置直接编译"
    echo "  --config     仅配置，不编译"
    echo "  --reset      清除保存的配置"
    echo ""
    echo "首次运行将进入交互式配置菜单。"
}

# --- 保存配置 ---
save_config() {
    cat > "$BUILD_CONFIG_FILE" << EOF
# GKI 编译配置 - $(date)
ANDROID_VERSION="${BUILD_CFG[android_version]}"
KERNEL_VERSION="${BUILD_CFG[kernel_version]}"
SUB_LEVEL="${BUILD_CFG[sub_level]}"
OS_PATCH_LEVEL="${BUILD_CFG[os_patch_level]}"
REVISION="${BUILD_CFG[revision]}"
KSU_VARIANT="${BUILD_CFG[ksu_variant]}"
KSU_BRANCH="${BUILD_CFG[ksu_branch]}"
CUSTOM_VERSION="${BUILD_CFG[custom_version]}"
BUILD_TIME="${BUILD_CFG[build_time]}"
USE_ZRAM="${BUILD_CFG[use_zram]}"
USE_KPM="${BUILD_CFG[use_kpm]}"
USE_REKERNEL="${BUILD_CFG[use_rekernel]}"
DROIDSPACES="${BUILD_CFG[droidspaces]}"
KERNEL_SOURCE="${BUILD_CFG[kernel_source]}"
KERNEL_SOURCE_TARBALL="${BUILD_CFG[kernel_source_tarball]:-}"
OUTPUT_DIR="${BUILD_CFG[output_dir]}"
PACKAGE_BOOT="${BUILD_CFG[package_boot]}"
EOF
    log_info "配置已保存到 $BUILD_CONFIG_FILE"
}

# --- 加载配置 ---
load_config() {
    if [ -f "$BUILD_CONFIG_FILE" ]; then
        source "$BUILD_CONFIG_FILE"
        BUILD_CFG[android_version]="${ANDROID_VERSION:-}"
        BUILD_CFG[kernel_version]="${KERNEL_VERSION:-}"
        BUILD_CFG[sub_level]="${SUB_LEVEL:-}"
        BUILD_CFG[os_patch_level]="${OS_PATCH_LEVEL:-}"
        BUILD_CFG[revision]="${REVISION:-}"
        BUILD_CFG[ksu_variant]="${KSU_VARIANT:-None}"
        BUILD_CFG[ksu_branch]="${KSU_BRANCH:-Stable(标准)}"
        BUILD_CFG[custom_version]="${CUSTOM_VERSION:-}"
        BUILD_CFG[build_time]="${BUILD_TIME:-}"
        BUILD_CFG[use_zram]="${USE_ZRAM:-false}"
        BUILD_CFG[use_kpm]="${USE_KPM:-disabled (关闭)}"
        BUILD_CFG[use_rekernel]="${USE_REKERNEL:-false}"
        BUILD_CFG[droidspaces]="${DROIDSPACES:-off}"
        BUILD_CFG[kernel_source]="${KERNEL_SOURCE:-}"
        BUILD_CFG[kernel_source_tarball]="${KERNEL_SOURCE_TARBALL:-}"
        BUILD_CFG[output_dir]="${OUTPUT_DIR:-$PROJECT_ROOT/build/out}"
        BUILD_CFG[package_boot]="${PACKAGE_BOOT:-true}"
        return 0
    fi
    return 1
}

# ================================================================
# 交互式菜单
# ================================================================

# GitHub 镜像源预设列表
GITHUB_MIRROR_PRESETS=(
    "https://gh-proxy.com/"
    "https://gh.llkk.cc/"
    "https://gh.ddlc.top/"
)

config_mirrors() {
    while true; do
        echo ""
        echo -e "${CYAN}─── GitHub 镜像源 ───${NC}"
        echo -e "当前: ${GREEN}${CUSTOM_GITHUB_MIRROR:-未设置 (直连)}${NC}"
        echo ""

        local opts=("保持当前" "清除 (直连)")
        for m in "${GITHUB_MIRROR_PRESETS[@]}"; do
            opts+=("$m")
        done
        opts+=("自定义输入")

        local result=$(select_option "选择 GitHub 镜像:" "${opts[@]}")
        local idx="${result%%$'\t'*}"
        case $idx in
            0) break ;;  # 保持当前，返回上级
            1) CUSTOM_GITHUB_MIRROR="" ; break ;;  # 清除，返回上级
            *)
                local preset_count=${#GITHUB_MIRROR_PRESETS[@]}
                local preset_idx=$((idx - 2))
                if [ "$preset_idx" -ge 0 ] && [ "$preset_idx" -lt "$preset_count" ]; then
                    CUSTOM_GITHUB_MIRROR="${GITHUB_MIRROR_PRESETS[$preset_idx]}"
                else
                    read -r -p "$(echo -e "${YELLOW}输入 GitHub 镜像前缀:${NC} ")" val
                    CUSTOM_GITHUB_MIRROR="${val:-}"
                fi
                ;;
        esac
        echo -e "  GitHub 镜像 → ${GREEN}${CUSTOM_GITHUB_MIRROR:-直连}${NC}"

        # 选择后询问是否测速
        if [ -n "${CUSTOM_GITHUB_MIRROR:-}" ]; then
            if confirm "是否对所选镜像进行测速（拉取约23M的视频文件，测速设置30s超时）?" "y"; then
                _speedtest_single "$CUSTOM_GITHUB_MIRROR"
                if confirm "是否使用该镜像源?" "y"; then
                    break
                fi
                CUSTOM_GITHUB_MIRROR=""
                continue
            else
                break
            fi
        fi
        break
    done

    # 保存配置
    cat > "$MIRRORS_CONF" << EOF
# ================================================================
# 镜像源配置文件
# ================================================================
use_custom_mirror=true
CUSTOM_GITHUB_MIRROR="${CUSTOM_GITHUB_MIRROR:-}"
EOF
    # 立即加载到当前 shell，确保后续步骤（如 fetch_kernel_source）可用
    source "$MIRRORS_CONF"
    log_info "镜像配置已保存"
}

_speedtest_single() {
    local mirror="$1"
    local test_file="https://raw.githubusercontent.com/404-GCross/GKI-Kernel-Source_Fetch/main/speedtest.mp4"
    local timeout=30
    local url="${mirror}${test_file}"

    echo ""
    echo -e "${CYAN}─── 镜像测速 ───${NC}"
    echo -e "镜像: ${mirror}"
    echo ""

    echo -n "  下载测速中 ... "
    local start=$(date +%s%N)
    local size="" ret=0
    size=$(curl -LSs -o /dev/null --max-time "$timeout" -w "%{size_download}" "$url" 2>/dev/null) || ret=$?
    local end=$(date +%s%N)
    local elapsed=$(( (end - start) / 1000000 ))

    if [ $ret -ne 0 ] || [ -z "$size" ] || [ "$size" -le 0 ]; then
        echo ""
        echo -e "  ${RED}测速失败 (超时或无法连接)${NC}"
        return
    fi

    # 计算速度 (KB/s)
    local speed=$(( size * 1000 / elapsed / 1024 ))
    echo ""
    echo -e "  耗时: ${elapsed}ms"
    echo -e "  大小: $(( size / 1024 ))KB"
    echo -e "  速度: ${GREEN}${speed} KB/s${NC}"
}

# 从 KERNEL_VERSIONS 表查找补丁级别
_lookup_os_patch_level() {
    local key="${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}"
    local data="${KERNEL_VERSIONS[$key]:-}"
    [ -z "$data" ] && return
    while IFS='|' read -r _ sub patch rev; do
        [ -z "$sub" ] && continue
        if [ "$sub" = "${BUILD_CFG[sub_level]}" ]; then
            [ -n "$patch" ] && BUILD_CFG[os_patch_level]="$patch"
            [ -n "$rev" ] && BUILD_CFG[revision]="$rev"
            return 0
        fi
    done <<< "$data" || true
}

# 获取内核源码 (远程脚本)
fetch_kernel_source() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ 获取内核源码 ═══${NC}"
    echo ""

    local script_url="https://raw.githubusercontent.com/404-GCross/GKI-Kernel-Source_Fetch/refs/heads/main/fetch_kernel_source_no-extract.sh"
    local actual_url=$(mirror_github "$script_url")

    log_info "正在获取内核源码拉取脚本..."
    log_info "脚本地址: $actual_url"

    mkdir -p "$PROJECT_ROOT/kernel-sources"

    local tmp_out="/tmp/fetch_kernel_output.log"
    local ret=0
    bash <(curl -LSs "$actual_url") 2>&1 | tee "$tmp_out" || ret=${PIPESTATUS[0]}
    ret=${ret:-${PIPESTATUS[0]}}

    if [ $ret -ne 0 ]; then
        log_error "内核源码获取失败 (退出码: $ret)"
        rm -f "$tmp_out"
        return 1
    fi

    log_info "内核源码获取完成"

    # 从脚本输出中解析版本号 (格式: "目标版本：android12-5.10-246")
    # 先去除 ANSI 转义码再解析，否则颜色码会导致行首匹配失败
    local version_line=$(sed 's/\x1b\[[0-9;]*m//g' "$tmp_out" | sed -n 's/^.*目标版本：//p' | tail -1)
    if [ -n "$version_line" ]; then
        # 解析 android12-5.10-246 → android12 / 5.10 / 246
        if [[ "$version_line" =~ ^(android[0-9]+)-([0-9]+\.[0-9]+)-(.+)$ ]]; then
            BUILD_CFG[android_version]="${BASH_REMATCH[1]}"
            BUILD_CFG[kernel_version]="${BASH_REMATCH[2]}"
            BUILD_CFG[sub_level]="${BASH_REMATCH[3]}"
            _lookup_os_patch_level
            log_info "已自动设置内核版本: ${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}-${BUILD_CFG[sub_level]}"
        fi
    fi

    # 从脚本输出中解析源码路径 (格式: "源码路径：/path/to/src")
    local source_path=$(sed -n 's/^源码路径：//p' "$tmp_out" | tail -1)
    rm -f "$tmp_out"

    if [ -n "$source_path" ] && [ -d "$source_path" ]; then
        BUILD_CFG[kernel_source]="$source_path"
        log_info "已自动设置内核源码路径: ${BUILD_CFG[kernel_source]}"
    elif [ -z "${BUILD_CFG[kernel_source]}" ] && [ -d "$PROJECT_ROOT/GKI-Kernel-Source" ]; then
        BUILD_CFG[kernel_source]="$PROJECT_ROOT/GKI-Kernel-Source"
        log_info "已自动设置内核源码路径: ${BUILD_CFG[kernel_source]}"
    else
        log_warn "未能自动检测源码路径，请手动设置"
    fi

    # 扫描 kernel-sources/ 中的压缩包，自动设置
    shopt -s nullglob
    local tarballs=("$PROJECT_ROOT/kernel-sources"/*.tar.gz)
    shopt -u nullglob
    if [ ${#tarballs[@]} -gt 0 ] && [ -n "${BUILD_CFG[android_version]}" ]; then
        local version_pattern="${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}-${BUILD_CFG[sub_level]}"
        local matched=""
        for t in "${tarballs[@]}"; do
            local name=$(basename "$t")
            if [[ "$name" =~ ^kernel-source-(android[0-9]+)-([0-9]+\.[0-9]+)-(.+)\.tar\.gz$ ]]; then
                if [ "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}" = "$version_pattern" ]; then
                    matched="$t"
                    break
                fi
            fi
        done
        [ -z "$matched" ] && matched="${tarballs[0]}"
        BUILD_CFG[kernel_source_tarball]="$matched"
        log_info "已自动设置内核源码包: $(basename "$matched")"
    fi
}

# 内核源码路径选择
config_kernel_source() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ 内核源码路径 ═══${NC}"
    echo ""
    echo -e "当前路径: ${YELLOW}${BUILD_CFG[kernel_source]:-未设置}${NC}"
    echo ""

    read -r -p "$(echo -e "${YELLOW}GKI 源码目录路径 (包含 common/ 子目录):${NC} ")" src
    if [ -d "$src/common" ]; then
        BUILD_CFG[kernel_source]=$(get_abs_path "$src")
        BUILD_CFG[kernel_source_tarball]=""  # 手动路径，编译时跳过解压
        log_info "已选择 GKI 源码: ${BUILD_CFG[kernel_source]}"
    else
        log_error "目录中未找到 common/ 子目录，不是有效的 GKI 源码目录"
        config_kernel_source
        return
    fi
}

# ================================================================
# 预定义内核版本组合 (来自 GitHub Actions matrix)
# 格式: "显示名|sub_level|os_patch_level|revision"
# ================================================================

declare -A KERNEL_VERSIONS

# Android 12 - 5.10 (有 revision)
KERNEL_VERSIONS["android12-5.10"]="
5.10.66  (2022-01 r11)|66|2022-01|r11
5.10.81  (2022-03 r11)|81|2022-03|r11
5.10.101 (2022-04 r28)|101|2022-04|r28
5.10.110 (2022-07 r1)|110|2022-07|r1
5.10.117 (2022-09 r1)|117|2022-09|r1
5.10.136 (2022-11 r15)|136|2022-11|r15
5.10.149 (2023-01 r1)|149|2023-01|r1
5.10.160 (2023-03 r1)|160|2023-03|r1
5.10.168 (2023-04 r9)|168|2023-04|r9
5.10.177 (2023-07 r3)|177|2023-07|r3
5.10.185 (2023-09 r1)|185|2023-09|r1
5.10.198 (2024-01 r17)|198|2024-01|r17
5.10.205 (2024-03 r1)|205|2024-03|r1
5.10.209 (2024-05 r13)|209|2024-05|r13
5.10.218 (2024-08 r14)|218|2024-08|r14
5.10.226 (2024-11 r8)|226|2024-11|r8
5.10.233 (2025-02 r1)|233|2025-02|r1
5.10.236 (2025-05 r1)|236|2025-05|r1
5.10.237 (2025-06 r1)|237|2025-06|r1
5.10.240 (2025-09 r1)|240|2025-09|r1
5.10.246 (2025-12 r1)|246|2025-12|r1
5.10.X   (lts r1)|X|lts|r1
"

# Android 13 - 5.15 (无 revision)
KERNEL_VERSIONS["android13-5.15"]="
5.15.74  (2023-01)|74|2023-01|
5.15.78  (2023-03)|78|2023-03|
5.15.94  (2023-05)|94|2023-05|
5.15.104 (2023-07)|104|2023-07|
5.15.119 (2023-09)|119|2023-09|
5.15.123 (2023-11)|123|2023-11|
5.15.137 (2024-01)|137|2024-01|
5.15.144 (2024-03)|144|2024-03|
5.15.148 (2024-05)|148|2024-05|
5.15.149 (2024-07)|149|2024-07|
5.15.151 (2024-08)|151|2024-08|
5.15.153 (2024-09)|153|2024-09|
5.15.167 (2024-11)|167|2024-11|
5.15.170 (2025-01)|170|2025-01|
5.15.178 (2025-03)|178|2025-03|
5.15.180 (2025-05)|180|2025-05|
5.15.185 (2025-07)|185|2025-07|
5.15.189 (2025-09)|189|2025-09|
5.15.194 (2025-12)|194|2025-12|
5.15.X   (lts)|X|lts|
"

# Android 14 - 6.1 (无 revision)
KERNEL_VERSIONS["android14-6.1"]="
6.1.25  (2023-10)|25|2023-10|
6.1.43  (2023-11)|43|2023-11|
6.1.57  (2024-01)|57|2024-01|
6.1.68  (2024-03)|68|2024-03|
6.1.75  (2024-05)|75|2024-05|
6.1.78  (2024-06)|78|2024-06|
6.1.84  (2024-07)|84|2024-07|
6.1.90  (2024-08)|90|2024-08|
6.1.93  (2024-09)|93|2024-09|
6.1.99  (2024-10)|99|2024-10|
6.1.112 (2024-11)|112|2024-11|
6.1.115 (2024-12)|115|2024-12|
6.1.118 (2025-01)|118|2025-01|
6.1.124 (2025-02)|124|2025-02|
6.1.128 (2025-03)|128|2025-03|
6.1.129 (2025-04)|129|2025-04|
6.1.134 (2025-05)|134|2025-05|
6.1.138 (2025-06)|138|2025-06|
6.1.141 (2025-07)|141|2025-07|
6.1.145 (2025-09)|145|2025-09|
6.1.157 (2025-12)|157|2025-12|
6.1.162 (2026-03)|162|2026-03|
6.1.X   (lts)|X|lts|
"

# Android 15 - 6.6 (无 revision)
KERNEL_VERSIONS["android15-6.6"]="
6.6.50  (2024-10)|50|2024-10|
6.6.56  (2024-11)|56|2024-11|
6.6.57  (2024-12)|57|2024-12|
6.6.58  (2025-01)|58|2025-01|
6.6.66  (2025-02)|66|2025-02|
6.6.77  (2025-03)|77|2025-03|
6.6.82  (2025-04)|82|2025-04|
6.6.87  (2025-05)|87|2025-05|
6.6.89  (2025-06)|89|2025-06|
6.6.92  (2025-07)|92|2025-07|
6.6.98  (2025-09)|98|2025-09|
6.6.102 (2025-10)|102|2025-10|
6.6.118 (2026-01)|118|2026-01|
6.6.127 (2026-04)|127|2026-04|
6.6.X   (lts)|X|lts|
"

# Android 16 - 6.12 (无 revision)
KERNEL_VERSIONS["android16-6.12"]="
6.12.23 (2025-06)|23|2025-06|
6.12.30 (2025-07)|30|2025-07|
6.12.38 (2025-09)|38|2025-09|
6.12.58 (2025-12)|58|2025-12|
"

# 内核版本选择菜单
config_kernel_version() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ 内核版本选择 ═══${NC}"
    echo ""

    local versions=(
        "Android 12 - 5.10 (android12-5.10)"
        "Android 13 - 5.15 (android13-5.15)"
        "Android 14 - 6.1  (android14-6.1)"
        "Android 15 - 6.6  (android15-6.6)"
        "Android 16 - 6.12 (android16-6.12)"
    )
    local result=$(select_option "选择目标 Android/内核版本:" "${versions[@]}")
    local idx="${result%%$'\t'*}"

    local av kv
    case $idx in
        0) av="android12"; kv="5.10" ;;
        1) av="android13"; kv="5.15" ;;
        2) av="android14"; kv="6.1"  ;;
        3) av="android15"; kv="6.6"  ;;
        4) av="android16"; kv="6.12" ;;
    esac

    BUILD_CFG[android_version]="$av"
    BUILD_CFG[kernel_version]="$kv"
    log_info "已选择: ${av} / ${kv}"

    # --- 选择子版本 (附带补丁级别) ---
    echo ""
    echo -e "${CYAN}选择子版本号 (安全补丁级别已自动关联):${NC}"

    local key="${av}-${kv}"
    local data="${KERNEL_VERSIONS[$key]}"
    local -a labels=()
    local -a subs=()
    local -a patches=()
    local -a revs=()

    while IFS='|' read -r label sub patch rev; do
        [ -z "$label" ] && continue
        labels+=("$label")
        subs+=("$sub")
        patches+=("$patch")
        revs+=("$rev")
    done <<< "$data" || true

    local sub_result=$(select_option "" "${labels[@]}")
    local sub_idx="${sub_result%%$'\t'*}"

    BUILD_CFG[sub_level]="${subs[$sub_idx]}"
    BUILD_CFG[os_patch_level]="${patches[$sub_idx]}"
    BUILD_CFG[revision]="${revs[$sub_idx]}"

    log_info "内核: ${kv}.${BUILD_CFG[sub_level]}  补丁: ${BUILD_CFG[os_patch_level]}  修订: ${BUILD_CFG[revision]:-无}"
}

# KernelSU 配置
config_kernelsu() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ KernelSU 配置 ═══${NC}"
    echo ""

    local variants=("None (纯GKI内核/无root)" "ReSukiSU (推荐)" "Official (KernelSU官方)")
    local result=$(select_option "选择 KernelSU 变体:" "${variants[@]}")
    local idx="${result%%$'\t'*}"

    case $idx in
        0) BUILD_CFG[ksu_variant]="None" ;;
        1) BUILD_CFG[ksu_variant]="ReSukiSU" ;;
        2) BUILD_CFG[ksu_variant]="Official" ;;
    esac

    # None = 纯 GKI，不需要选择分支
    if [ "${BUILD_CFG[ksu_variant]}" = "None" ]; then
        BUILD_CFG[ksu_branch]="-"
        BUILD_CFG[use_kpm]="disabled (关闭)"
        log_info "KernelSU: 无 (纯GKI内核)"
        return 0
    fi

    local branches=("Stable(标准)" "Dev(开发)")
    local branch_result=$(select_option "选择 KSU 分支:" "${branches[@]}")
    idx="${branch_result%%$'\t'*}"
    case $idx in
        0) BUILD_CFG[ksu_branch]="Stable(标准)" ;;
        1) BUILD_CFG[ksu_branch]="Dev(开发)" ;;
    esac

    log_info "KernelSU: ${BUILD_CFG[ksu_variant]} / ${BUILD_CFG[ksu_branch]}"
}

# Droidspaces 容器支持配置
config_droidspaces() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ Droidspaces 容器支持 ═══${NC}"
    echo ""

    local ds_opts=("off (关闭)" "678" "123" "345")
    if [ "${BUILD_CFG[kernel_version]}" = "6.12" ]; then
        ds_opts=("off (关闭)" "on (开启)")
    fi
    local ds_result=$(select_option "Droidspaces 容器支持:" "${ds_opts[@]}")
    local idx="${ds_result%%$'\t'*}"
    case $idx in
        0) BUILD_CFG[droidspaces]="off" ;;
        1) [ "${BUILD_CFG[kernel_version]}" = "6.12" ] && BUILD_CFG[droidspaces]="on" || BUILD_CFG[droidspaces]="678" ;;
        2) BUILD_CFG[droidspaces]="123" ;;
        3) BUILD_CFG[droidspaces]="345" ;;
    esac
    echo -e "  Droidspaces: ${GREEN}${BUILD_CFG[droidspaces]}${NC}"
}

# 功能开关配置
config_features() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ 其他功能配置 ═══${NC}"
    echo ""

    # ZRAM
    if confirm "启用 ZRAM 增强算法 (LZ4KD)?" "n"; then
        BUILD_CFG[use_zram]="true"
    else
        BUILD_CFG[use_zram]="false"
    fi
    echo -e "  ZRAM: ${GREEN}${BUILD_CFG[use_zram]}${NC}"

    # Re-Kernel
    if confirm "启用 Re-Kernel 驱动?" "n"; then
        BUILD_CFG[use_rekernel]="true"
    else
        BUILD_CFG[use_rekernel]="false"
    fi
    echo -e "  Re-Kernel: ${GREEN}${BUILD_CFG[use_rekernel]}${NC}"

    # KPM — 仅在使用 KernelSU 时可选
    if [ "${BUILD_CFG[ksu_variant]}" = "None" ]; then
        BUILD_CFG[use_kpm]="disabled (关闭)"
        echo -e "  KPM: ${RED}不可用 (纯GKI内核)${NC}"
    else
        local kpm_opts=("disabled (关闭)" "enabled (开启)")
        local kpm_result=$(select_option "KPM 功能:" "${kpm_opts[@]}")
        idx="${kpm_result%%$'\t'*}"
        case $idx in
            0) BUILD_CFG[use_kpm]="disabled (关闭)" ;;
            1) BUILD_CFG[use_kpm]="enabled (开启)" ;;
        esac
        echo -e "  KPM: ${GREEN}${BUILD_CFG[use_kpm]}${NC}"
    fi

    # 默认打包 AnyKernel3
    BUILD_CFG[package_boot]="true"
    echo -e "  打包 AK3:   ${GREEN}true${NC}"
}

# 可选配置
config_optional() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ 可选配置 ═══${NC}"
    echo ""

    read -r -p "$(echo -e "${YELLOW}自定义版本名 (可选, 留空跳过; ${RED}不宜过长${NC}${YELLOW}, 过长会导致编译失败):${NC} ")" ver
    BUILD_CFG[custom_version]="$ver"

    read -r -p "$(echo -e "${YELLOW}自定义构建时间 (可选, N或留空=当前UTC时间):${NC} ")" btime
    BUILD_CFG[build_time]="$btime"

    read -r -p "$(echo -e "${YELLOW}输出目录 (留空使用默认):${NC} ")" outdir
    BUILD_CFG[output_dir]="${outdir:-$PROJECT_ROOT/build/out}"

    echo ""
    echo -e "  自定义版本: ${GREEN}${BUILD_CFG[custom_version]:-未设置}${NC}"
    echo -e "  构建时间:   ${GREEN}${BUILD_CFG[build_time]:-当前UTC}${NC}"
    echo -e "  输出目录:   ${GREEN}${BUILD_CFG[output_dir]}${NC}"
}

# 显示配置摘要
show_config_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║           构建配置摘要                       ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    if [ -n "${BUILD_CFG[kernel_source]}" ]; then
        echo -e "  ${BOLD}内核源码${NC}      ${GREEN}${BUILD_CFG[kernel_source]}${NC}"
    elif [ -n "${BUILD_CFG[kernel_source_tarball]}" ]; then
        echo -e "  ${BOLD}源码包${NC}        ${GREEN}$(basename "${BUILD_CFG[kernel_source_tarball]}")${NC} ${YELLOW}(编译时解压)${NC}"
    else
        echo -e "  ${BOLD}内核源码${NC}      ${RED}未设置!${NC}"
    fi
    echo -e "  ${BOLD}Android版本${NC}    ${GREEN}${BUILD_CFG[android_version]:-未设置!}${NC}"
    echo -e "  ${BOLD}内核版本${NC}      ${GREEN}${BUILD_CFG[kernel_version]:-未设置!}${NC}"
    echo -e "  ${BOLD}子版本号${NC}      ${GREEN}${BUILD_CFG[sub_level]:-未设置!}${NC}"
    if [ -n "${BUILD_CFG[revision]}" ]; then
        echo -e "  ${BOLD}修订版本${NC}      ${GREEN}${BUILD_CFG[revision]}${NC}"
    fi
    if [ "${BUILD_CFG[ksu_variant]}" = "None" ]; then
        echo -e "  ${BOLD}KSU变体${NC}       ${GREEN}纯GKI内核 (无root)${NC}"
    else
        echo -e "  ${BOLD}KSU变体${NC}       ${GREEN}${BUILD_CFG[ksu_variant]}${NC}"
        echo -e "  ${BOLD}KSU分支${NC}       ${GREEN}${BUILD_CFG[ksu_branch]}${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}功能开关:${NC}"
    echo -e "    ZRAM增强:    ${BUILD_CFG[use_zram]}" | sed 's/true/'$'\033[0;32m''开启'$'\033[0m'/g | sed 's/false/'$'\033[0;31m''关闭'$'\033[0m'/g
    echo -e "    Re-Kernel:   ${BUILD_CFG[use_rekernel]}" | sed 's/true/'$'\033[0;32m''开启'$'\033[0m'/g | sed 's/false/'$'\033[0;31m''关闭'$'\033[0m'/g
    echo -e "    KPM:         ${BUILD_CFG[use_kpm]}"
    echo -e "    Droidspaces: ${BUILD_CFG[droidspaces]}"
    echo -e "    打包 AK3:     默认开启"
    echo ""
    echo -e "  ${BOLD}镜像源:${NC}"
    echo -e "    GitHub:  ${GREEN}${CUSTOM_GITHUB_MIRROR:-直连}${NC}"
    echo ""
    echo -e "  ${BOLD}构建时间${NC}      ${GREEN}${BUILD_CFG[build_time]:-当前UTC}${NC}"
    echo -e "  ${BOLD}输出版本${NC}      ${GREEN}${BUILD_CFG[custom_version]:-自动生成}${NC}"
    echo -e "  ${BOLD}输出目录${NC}      ${GREEN}${BUILD_CFG[output_dir]}${NC}"
    echo ""
}

# 选择脚本获取的内核源码
config_kernel_from_source_package() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ 选择脚本获取的内核源码 ═══${NC}"
    echo ""

    local src_dir="$PROJECT_ROOT/kernel-sources"
    if [ ! -d "$src_dir" ]; then
        log_error "内核源码目录不存在: $src_dir"
        log_info "请先执行 '获取内核源码' 下载源码包"
        return 1
    fi

    shopt -s nullglob
    local tarballs=("$src_dir"/*.tar.gz)
    shopt -u nullglob

    if [ ${#tarballs[@]} -eq 0 ]; then
        log_error "未找到内核源码压缩包 (.tar.gz)"
        log_info "请先执行 '获取内核源码' 下载源码包"
        return 1
    fi

    local labels=()
    for t in "${tarballs[@]}"; do
        local name=$(basename "$t")
        if [[ "$name" =~ ^kernel-source-(android[0-9]+)-([0-9]+\.[0-9]+)-(.+)\.tar\.gz$ ]]; then
            labels+=("${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}")
        else
            labels+=("$name")
        fi
    done

    local result=$(select_option "选择内核源码:" "${labels[@]}")
    local idx="${result%%$'\t'*}"
    local chosen="${tarballs[$idx]}"
    local name=$(basename "$chosen")

    # 解析版本号
    if [[ "$name" =~ ^kernel-source-(android[0-9]+)-([0-9]+\.[0-9]+)-(.+)\.tar\.gz$ ]]; then
        BUILD_CFG[android_version]="${BASH_REMATCH[1]}"
        BUILD_CFG[kernel_version]="${BASH_REMATCH[2]}"
        BUILD_CFG[sub_level]="${BASH_REMATCH[3]}"
        BUILD_CFG[kernel_source_tarball]="$chosen"
        _lookup_os_patch_level
        log_info "已识别内核版本: ${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}-${BUILD_CFG[sub_level]}"
        log_info "源码包: $chosen (将在编译时解压)"
    else
        log_warn "无法从文件名识别内核版本: $name"
        log_info "参考格式: kernel-source-android16-6.12-23.tar.gz"
    fi
}

# ================================================================
# 解压内核源码压缩包
# ================================================================
extract_kernel_source_tarball() {
    local tarball="${BUILD_CFG[kernel_source_tarball]:-}"
    [ -z "$tarball" ] && return 0

    if [ -z "${BUILD_CFG[kernel_source]}" ] || [ ! -d "${BUILD_CFG[kernel_source]}" ]; then
        if [ -f "$tarball" ]; then
            log_step "解压内核源码包"
            local extracted_dir="$PROJECT_ROOT/$(basename "${tarball%.tar.gz}")"
            if [ -d "$extracted_dir" ]; then
                log_info "已存在 $extracted_dir，跳过解压"
            else
                mkdir -p "$extracted_dir"
                tar -xzf "$tarball" -C "$extracted_dir" --strip-components=1
            fi
            if [ -d "$extracted_dir/common" ]; then
                BUILD_CFG[kernel_source]="$extracted_dir"
                log_info "内核源码路径: $extracted_dir"
            fi
        else
            log_error "源码包不存在: $tarball"
            return 1
        fi
    fi
}

# ================================================================
# 主菜单
# ================================================================

main_menu() {
    show_banner

    # 尝试加载上次配置
    if load_config; then
        echo -e "已加载上次配置: ${YELLOW}$BUILD_CONFIG_FILE${NC}"
    fi

    # 加载镜像配置
    load_mirror_config

    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}═══ 主菜单 ═══${NC}"
        echo -e "  ${RED}米系6.12设备暂不可用${NC}"
        echo ""
        echo -e "  ${YELLOW}建议按顺序配置一遍${NC}"
        echo ""
        echo -ne "  1) 镜像源配置"
        echo -e " ${GREEN}→ ${CUSTOM_GITHUB_MIRROR:-直连}${NC}"
        echo "  2) 安装编译依赖"
        echo "  3) 获取内核源码"
        echo "  4) 选择脚本获取的内核源码"
        echo -ne "  5) 选择内核源码路径"
        [ -n "${BUILD_CFG[kernel_source]}" ] && echo -e " ${GREEN}→ ${BUILD_CFG[kernel_source]}${NC}" || echo ""
        echo -ne "  6) 选择内核版本"
        if [ -n "${BUILD_CFG[android_version]}" ] && [ -n "${BUILD_CFG[kernel_version]}" ]; then
            echo -e " ${GREEN}→ ${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}-${BUILD_CFG[sub_level]}${NC}"
        else
            echo ""
        fi
        echo -ne "  7) 配置 KernelSU"
        if [ -n "${BUILD_CFG[ksu_variant]}" ]; then
            echo -e " ${GREEN}→ ${BUILD_CFG[ksu_variant]} (${BUILD_CFG[ksu_branch]})${NC}"
        else
            echo ""
        fi
        echo -ne "  8) Droidspaces 容器支持"
        if [ -n "${BUILD_CFG[droidspaces]}" ]; then
            echo -e " ${GREEN}→ ${BUILD_CFG[droidspaces]}${NC}"
        else
            echo ""
        fi
        echo -ne "  9) 其他功能配置 (实验性内容，不推荐使用)"
        local enabled_features=()
        [ "${BUILD_CFG[use_zram]}" = "true" ] && enabled_features+=("ZRAM")
        [ "${BUILD_CFG[use_rekernel]}" = "true" ] && enabled_features+=("Re-Kernel")
        [[ "${BUILD_CFG[use_kpm]}" == enabled* ]] && enabled_features+=("KPM")
        if [ ${#enabled_features[@]} -gt 0 ]; then
            local joined=$(IFS=', '; echo "${enabled_features[*]}")
            echo -e " ${GREEN}→ ${joined}${NC}"
        else
            echo ""
        fi
        echo -ne "  0) 可选配置 (版本名, 构建时间, 输出目录)"
        local optional_items=()
        [ -n "${BUILD_CFG[custom_version]}" ] && optional_items+=("版本名:${BUILD_CFG[custom_version]}")
        [ -n "${BUILD_CFG[build_time]}" ] && optional_items+=("时间:${BUILD_CFG[build_time]}")
        [ -n "${BUILD_CFG[output_dir]}" ] && optional_items+=("输出:${BUILD_CFG[output_dir]}")
        if [ ${#optional_items[@]} -gt 0 ]; then
            local joined_opt=$(IFS=' '; echo "${optional_items[*]}")
            echo -e " ${GREEN}→ ${joined_opt}${NC}"
        else
            echo ""
        fi
        echo ""
        echo "  ${GREEN}S) 查看配置摘要 & 开始编译${NC}"
        echo "  ${YELLOW}Q) 退出${NC}"
        echo ""

        read -r -p "$(echo -e "${YELLOW}请选择 [0-9 / S / Q]:${NC} ")" choice

        case "${choice,,}" in
            1) config_mirrors ;;
            2)
                setup_dependencies
                setup_ccache
                ;;
            3) fetch_kernel_source ;;
            4) config_kernel_from_source_package ;;
            5) config_kernel_source ;;
            6) config_kernel_version ;;
            7) config_kernelsu ;;
            8) config_droidspaces ;;
            9) config_features ;;
            0) config_optional ;;
            s)
                # 验证必要配置
                if ([ -z "${BUILD_CFG[kernel_source]}" ] && [ -z "${BUILD_CFG[kernel_source_tarball]}" ]) || [ -z "${BUILD_CFG[android_version]}" ] || [ -z "${BUILD_CFG[kernel_version]}" ]; then
                    log_error "请先配置内核源码路径和内核版本!"
                    continue
                fi

                extract_kernel_source_tarball

                show_config_summary

                if confirm "确认配置无误，开始编译?" "y"; then
                    save_config
                    run_build
                    local build_ret=$?
                    _cleanup_extracted_source
                    return $build_ret
                else
                    log_info "返回主菜单"
                fi
                ;;
            q)
                if [ -n "${BUILD_CFG[kernel_source]}" ] || [ -n "${BUILD_CFG[android_version]}" ]; then
                    if confirm "是否保存当前配置?" "y"; then
                        save_config
                    fi
                fi
                log_info "退出"
                exit 0
                ;;
            *)
                log_error "无效选择: $choice"
                ;;
        esac
    done
}

# 编译完成后清理解压的源码目录
_cleanup_extracted_source() {
    local tarball="${BUILD_CFG[kernel_source_tarball]:-}"
    local extracted="${BUILD_CFG[kernel_source]}"
    # 仅清理解压产生的子目录，防止误删项目根目录
    if [ -n "$tarball" ] && [ -n "$extracted" ] && [ -d "$extracted" ] && [ "$extracted" != "$PROJECT_ROOT" ]; then
        log_info "清理解压的源码目录: $extracted"
        rm -rf "$extracted"
    fi
}

# ================================================================
# 入口
# ================================================================

case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --quick)
        load_mirror_config
        if load_config; then
            log_info "使用保存的配置快速构建..."
            show_config_summary
            extract_kernel_source_tarball || exit 1
            run_build
            _cleanup_extracted_source
        else
            log_error "未找到保存的配置，请先运行 ./build_kernel.sh 进行配置"
            exit 1
        fi
        ;;
    --config)
        load_mirror_config
        load_config 2>/dev/null || true
        config_mirrors
        config_kernel_source
        config_kernel_version
        config_kernelsu
        config_droidspaces
        config_features
        config_optional
        show_config_summary
        save_config
        log_info "配置已保存"
        ;;
    --reset)
        rm -f "$BUILD_CONFIG_FILE"
        log_info "已清除保存的配置"
        ;;
    *)
        load_mirror_config
        load_config 2>/dev/null || true
        main_menu
        ;;
esac
