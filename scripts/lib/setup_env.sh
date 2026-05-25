#!/usr/bin/env bash
# ================================================================
# GKI 内核本地编译工具 - 环境初始化 & 依赖安装
# ================================================================

setup_dependencies() {
    log_step "检查编译依赖"

    # --- 检测发行版 ---
    local distro=""
    local install_cmd=""
    local update_cmd=""
    local pkgs=()

    # 优先检测 /etc/os-release (所有现代发行版通用)
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        case "${ID:-}" in
            debian|ubuntu|linuxmint|pop|elementary|zorin)
                distro="debian"
                install_cmd="sudo apt-get install -y"
                update_cmd="sudo apt-get update -qq"
                pkgs=(git curl make gcc g++ build-essential libssl-dev
                      bison flex libelf-dev dwarves ccache python3
                      clang lld bc rsync cpio perl patch zip gawk aria2)
                ;;
            fedora)
                distro="fedora"
                install_cmd="sudo dnf install -y"
                pkgs=(git curl make gcc gcc-c++ openssl-devel
                      bison flex elfutils-libelf-devel dwarves ccache python3
                      clang lld bc rsync cpio perl patch zip gawk aria2)
                ;;
            rhel|centos|almalinux|rocky|ol)
                distro="rhel"
                if command -v dnf &>/dev/null; then
                    install_cmd="sudo dnf install -y"
                else
                    install_cmd="sudo yum install -y"
                fi
                pkgs=(git curl make gcc gcc-c++ openssl-devel
                      bison flex elfutils-libelf-devel dwarves ccache python3
                      clang lld bc rsync cpio perl patch zip gawk aria2)
                # RHEL/CentOS 可能需要 EPEL
                if [[ "$install_cmd" == *"yum"* ]]; then
                    sudo yum install -y epel-release 2>/dev/null || true
                else
                    sudo dnf install -y epel-release 2>/dev/null || true
                fi
                ;;
            arch|manjaro|endeavouros|garuda)
                distro="arch"
                install_cmd="sudo pacman -S --needed --noconfirm"
                pkgs=(git curl make gcc base-devel openssl
                      bison flex libelf dwarves ccache python
                      clang lld bc rsync cpio perl zip aria2)
                ;;
            opensuse*|suse)
                distro="suse"
                install_cmd="sudo zypper install -y"
                pkgs=(git curl make gcc gcc-c++ libopenssl-devel
                      bison flex libelf-devel dwarves ccache python3
                      clang lld bc rsync cpio perl patch zip gawk aria2)
                ;;
        esac
    fi

    # 回退: 老式检测
    if [ -z "$distro" ]; then
        if [ -f /etc/debian_version ]; then
            distro="debian"
            install_cmd="sudo apt-get install -y"
            update_cmd="sudo apt-get update -qq"
            pkgs=(git curl make gcc g++ build-essential libssl-dev
                  bison flex libelf-dev dwarves ccache python3
                  clang lld bc rsync cpio perl patch zip gawk aria2)
        elif [ -f /etc/redhat-release ]; then
            distro="rhel"
            if command -v dnf &>/dev/null; then
                install_cmd="sudo dnf install -y"
            else
                install_cmd="sudo yum install -y"
            fi
            pkgs=(git curl make gcc gcc-c++ openssl-devel
                  bison flex elfutils-libelf-devel dwarves ccache python3
                  clang lld bc rsync cpio perl patch zip gawk aria2)
        elif [ -f /etc/arch-release ]; then
            distro="arch"
            install_cmd="sudo pacman -S --needed --noconfirm"
            pkgs=(git curl make gcc base-devel openssl
                  bison flex libelf dwarves ccache python
                  clang lld bc rsync cpio perl zip aria2)
        fi
    fi

    if [ -z "$distro" ]; then
        log_warn "未知发行版，请手动安装以下依赖:"
        log_warn "  git curl make gcc g++ openssl-dev bison flex libelf-dev dwarves ccache python3 clang lld bc rsync cpio perl patch zip aria2"
        if confirm "是否继续?" "y"; then
            return 0
        else
            exit 1
        fi
    fi

    # --- 安装 ---
    log_info "检测到发行版: ${distro} ($install_cmd)"

    # 先检查哪些包尚未安装
    local missing=()
    for pkg in "${pkgs[@]}"; do
        case "$distro" in
            debian)
                dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
                ;;
            fedora|rhel)
                rpm -q "$pkg" &>/dev/null || missing+=("$pkg")
                ;;
            arch)
                pacman -Qi "$pkg" &>/dev/null || missing+=("$pkg")
                ;;
            suse)
                rpm -q "$pkg" &>/dev/null || missing+=("$pkg")
                ;;
            *)
                missing+=("$pkg")
                ;;
        esac
    done

    if [ ${#missing[@]} -eq 0 ]; then
        log_info "所有依赖已安装 (${#pkgs[@]} 项)"
        return 0
    fi

    log_info "需安装 ${#missing[@]}/${#pkgs[@]} 个包: ${missing[*]}"

    if ! confirm "确认安装?" "y"; then
        log_info "跳过依赖安装"
        return 0
    fi

    [ -n "$update_cmd" ] && $update_cmd
    $install_cmd "${missing[@]}"

    log_info "依赖安装完成"
}

setup_ccache() {
    log_step "配置 ccache"
    mkdir -p ~/.cache/bazel
    ccache --version 2>/dev/null || true
    ccache --max-size=2G 2>/dev/null || true
    ccache --set-config=compression=true 2>/dev/null || true
    export CCACHE_DIR="$HOME/.ccache"
    log_info "ccache 缓存目录: $CCACHE_DIR"
}


