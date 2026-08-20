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
    echo "$(txt "GKI 内核本地编译工具" "GKI Local Kernel Builder")"
    echo ""
    echo "$(txt "用法" "Usage"): $0 [$(txt "选项" "options")]"
    echo ""
    echo "$(txt "选项" "Options"):"
    echo "  --help       $(txt "显示此帮助信息" "Show this help message")"
    echo "  --quick      $(txt "使用上次保存的配置直接编译" "Build directly with the saved config")"
    echo "  --config     $(txt "仅配置，不编译" "Configure only, do not build")"
    echo "  --reset      $(txt "清除保存的配置" "Clear the saved config")"
    echo ""
    echo "$(txt "首次运行将进入交互式配置菜单。" "First run opens the interactive configuration menu.")"
}

# --- 保存配置 ---
save_config() {
    cat > "$BUILD_CONFIG_FILE" << EOF
# GKI 编译配置 - $(date)
APP_LANG="${APP_LANG:-zh}"
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
CVE_2026_43499_PATCH="${BUILD_CFG[cve_2026_43499_patch]:-false}"
DROIDSPACES="${BUILD_CFG[droidspaces]}"
# 如果有压缩包，kernel_source 由解压自动管理，不持久化
if [ -z "${BUILD_CFG[kernel_source_tarball]:-}" ]; then
    KERNEL_SOURCE="${BUILD_CFG[kernel_source]}"
else
    KERNEL_SOURCE=""
fi
KERNEL_SOURCE_TARBALL="${BUILD_CFG[kernel_source_tarball]:-}"
OUTPUT_DIR="${BUILD_CFG[output_dir]}"
PACKAGE_BOOT="${BUILD_CFG[package_boot]}"
EOF
    CONFIG_DIRTY=false
    log_info "$(txt "配置已保存到" "Config saved to") $BUILD_CONFIG_FILE"
}

# --- 加载配置 ---
load_config() {
    if [ -f "$BUILD_CONFIG_FILE" ]; then
        source "$BUILD_CONFIG_FILE"
        case "${APP_LANG:-zh}" in
            zh|en) ;;
            *) APP_LANG="zh" ;;
        esac
        export APP_LANG
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
        BUILD_CFG[use_kpm]="${USE_KPM:-disabled}"
        BUILD_CFG[use_rekernel]="${USE_REKERNEL:-false}"
        BUILD_CFG[cve_2026_43499_patch]="${CVE_2026_43499_PATCH:-false}"
        BUILD_CFG[droidspaces]="${DROIDSPACES:-off}"
        BUILD_CFG[kernel_source]="${KERNEL_SOURCE:-}"
        BUILD_CFG[kernel_source_tarball]="${KERNEL_SOURCE_TARBALL:-}"
        BUILD_CFG[output_dir]="${OUTPUT_DIR:-$PROJECT_ROOT/build/out}"
        BUILD_CFG[package_boot]="${PACKAGE_BOOT:-true}"
        return 0
    fi
    return 1
}

config_language() {
    choose_language
    CONFIG_DIRTY=true
    log_info "$(txt "语言已设置为" "Language set to"): $(language_name)"
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
        echo -e "${CYAN}─── $(txt "GitHub 镜像源" "GitHub Mirror") ───${NC}"
        echo -e "$(txt "当前" "Current"): ${GREEN}${CUSTOM_GITHUB_MIRROR:-$(txt "未设置 (直连)" "Not set (direct)")}${NC}"
        echo ""

        local opts=("$(txt "保持当前" "Keep current")" "$(txt "清除 (直连)" "Clear (direct)")")
        for m in "${GITHUB_MIRROR_PRESETS[@]}"; do
            opts+=("$m")
        done
        opts+=("$(txt "自定义输入" "Custom input")")

        local result=$(select_option "$(txt "选择 GitHub 镜像:" "Select GitHub mirror:")" "${opts[@]}")
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
                    read -r -p "$(echo -e "${YELLOW}$(txt "输入 GitHub 镜像前缀:" "Enter GitHub mirror prefix:")${NC} ")" val
                    CUSTOM_GITHUB_MIRROR="${val:-}"
                fi
                ;;
        esac
        echo -e "  GitHub $(txt "镜像" "mirror") → ${GREEN}${CUSTOM_GITHUB_MIRROR:-$(txt "直连" "direct")}${NC}"

        # 选择后询问是否测速
        if [ -n "${CUSTOM_GITHUB_MIRROR:-}" ]; then
            if confirm "$(txt "是否对所选镜像进行测速（拉取约23M的视频文件，测速设置30s超时）?" "Speed test the selected mirror? This downloads a ~23MB video with a 30s timeout.")" "y"; then
                _speedtest_single "$CUSTOM_GITHUB_MIRROR"
                if confirm "$(txt "是否使用该镜像源?" "Use this mirror?")" "y"; then
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
    log_info "$(txt "镜像配置已保存" "Mirror config saved")"
}

_speedtest_single() {
    local mirror="$1"
    local test_file="https://github.com/404-GCross/Droidspaces_GKI_Buildin_Local/blob/main/speedtest.mp4?raw=1"
    local timeout=30
    local url="${mirror}${test_file}"

    echo ""
    echo -e "${CYAN}─── $(txt "镜像测速" "Mirror Speed Test") ───${NC}"
    echo -e "$(txt "镜像" "Mirror"): ${mirror}"
    echo ""

    echo -n "  $(txt "下载测速中" "Testing download speed") ... "
    local metrics="" ret=0
    metrics=$(curl -LSs -o /dev/null --max-time "$timeout" \
        -w "%{http_code}"$'\t'"%{size_download}"$'\t'"%{speed_download}"$'\t'"%{time_total}" \
        "$url" 2>/dev/null) || ret=$?

    local http_code="" size="" speed_bps="" elapsed_sec=""
    IFS=$'\t' read -r http_code size speed_bps elapsed_sec <<< "$metrics"

    if { [ $ret -ne 0 ] && [ $ret -ne 28 ]; } || [[ ! "$http_code" =~ ^2 ]] || [[ ! "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt 1048576 ]; then
        echo ""
        echo -e "  ${RED}$(txt "测速失败" "Speed test failed") (HTTP:${http_code:-$(txt "无响应" "no response")}, $(txt "下载" "downloaded"):${size:-0}B)${NC}"
        return
    fi

    local speed_text size_text elapsed_text
    speed_text=$(awk -v bps="$speed_bps" 'BEGIN { if (bps >= 1048576) printf "%.2f MB/s", bps / 1048576; else printf "%.0f KB/s", bps / 1024 }')
    size_text=$(awk -v bytes="$size" 'BEGIN { if (bytes >= 1048576) printf "%.2f MB", bytes / 1048576; else printf "%.0f KB", bytes / 1024 }')
    elapsed_text=$(awk -v sec="$elapsed_sec" 'BEGIN { printf "%.2fs", sec }')

    echo ""
    echo -e "  $(txt "状态" "Status"): HTTP ${http_code}"
    echo -e "  $(txt "耗时" "Elapsed"): ${elapsed_text}"
    echo -e "  $(txt "大小" "Size"): ${size_text}"
    echo -e "  $(txt "速度" "Speed"): ${GREEN}${speed_text}${NC}"
}

# 从 KERNEL_VERSIONS 表查找补丁级别
_lookup_os_patch_level() {
    local key="${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}"
    local data="${KERNEL_VERSIONS[$key]:-}"

    BUILD_CFG[os_patch_level]=""
    BUILD_CFG[revision]=""

    [ -z "$data" ] && return

    local label sub patch rev
    while IFS='|' read -r label sub patch rev; do
        [ -z "$sub" ] && continue
        if [ "$sub" = "${BUILD_CFG[sub_level]}" ]; then
            [ -n "$patch" ] && BUILD_CFG[os_patch_level]="$patch"
            [ -n "$rev" ] && BUILD_CFG[revision]="$rev"
            return 0
        fi
    done <<< "$data" || true

    # GKI-Kernel-Source_Fetch resolves X/LTS to the real sublevel before printing
    # the target version, e.g. android16-6.12-92. Map that back to the X row.
    local lts_regex='lts[[:space:]]*->[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)'
    while IFS='|' read -r label sub patch rev; do
        [ -z "$label" ] && continue
        if [[ "$label" =~ $lts_regex ]]; then
            local lts_kernel="${BASH_REMATCH[1]}"
            local lts_sub="${lts_kernel##*.}"
            if [ "$lts_sub" = "${BUILD_CFG[sub_level]}" ]; then
                [ -n "$patch" ] && BUILD_CFG[os_patch_level]="$patch"
                [ -n "$rev" ] && BUILD_CFG[revision]="$rev"
                return 0
            fi
        fi
    done <<< "$data" || true
}

_set_kernel_version_from_id() {
    local version_id="$1"
    if [[ "$version_id" =~ ^(android[0-9]+)-([0-9]+\.[0-9]+)-(.+)$ ]]; then
        BUILD_CFG[android_version]="${BASH_REMATCH[1]}"
        BUILD_CFG[kernel_version]="${BASH_REMATCH[2]}"
        BUILD_CFG[sub_level]="${BASH_REMATCH[3]}"
        _lookup_os_patch_level
        return 0
    fi
    return 1
}

# 获取内核源码 (远程脚本)
fetch_kernel_source() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ $(txt "获取内核源码" "Fetch Kernel Source") ═══${NC}"
    echo ""

    local script_url="https://raw.githubusercontent.com/404-GCross/GKI-Kernel-Source_Fetch/refs/heads/main/fetch_kernel_source_no-extract.sh"
    local actual_url=$(mirror_github "$script_url")

    log_info "$(txt "正在获取内核源码拉取脚本..." "Fetching kernel source fetch script...")"
    log_info "$(txt "脚本地址" "Script URL"): $actual_url"
    log_info "$(txt "拉取脚本语言" "Fetch script language"): ${APP_LANG:-zh}"

    mkdir -p "$HOME/kernel-sources"
    cd "$HOME"

    local tmp_out="/tmp/fetch_kernel_output.log"
    local ret=0
    SCRIPT_LANG="${APP_LANG:-zh}" bash <(curl -LSs "$actual_url") 2>&1 | tee "$tmp_out" || ret=${PIPESTATUS[0]}
    ret=${ret:-${PIPESTATUS[0]}}

    if [ $ret -ne 0 ]; then
        log_error "$(txt "内核源码获取失败" "Kernel source fetch failed") ($(txt "退出码" "exit code"): $ret)"
        rm -f "$tmp_out"
        return 1
    fi

    log_info "$(txt "内核源码获取完成" "Kernel source fetch completed")"

    # 从脚本输出中解析版本号 (格式: "目标版本：android12-5.10-246" / "Target version: android12-5.10-246")
    # 先去除 ANSI 转义码再解析，否则颜色码会导致行首匹配失败
    local clean_output
    clean_output=$(sed 's/\x1b\[[0-9;]*m//g' "$tmp_out")
    local version_line=$(printf '%s\n' "$clean_output" | sed -n -E 's/^.*(目标版本：|Target version:)[[:space:]]*//p' | tail -1)
    if [ -n "$version_line" ]; then
        if _set_kernel_version_from_id "$version_line"; then
            log_info "$(txt "已自动设置内核版本" "Auto-detected kernel version"): ${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}-${BUILD_CFG[sub_level]}"
        fi
    fi

    # 从脚本输出中解析源码路径/压缩包路径。
    # no-extract 脚本默认只输出压缩包路径，英文界面输出 Source/Archive path。
    local source_path=$(printf '%s\n' "$clean_output" | sed -n -E 's/^(源码路径：|Source path:)[[:space:]]*//p' | tail -1)
    local archive_path=$(printf '%s\n' "$clean_output" | sed -n -E 's/^(压缩包路径：|Archive path:)[[:space:]]*//p' | tail -1)
    rm -f "$tmp_out"

    if [ -n "$archive_path" ] && [ -f "$archive_path" ]; then
        BUILD_CFG[kernel_source_tarball]="$archive_path"
        BUILD_CFG[kernel_source]=""
        local archive_name=$(basename "$archive_path")
        if [[ "$archive_name" =~ ^kernel-source-(android[0-9]+-[0-9]+\.[0-9]+-.+)\.tar\.gz$ ]]; then
            _set_kernel_version_from_id "${BASH_REMATCH[1]}" || true
        fi
        log_info "$(txt "已自动设置内核源码包" "Auto-detected kernel source archive"): $(basename "$archive_path")"
    elif [ -n "$source_path" ] && [ -d "$source_path" ]; then
        BUILD_CFG[kernel_source]="$source_path"
        BUILD_CFG[kernel_source_tarball]=""
        log_info "$(txt "已自动设置内核源码路径" "Auto-detected kernel source path"): ${BUILD_CFG[kernel_source]}"
    elif [ -z "${BUILD_CFG[kernel_source]}" ] && [ -d "$PROJECT_ROOT/GKI-Kernel-Source" ]; then
        BUILD_CFG[kernel_source]="$PROJECT_ROOT/GKI-Kernel-Source"
        log_info "$(txt "已自动设置内核源码路径" "Auto-detected kernel source path"): ${BUILD_CFG[kernel_source]}"
    else
        log_warn "$(txt "未能自动检测源码路径，请手动设置" "Could not auto-detect the source path; please set it manually")"
    fi

    # 扫描 kernel-sources/ 中的压缩包，自动设置
    shopt -s nullglob
    local tarballs=("$HOME/kernel-sources"/*.tar.gz)
    shopt -u nullglob
    if [ -z "${BUILD_CFG[kernel_source_tarball]:-}" ] && [ ${#tarballs[@]} -gt 0 ] && [ -n "${BUILD_CFG[android_version]}" ]; then
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
        log_info "$(txt "已自动设置内核源码包" "Auto-detected kernel source archive"): $(basename "$matched")"
    fi
}

# 内核源码路径选择
config_kernel_source() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ $(txt "内核源码路径" "Kernel Source Path") ═══${NC}"
    echo ""
    echo -e "$(txt "当前路径" "Current path"): ${YELLOW}${BUILD_CFG[kernel_source]:-$(txt "未设置" "Not set")}${NC}"
    echo ""

    read -r -p "$(echo -e "${YELLOW}$(txt "GKI 源码目录路径 (包含 common/ 子目录):" "GKI source directory path (must contain common/):")${NC} ")" src
    if [ -d "$src/common" ]; then
        BUILD_CFG[kernel_source]=$(get_abs_path "$src")
        BUILD_CFG[kernel_source_tarball]=""  # 手动路径，编译时跳过解压
        log_info "$(txt "已选择 GKI 源码" "Selected GKI source"): ${BUILD_CFG[kernel_source]}"
    else
        log_error "$(txt "目录中未找到 common/ 子目录，不是有效的 GKI 源码目录" "common/ was not found; this is not a valid GKI source directory")"
        config_kernel_source
        return
    fi
}

# ================================================================
# 预定义内核版本组合 (对齐 GKI-Kernel-Source_Fetch 的 fetch_kernel_source_no-extract.sh)
# 格式: "显示名|sub_level|os_patch_level|revision"
# ================================================================

declare -A KERNEL_VERSIONS
KERNEL_VERSION_KEYS=(
    "android12-5.10"
    "android13-5.15"
    "android14-6.1"
    "android15-6.6"
    "android16-6.12"
    "android17-6.18"
)

# Android 12 - 5.10
KERNEL_VERSIONS["android12-5.10"]="
5.10.43  (2021-10)|43|2021-10|
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
5.10.256 (2026-07)|256|2026-07|
5.10.X   (lts -> 5.10.264)|X|lts|r1
"

# Android 13 - 5.15
KERNEL_VERSIONS["android13-5.15"]="
5.15.41  (2022-11)|41|2022-11|
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
5.15.207 (2026-07)|207|2026-07|
5.15.X   (lts -> 5.15.211)|X|lts|
"

# Android 14 - 6.1
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
6.1.172 (2026-06)|172|2026-06|
6.1.173 (2026-07)|173|2026-07|
6.1.X   (lts -> 6.1.176)|X|lts|
"

# Android 15 - 6.6
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
6.6.139 (2026-07)|139|2026-07|
6.6.X   (lts -> 6.6.142)|X|lts|
"

# Android 16 - 6.12
KERNEL_VERSIONS["android16-6.12"]="
6.12.23 (2025-06)|23|2025-06|
6.12.30 (2025-07)|30|2025-07|
6.12.38 (2025-09)|38|2025-09|
6.12.58 (2025-12)|58|2025-12|
6.12.69 (2026-03)|69|2026-03|
6.12.81 (2026-06)|81|2026-06|
6.12.X  (lts -> 6.12.92)|X|lts|
"

# Android 17 - 6.18
KERNEL_VERSIONS["android17-6.18"]="
6.18.21 (2026-06)|21|2026-06|
6.18.X  (lts -> 6.18.32)|X|lts|
"

# 内核版本选择菜单
config_kernel_version() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ $(txt "内核版本选择" "Kernel Version Selection") ═══${NC}"
    echo ""

    local versions=(
        "Android 12 - 5.10 (android12-5.10)"
        "Android 13 - 5.15 (android13-5.15)"
        "Android 14 - 6.1  (android14-6.1)"
        "Android 15 - 6.6  (android15-6.6)"
        "Android 16 - 6.12 (android16-6.12)"
        "Android 17 - 6.18 (android17-6.18)"
    )
    local result=$(select_option "$(txt "选择目标 Android/内核版本:" "Select target Android/kernel version:")" "${versions[@]}")
    local idx="${result%%$'\t'*}"

    local key="${KERNEL_VERSION_KEYS[$idx]}"
    local av="${key%-*}"
    local kv="${key##*-}"

    BUILD_CFG[android_version]="$av"
    BUILD_CFG[kernel_version]="$kv"
    log_info "$(txt "已选择" "Selected"): ${av} / ${kv}"

    # --- 选择子版本 (附带补丁级别) ---
    echo ""
    echo -e "${CYAN}$(txt "选择子版本号 (安全补丁级别已自动关联):" "Select sublevel (security patch level is linked automatically):")${NC}"

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

    log_info "$(txt "内核" "Kernel"): ${kv}.${BUILD_CFG[sub_level]}  $(txt "补丁" "Patch"): ${BUILD_CFG[os_patch_level]}  $(txt "修订" "Revision"): ${BUILD_CFG[revision]:-$(txt "无" "none")}"
}

# KernelSU 配置
config_kernelsu() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ KernelSU $(txt "配置" "Configuration") ═══${NC}"
    echo ""

    local variants=("None ($(txt "纯GKI内核/无root" "pure GKI/no root"))" "ReSukiSU ($(txt "推荐" "recommended"))" "Official ($(txt "KernelSU官方" "official KernelSU"))")
    local result=$(select_option "$(txt "选择 KernelSU 变体:" "Select KernelSU variant:")" "${variants[@]}")
    local idx="${result%%$'\t'*}"

    case $idx in
        0) BUILD_CFG[ksu_variant]="None" ;;
        1) BUILD_CFG[ksu_variant]="ReSukiSU" ;;
        2) BUILD_CFG[ksu_variant]="Official" ;;
    esac

    # None = 纯 GKI，不需要选择分支
    if [ "${BUILD_CFG[ksu_variant]}" = "None" ]; then
        BUILD_CFG[ksu_branch]="-"
        BUILD_CFG[use_kpm]="disabled"
        log_info "KernelSU: $(txt "无 (纯GKI内核)" "None (pure GKI)")"
        return 0
    fi

    local branches=("$(txt "Stable(标准)" "Stable")" "$(txt "Dev(开发)" "Dev")")
    local branch_result=$(select_option "$(txt "选择 KSU 分支:" "Select KSU branch:")" "${branches[@]}")
    idx="${branch_result%%$'\t'*}"
    case $idx in
        0) BUILD_CFG[ksu_branch]="Stable(标准)" ;;
        1) BUILD_CFG[ksu_branch]="Dev(开发)" ;;
    esac

    log_info "KernelSU: ${BUILD_CFG[ksu_variant]} / $(display_ksu_branch "${BUILD_CFG[ksu_branch]}")"
}

# Droidspaces 容器支持配置
config_droidspaces() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ Droidspaces $(txt "容器支持" "Container Support") ═══${NC}"
    echo ""

    local ds_opts=("$(txt "off (关闭)" "Off")" "678" "123" "345")
    case "${BUILD_CFG[kernel_version]}" in
        6.12|6.18)
            ds_opts=("$(txt "off (关闭)" "Off")" "$(txt "on (开启)" "On")")
            ;;
    esac
    local ds_result=$(select_option "Droidspaces $(txt "容器支持:" "container support:")" "${ds_opts[@]}")
    local idx="${ds_result%%$'\t'*}"
    case $idx in
        0) BUILD_CFG[droidspaces]="off" ;;
        1)
            case "${BUILD_CFG[kernel_version]}" in
                6.12|6.18) BUILD_CFG[droidspaces]="on" ;;
                *) BUILD_CFG[droidspaces]="678" ;;
            esac
            ;;
        2) BUILD_CFG[droidspaces]="123" ;;
        3) BUILD_CFG[droidspaces]="345" ;;
    esac
    echo -e "  Droidspaces: ${GREEN}${BUILD_CFG[droidspaces]}${NC}"

    if [ "${BUILD_CFG[droidspaces]}" != "off" ]; then
        BUILD_CFG[cve_2026_43499_patch]="true"
        echo -e "  $(txt "CVE修复链" "CVE fix chain"): ${GREEN}$(txt "默认开启 (Droidspaces)" "Enabled by default (Droidspaces)")${NC}"
    fi
    CONFIG_DIRTY=true
}

# 功能开关配置
config_features() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ $(txt "其他功能配置" "Additional Feature Configuration") ═══${NC}"
    echo ""

    # ZRAM
    case "${BUILD_CFG[kernel_version]}" in
        6.12|6.18)
            BUILD_CFG[use_zram]="false"
            echo -e "  ZRAM: ${YELLOW}$(txt "6.12/6.18 暂不启用，已按参考项目禁用" "Disabled for 6.12/6.18 to match the reference project")${NC}"
            ;;
        *)
            if confirm "$(txt "启用 ZRAM 增强算法 (LZ4KD)?" "Enable ZRAM enhanced algorithms (LZ4KD)?")" "n"; then
                BUILD_CFG[use_zram]="true"
            else
                BUILD_CFG[use_zram]="false"
            fi
            echo -e "  ZRAM: ${GREEN}$(status_bool "${BUILD_CFG[use_zram]}")${NC}"
            ;;
    esac

    # Re-Kernel
    if confirm "$(txt "启用 Re-Kernel 驱动?" "Enable Re-Kernel driver?")" "n"; then
        BUILD_CFG[use_rekernel]="true"
    else
        BUILD_CFG[use_rekernel]="false"
    fi
    echo -e "  Re-Kernel: ${GREEN}$(status_bool "${BUILD_CFG[use_rekernel]}")${NC}"

    # CVE-2026-43499 / CVE-2026-53163 rtmutex 修复链
    local cve_default="n"
    local cve_prompt
    if [ "${BUILD_CFG[droidspaces]:-off}" != "off" ]; then
        cve_default="y"
        cve_prompt="$(txt "应用 CVE-2026-43499 rtmutex 修复链? (Droidspaces 已启用，默认开启)" "Apply CVE-2026-43499 rtmutex fix chain? (Droidspaces enabled, default: on)")"
    else
        cve_prompt="$(txt "应用 CVE-2026-43499 rtmutex 修复链? (默认关闭)" "Apply CVE-2026-43499 rtmutex fix chain? (default: off)")"
    fi

    if confirm "$cve_prompt" "$cve_default"; then
        BUILD_CFG[cve_2026_43499_patch]="true"
    else
        BUILD_CFG[cve_2026_43499_patch]="false"
    fi
    echo -e "  $(txt "CVE修复链" "CVE fix chain"): ${GREEN}$(status_bool "${BUILD_CFG[cve_2026_43499_patch]}")${NC}"

    # KPM — 仅在使用 KernelSU 时可选
    if [ "${BUILD_CFG[ksu_variant]}" = "None" ]; then
        BUILD_CFG[use_kpm]="disabled"
        echo -e "  KPM: ${RED}$(txt "不可用 (纯GKI内核)" "Unavailable (pure GKI)")${NC}"
    else
        local kpm_opts=("$(txt "disabled (关闭)" "Disabled")" "$(txt "enabled (开启)" "Enabled")")
        local kpm_result=$(select_option "KPM $(txt "功能:" "feature:")" "${kpm_opts[@]}")
        idx="${kpm_result%%$'\t'*}"
        case $idx in
            0) BUILD_CFG[use_kpm]="disabled" ;;
            1) BUILD_CFG[use_kpm]="enabled" ;;
        esac
        echo -e "  KPM: ${GREEN}$(display_kpm "${BUILD_CFG[use_kpm]}")${NC}"
    fi

    # 默认打包 AnyKernel3
    BUILD_CFG[package_boot]="true"
    echo -e "  $(txt "打包 AK3" "Package AK3"):   ${GREEN}$(status_bool true)${NC}"
}

# 可选配置
config_optional() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ $(txt "可选配置" "Optional Configuration") ═══${NC}"
    echo ""

    read -r -p "$(echo -e "${YELLOW}$(txt "自定义版本名 (可选, 留空跳过; 不宜过长，过长会导致编译失败):" "Custom version name (optional; leave blank to skip; keep it short):")${NC} ")" ver
    BUILD_CFG[custom_version]="$ver"

    read -r -p "$(echo -e "${YELLOW}$(txt "自定义构建时间 (可选, N或留空=当前UTC时间):" "Custom build time (optional, N/blank = current UTC):")${NC} ")" btime
    BUILD_CFG[build_time]="$btime"

    read -r -p "$(echo -e "${YELLOW}$(txt "输出目录 (留空使用默认):" "Output directory (blank = default):")${NC} ")" outdir
    BUILD_CFG[output_dir]="${outdir:-$PROJECT_ROOT/build/out}"

    echo ""
    echo -e "  $(txt "自定义版本" "Custom version"): ${GREEN}${BUILD_CFG[custom_version]:-$(txt "未设置" "Not set")}${NC}"
    echo -e "  $(txt "构建时间" "Build time"):   ${GREEN}${BUILD_CFG[build_time]:-$(txt "当前UTC" "Current UTC")}${NC}"
    echo -e "  $(txt "输出目录" "Output dir"):   ${GREEN}${BUILD_CFG[output_dir]}${NC}"
}

# 显示配置摘要
show_config_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    if [ "${APP_LANG:-zh}" = "en" ]; then
        echo -e "${CYAN}${BOLD}║           Build Configuration Summary        ║${NC}"
    else
        echo -e "${CYAN}${BOLD}║           构建配置摘要                       ║${NC}"
    fi
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    if [ -n "${BUILD_CFG[kernel_source]}" ]; then
        echo -e "  ${BOLD}$(txt "内核源码" "Kernel source")${NC}      ${GREEN}${BUILD_CFG[kernel_source]}${NC}"
    elif [ -n "${BUILD_CFG[kernel_source_tarball]:-}" ]; then
        echo -e "  ${BOLD}$(txt "源码包" "Source archive")${NC}        ${GREEN}$(basename "${BUILD_CFG[kernel_source_tarball]:-}")${NC} ${YELLOW}($(txt "编译时解压" "extract during build"))${NC}"
    else
        echo -e "  ${BOLD}$(txt "内核源码" "Kernel source")${NC}      ${RED}$(txt "未设置!" "Not set!")${NC}"
    fi
    echo -e "  ${BOLD}$(txt "语言" "Language")${NC}      ${GREEN}$(language_name)${NC}"
    echo -e "  ${BOLD}$(txt "Android版本" "Android version")${NC}    ${GREEN}${BUILD_CFG[android_version]:-$(txt "未设置!" "Not set!")}${NC}"
    echo -e "  ${BOLD}$(txt "内核版本" "Kernel version")${NC}      ${GREEN}${BUILD_CFG[kernel_version]:-$(txt "未设置!" "Not set!")}${NC}"
    echo -e "  ${BOLD}$(txt "子版本号" "Sublevel")${NC}      ${GREEN}${BUILD_CFG[sub_level]:-$(txt "未设置!" "Not set!")}${NC}"
    if [ -n "${BUILD_CFG[revision]}" ]; then
        echo -e "  ${BOLD}$(txt "修订版本" "Revision")${NC}      ${GREEN}${BUILD_CFG[revision]}${NC}"
    fi
    if [ "${BUILD_CFG[ksu_variant]}" = "None" ]; then
        echo -e "  ${BOLD}$(txt "KSU变体" "KSU variant")${NC}       ${GREEN}$(txt "纯GKI内核 (无root)" "Pure GKI kernel (no root)")${NC}"
    else
        echo -e "  ${BOLD}$(txt "KSU变体" "KSU variant")${NC}       ${GREEN}${BUILD_CFG[ksu_variant]}${NC}"
        echo -e "  ${BOLD}$(txt "KSU分支" "KSU branch")${NC}       ${GREEN}$(display_ksu_branch "${BUILD_CFG[ksu_branch]}")${NC}"
    fi
    echo ""
    echo -e "  ${BOLD}$(txt "功能开关:" "Feature switches:")${NC}"
    echo -e "    ZRAM$(txt "增强" " enhancement"):    $(status_bool "${BUILD_CFG[use_zram]}")"
    echo -e "    Re-Kernel:   $(status_bool "${BUILD_CFG[use_rekernel]}")"
    echo -e "    $(txt "CVE修复链" "CVE fix chain"):   $(status_bool "${BUILD_CFG[cve_2026_43499_patch]:-false}")"
    echo -e "    KPM:         $(display_kpm "${BUILD_CFG[use_kpm]}")"
    echo -e "    Droidspaces: ${BUILD_CFG[droidspaces]}"
    echo -e "    $(txt "打包 AK3" "Package AK3"):     $(txt "默认开启" "Enabled by default")"
    echo ""
    echo -e "  ${BOLD}$(txt "镜像源:" "Mirrors:")${NC}"
    echo -e "    GitHub:  ${GREEN}${CUSTOM_GITHUB_MIRROR:-$(txt "直连" "direct")}${NC}"
    echo ""
    echo -e "  ${BOLD}$(txt "构建时间" "Build time")${NC}      ${GREEN}${BUILD_CFG[build_time]:-$(txt "当前UTC" "Current UTC")}${NC}"
    echo -e "  ${BOLD}$(txt "输出版本" "Output version")${NC}      ${GREEN}${BUILD_CFG[custom_version]:-$(txt "自动生成" "Auto-generated")}${NC}"
    echo -e "  ${BOLD}$(txt "输出目录" "Output dir")${NC}      ${GREEN}${BUILD_CFG[output_dir]}${NC}"
    echo ""
}

# 选择脚本获取的内核源码
config_kernel_from_source_package() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ $(txt "选择脚本获取的内核源码" "Select Downloaded Kernel Source") ═══${NC}"
    echo ""

    local src_dir="$HOME/kernel-sources"
    if [ ! -d "$src_dir" ]; then
        log_error "$(txt "内核源码目录不存在" "Kernel source directory does not exist"): $src_dir"
        log_info "$(txt "请先执行 '获取内核源码' 下载源码包" "Run 'Fetch Kernel Source' first to download source archives")"
        return 1
    fi

    shopt -s nullglob
    local tarballs=("$src_dir"/*.tar.gz)
    shopt -u nullglob

    if [ ${#tarballs[@]} -eq 0 ]; then
        log_error "$(txt "未找到内核源码压缩包 (.tar.gz)" "No kernel source archive found (.tar.gz)")"
        log_info "$(txt "请先执行 '获取内核源码' 下载源码包" "Run 'Fetch Kernel Source' first to download source archives")"
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

    local result=$(select_option "$(txt "选择内核源码:" "Select kernel source:")" "${labels[@]}")
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
        log_info "$(txt "已识别内核版本" "Detected kernel version"): ${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}-${BUILD_CFG[sub_level]}"
        log_info "$(txt "源码包" "Source archive"): $chosen ($(txt "将在编译时解压" "will be extracted during build"))"
    else
        log_warn "$(txt "无法从文件名识别内核版本" "Could not detect kernel version from filename"): $name"
        log_info "$(txt "参考格式" "Expected format"): kernel-source-android17-6.18-21.tar.gz"
    fi
}

# ================================================================
# 解压内核源码压缩包
# ================================================================
extract_kernel_source_tarball() {
    local tarball="${BUILD_CFG[kernel_source_tarball]:-}"
    [ -z "$tarball" ] && return 0

    if [ ! -f "$tarball" ]; then
        log_error "$(txt "源码包不存在" "Source archive does not exist"): $tarball"
        return 1
    fi

    if [ -n "${BUILD_CFG[kernel_source]}" ] && { [ -d "${BUILD_CFG[kernel_source]}/common" ] || [ -f "${BUILD_CFG[kernel_source]}/Makefile" ]; }; then
        return 0
    fi

    log_step "$(txt "解压内核源码包" "Extract kernel source archive")"
    local extracted_dir="$HOME/kernel-sources/$(basename "${tarball%.tar.gz}")"

    if [ -d "$extracted_dir/common" ] || [ -f "$extracted_dir/Makefile" ]; then
        log_info "$(txt "已存在有效源码目录" "Found existing valid source directory"): $extracted_dir"
    else
        if [ -d "$extracted_dir" ]; then
            log_warn "$(txt "已存在的解压目录无效，将重新解压" "Existing extracted directory is invalid; re-extracting"): $extracted_dir"
            local backup_dir="${extracted_dir}.invalid-$(date +%Y%m%d%H%M%S)-$$"
            mv "$extracted_dir" "$backup_dir"
            log_warn "$(txt "旧目录已保留为" "Old directory kept as"): $backup_dir"
        fi
        mkdir -p "$extracted_dir"
        if ! tar -xzf "$tarball" -C "$extracted_dir" --strip-components=1; then
            log_error "$(txt "源码包解压失败" "Failed to extract source archive"): $tarball"
            return 1
        fi
        # 删除压缩包自带的 Bazel 缓存（含其他机器的硬编码路径）
        rm -rf "$extracted_dir/out" 2>/dev/null || true
    fi

    if [ -d "$extracted_dir/common" ] || [ -f "$extracted_dir/Makefile" ]; then
        BUILD_CFG[kernel_source]="$extracted_dir"
        log_info "$(txt "内核源码路径" "Kernel source path"): $extracted_dir"
    else
        BUILD_CFG[kernel_source]=""
        log_error "$(txt "解压后未找到 common/ 或 Makefile，源码包可能不完整" "common/ or Makefile was not found after extraction; the source archive may be incomplete"): $extracted_dir"
        return 1
    fi
}

# ================================================================
# 主菜单
# ================================================================

main_menu() {
    show_banner

    if [ "${CONFIG_WAS_LOADED:-false}" = "true" ]; then
        echo -e "$(txt "已加载上次配置" "Loaded saved config"): ${YELLOW}$BUILD_CONFIG_FILE${NC}"
    fi

    # 加载镜像配置
    load_mirror_config

    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}═══ $(txt "主菜单" "Main Menu") ═══${NC}"
        echo -e "  ${RED}$(txt "米系6.12设备暂不可用，6.18请先小范围测试" "Xiaomi-family 6.12 devices are currently unsupported; test 6.18 carefully first")${NC}"
        echo ""
        echo -e "  ${YELLOW}$(txt "建议按顺序配置一遍" "Recommended: configure each item in order")${NC}"
        echo ""
        echo -ne "  1) $(txt "语言选择" "Language")"
        echo -e " ${GREEN}→ $(language_name)${NC}"
        echo -ne "  2) $(txt "镜像源配置" "Mirror configuration")"
        echo -e " ${GREEN}→ ${CUSTOM_GITHUB_MIRROR:-$(txt "直连" "direct")}${NC}"
        echo "  3) $(txt "安装编译依赖" "Install build dependencies")"
        echo "  4) $(txt "获取内核源码" "Fetch kernel source")"
        echo -ne "  5) $(txt "选择脚本获取的内核源码" "Select downloaded kernel source")"
        if [ -n "${BUILD_CFG[kernel_source_tarball]:-}" ]; then
            echo -e " ${GREEN}→ $(basename "${BUILD_CFG[kernel_source_tarball]:-}")${NC}"
        else
            echo ""
        fi
        echo -ne "  6) $(txt "选择内核源码路径" "Select kernel source path")"
        if [ -z "${BUILD_CFG[kernel_source_tarball]:-}" ] && [ -n "${BUILD_CFG[kernel_source]}" ]; then
            echo -e " ${GREEN}→ ${BUILD_CFG[kernel_source]}${NC}"
        else
            echo ""
        fi
        echo -ne "  7) $(txt "选择内核版本" "Select kernel version")"
        if [ -n "${BUILD_CFG[android_version]}" ] && [ -n "${BUILD_CFG[kernel_version]}" ]; then
            echo -e " ${GREEN}→ ${BUILD_CFG[android_version]}-${BUILD_CFG[kernel_version]}-${BUILD_CFG[sub_level]}${NC}"
        else
            echo ""
        fi
        echo -ne "  8) $(txt "配置 KernelSU" "Configure KernelSU")"
        if [ -n "${BUILD_CFG[ksu_variant]}" ]; then
            if [ "${BUILD_CFG[ksu_variant]}" = "None" ]; then
                echo -e " ${GREEN}→ $(txt "无 (纯GKI内核)" "None (pure GKI)")${NC}"
            else
                echo -e " ${GREEN}→ ${BUILD_CFG[ksu_variant]} ($(display_ksu_branch "${BUILD_CFG[ksu_branch]}"))${NC}"
            fi
        else
            echo ""
        fi
        echo -ne "  9) Droidspaces $(txt "容器支持" "container support")"
        if [ -n "${BUILD_CFG[droidspaces]}" ]; then
            echo -e " ${GREEN}→ ${BUILD_CFG[droidspaces]}${NC}"
        else
            echo ""
        fi
        echo -ne "  A) $(txt "其他功能配置 (实验性内容，不推荐使用)" "Additional features (experimental, not recommended)")"
        local enabled_features=()
        [ "${BUILD_CFG[use_zram]}" = "true" ] && enabled_features+=("ZRAM")
        [ "${BUILD_CFG[use_rekernel]}" = "true" ] && enabled_features+=("Re-Kernel")
        [ "${BUILD_CFG[cve_2026_43499_patch]:-false}" = "true" ] && enabled_features+=("$(txt "CVE修复链" "CVE fix chain")")
        [[ "${BUILD_CFG[use_kpm]}" == enabled* ]] && enabled_features+=("KPM")
        if [ ${#enabled_features[@]} -gt 0 ]; then
            local joined=$(IFS=', '; echo "${enabled_features[*]}")
            echo -e " ${GREEN}→ ${joined}${NC}"
        else
            echo ""
        fi
        echo -ne "  0) $(txt "可选配置 (版本名, 构建时间, 输出目录)" "Optional config (version name, build time, output dir)")"
        local optional_items=()
        [ -n "${BUILD_CFG[custom_version]}" ] && optional_items+=("$(txt "版本名" "version"):${BUILD_CFG[custom_version]}")
        [ -n "${BUILD_CFG[build_time]}" ] && optional_items+=("$(txt "时间" "time"):${BUILD_CFG[build_time]}")
        [ -n "${BUILD_CFG[output_dir]}" ] && optional_items+=("$(txt "输出" "output"):${BUILD_CFG[output_dir]}")
        if [ ${#optional_items[@]} -gt 0 ]; then
            local joined_opt=$(IFS=' '; echo "${optional_items[*]}")
            echo -e " ${GREEN}→ ${joined_opt}${NC}"
        else
            echo ""
        fi
        echo ""
        echo "  ${GREEN}S) $(txt "查看配置摘要 & 开始编译" "Show summary & start build")${NC}"
        echo "  ${YELLOW}Q) $(txt "退出" "Quit")${NC}"
        echo ""

        read -r -p "$(echo -e "${YELLOW}$(txt "请选择" "Select") [0-9 / A / S / Q]:${NC} ")" choice

        case "${choice,,}" in
            1) config_language ;;
            2) config_mirrors ;;
            3)
                setup_dependencies
                setup_ccache
                ;;
            4) fetch_kernel_source ;;
            5) config_kernel_from_source_package ;;
            6) config_kernel_source ;;
            7) config_kernel_version ;;
            8) config_kernelsu ;;
            9) config_droidspaces ;;
            a) config_features ;;
            0) config_optional ;;
            s)
                # 验证必要配置
                if ([ -z "${BUILD_CFG[kernel_source]}" ] && [ -z "${BUILD_CFG[kernel_source_tarball]:-}" ]) || [ -z "${BUILD_CFG[android_version]}" ] || [ -z "${BUILD_CFG[kernel_version]}" ]; then
                    log_error "$(txt "请先配置内核源码路径和内核版本!" "Please configure the kernel source path and kernel version first!")"
                    continue
                fi

                extract_kernel_source_tarball || continue

                show_config_summary

                if confirm "$(txt "确认配置无误，开始编译?" "Confirm this configuration and start building?")" "y"; then
                    save_config
                    local build_ret=0
                    run_build || build_ret=$?
                    _cleanup_extracted_source
                    return $build_ret
                else
                    log_info "$(txt "返回主菜单" "Returning to main menu")"
                fi
                ;;
            q)
                if [ "${CONFIG_DIRTY:-false}" = "true" ] || [ -n "${BUILD_CFG[kernel_source]}" ] || [ -n "${BUILD_CFG[android_version]}" ]; then
                    if confirm "$(txt "是否保存当前配置?" "Save current configuration?")" "y"; then
                        save_config
                    fi
                fi
                log_info "$(txt "退出" "Exit")"
                exit 0
                ;;
            *)
                log_error "$(txt "无效选择" "Invalid choice"): $choice"
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
        log_info "$(txt "清理解压的源码目录" "Cleaning extracted source directory"): $extracted"
        rm -rf "$extracted"
        BUILD_CFG[kernel_source]=""
    fi
}

# ================================================================
# 入口
# ================================================================

case "${1:-}" in
    --help|-h)
        load_config 2>/dev/null || true
        show_help
        exit 0
        ;;
    --quick)
        load_mirror_config
        if load_config; then
            log_info "$(txt "使用保存的配置快速构建..." "Building with saved configuration...")"
            show_config_summary
            extract_kernel_source_tarball || exit 1
            run_build || true
            _cleanup_extracted_source
        else
            log_error "$(txt "未找到保存的配置，请先运行 ./build_kernel.sh 进行配置" "No saved config found; run ./build_kernel.sh first to configure")"
            exit 1
        fi
        ;;
    --config)
        if load_config; then
            CONFIG_WAS_LOADED=true
        else
            CONFIG_WAS_LOADED=false
            choose_language
            CONFIG_DIRTY=true
        fi
        load_mirror_config
        config_mirrors
        config_kernel_source
        config_kernel_version
        config_kernelsu
        config_droidspaces
        config_features
        config_optional
        show_config_summary
        save_config
        log_info "$(txt "配置已保存" "Config saved")"
        ;;
    --reset)
        load_config 2>/dev/null || true
        rm -f "$BUILD_CONFIG_FILE"
        log_info "$(txt "已清除保存的配置" "Saved config cleared")"
        ;;
    *)
        if load_config; then
            CONFIG_WAS_LOADED=true
        else
            CONFIG_WAS_LOADED=false
            choose_language
            CONFIG_DIRTY=true
        fi
        main_menu
        ;;
esac
