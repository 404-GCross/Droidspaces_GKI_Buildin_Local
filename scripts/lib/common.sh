#!/usr/bin/env bash
# ================================================================
# GKI 内核本地编译工具 - 公共函数库
# ================================================================

set -euo pipefail

# --- 颜色输出 ---
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m' # No Color

# --- 路径 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIRRORS_CONF="$PROJECT_ROOT/config/mirrors.conf"

# --- 日志函数 (输出到 stderr，避免被 $() 捕获) ---
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_step()  { echo -e "\n${CYAN}${BOLD}>>>${NC} ${BOLD}$*${NC}" >&2; }
# --- 显示横幅 ---
show_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║    Droidspaces内核本地编译脚本                           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# --- 加载镜像配置 ---
load_mirror_config() {
    if [ -f "$MIRRORS_CONF" ]; then
        source "$MIRRORS_CONF"
    fi
}

# --- 镜像 URL 转换 ---
# GitHub 镜像走反向代理模式: <mirror_prefix>/<完整原始URL>
# 例如: https://gh.con.sh/https://github.com/user/repo.git
mirror_github() {
    local url="$1"
    if [ "${use_custom_mirror:-false}" = "true" ] && [ -n "${CUSTOM_GITHUB_MIRROR:-}" ]; then
        local mirror="${CUSTOM_GITHUB_MIRROR%/}"
        echo "${mirror}/${url}"
    else
        echo "$url"
    fi
}

# --- Git 克隆 (带镜像) ---
git_clone() {
    local repo_url="$1"
    local target_dir="$2"
    shift 2
    local extra_args=("$@")
    local actual_url="$repo_url"

    # GitHub 镜像
    if [[ "$repo_url" == *"github.com"* ]]; then
        actual_url=$(mirror_github "$repo_url")
    fi

    if [ "$actual_url" != "$repo_url" ]; then
        log_info "使用镜像源克隆: $actual_url (原始: $repo_url)"
    fi

    git clone "$actual_url" "$target_dir" "${extra_args[@]}"
}

# --- 确认提示 ---
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local yn

    if [ "$default" = "y" ]; then
        read -r -p "$(echo -e "${YELLOW}${prompt} [Y/n]:${NC} ")" yn
        yn=${yn:-y}
    else
        read -r -p "$(echo -e "${YELLOW}${prompt} [y/N]:${NC} ")" yn
        yn=${yn:-n}
    fi

    [[ "$yn" =~ ^[Yy]$ ]]
}

# --- 选择菜单 ---
# 菜单 UI → stderr, 输出 "index<TAB>label" → stdout
# 调用方式:
#   local result=$(select_option "prompt" "${opts[@]}")
#   local idx="${result%%$'\t'*}"
#   local chosen="${result#*$'\t'}"
select_option() {
    local prompt="$1"
    shift
    local options=("$@")

    # 菜单 UI 输出到 stderr，避免被 $() 捕获
    [ -n "$prompt" ] && echo -e "${CYAN}${prompt}${NC}" >&2
    for i in "${!options[@]}"; do
        echo "  $((i+1))) ${options[i]}" >&2
    done

    local choice
    while true; do
        read -r -p "$(echo -e "${YELLOW}请选择 [1-${#options[@]}]:${NC} ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            printf '%d\t%s\n' "$((choice-1))" "${options[$((choice-1))]}"
            return 0
        fi
        log_error "无效选择: $choice"
    done
}

# --- 获取脚本目录的绝对路径 ---
get_abs_path() {
    local rel="$1"
    if command -v realpath &>/dev/null; then
        realpath "$rel"
    else
        readlink -f "$rel"
    fi
}
