<div align="center">

# GKI-Kernel-Source_Compile

**GKI 内核本地编译工具 | 集成 KernelSU + SUSFS**

[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-5AA300?style=flat-square)](https://kernelsu.org/)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-E67E22?style=flat-square)](https://gitlab.com/simonpunk/susfs4ksu)
[![License](https://img.shields.io/badge/License-GPL%20v3-blue?style=flat-square)](LICENSE)

</div>

---

## 简介

在本地 Linux 环境编译 GKI 内核，集成 KernelSU root 方案和 SUSFS 文件系统伪装。支持 Android 12 ~ 16 全系列 GKI 内核版本，通过交互式菜单完成配置和编译。

**主要特性：**

- **一键式交互菜单** — 按序号配置，无需手动编辑脚本
- **多版本覆盖** — 支持 Android 12 (5.10) ~ Android 16 (6.12)
- **多种 root 方案** — KernelSU 官方版、SukiSU、ReSukiSU
- **功能扩展** — SUSFS 文件伪装、ZRAM 增强、BBG 防格机等
- **镜像加速** — 国内网络环境可通过镜像源加速下载

## 环境要求

| 要求 | 说明 |
|:---|:---|
| **操作系统** | Linux x86_64 (Debian/Ubuntu、Fedora、Arch、openSUSE 等) |
| **磁盘空间** | 至少 30GB |
| **内核源码** | 通过 `repo init` 下载的 Android 内核源码树（需包含 `common/` 子目录） |
| **依赖工具** | git、curl、make、gcc、clang 等（脚本会自动检查并提示安装） |

**快速安装依赖：**

```bash
# Debian / Ubuntu
sudo apt install -y git curl make gcc clang bison flex bc openssl

# Fedora
sudo dnf install -y git curl make gcc clang bison flex bc openssl

# Arch
sudo pacman -S --needed git curl make gcc clang bison flex bc openssl
```

## 快速开始

```bash
./build_kernel.sh           # 交互式菜单（推荐）
./build_kernel.sh --quick   # 使用上次配置直接编译
./build_kernel.sh --config  # 仅配置，不编译
./build_kernel.sh --reset   # 清除保存的配置
./build_kernel.sh --help    # 显示帮助信息
```

### 配置流程

运行后按序号完成以下配置：

| 步骤 | 配置项 | 说明 |
|:---|:---|:---|
| 1 | **内核源码路径** | 包含 `common/` 子目录的 GKI 源码目录（必选） |
| 2 | **内核版本** | 选择 Android 版本 → 内核子版本 → 安全补丁级别 |
| 3 | **KernelSU** | 选择 root 方案 |
| 4 | **功能开关** | SUSFS / ZRAM / BBG / Re-Kernel / KPM / Droidspaces |
| 5 | **镜像源** | 国内网络可选镜像加速 |
| 6 | **可选配置** | 自定义版本名、构建时间、输出目录 |

按 `S` 查看配置摘要并开始编译。

## 目录结构

```
├── build_kernel.sh          # 主入口脚本
├── scripts/lib/
│   ├── common.sh            # 公共函数和常量
│   ├── setup_env.sh         # 环境检测和工具链配置
│   ├── features.sh          # KernelSU + SUSFS + 功能开关处理
│   └── build_core.sh        # 内核编译核心逻辑
├── config/
│   ├── config               # 自定义 commit 配置
│   ├── mirrors.conf         # 镜像源配置
│   └── zram.config          # ZRAM 压缩算法配置
└── zram/                    # ZRAM LZ4 增强模块
```

## 支持的内核版本

| Android 版本 | 内核版本 |
|:---|:---|
| Android 12 | 5.10 |
| Android 13 | 5.15 |
| Android 14 | 6.1 |
| Android 15 | 6.6 |
| Android 16 | 6.12 |

每个内核版本提供多个子版本号和对应的安全补丁级别，可在菜单中按需选择。

## KernelSU 变体

| 变体 | 说明 |
|:---|:---|
| **ReSukiSU** | 推荐，集成 SUSFS 支持，开箱即用 |
| **SukiSU** | SukiSU-Ultra 分支 |
| **Official** | KernelSU 官方版本 |
| **None** | 纯 GKI 内核，不集成任何 root 方案 |



## 功能开关

| 功能 | 依赖 | 说明 |
|:---|:---|:---|
| **SUSFS** | KernelSU | 文件系统伪装，隐藏 root 痕迹 |
| **ZRAM 增强** | — | 添加 LZ4KD 等压缩算法，提升内存压缩效率 |
| **BBG** | — | 防格机补丁（Baseband Guard） |
| **Re-Kernel** | — | 扩展内核驱动支持，兼容更多硬件 |
| **KPM** | KernelSU | 内核补丁模块，支持动态加载内核模块 |
| **Droidspaces** | — | Linux 容器支持，在 Android 上运行完整 Linux 环境 |

## 镜像源配置

国内下载 GitHub / GitLab / AOSP 仓库时可通过镜像加速：

| 预设 | GitHub | GitLab | AOSP |
|:---|:---|:---|:---|
| `none` | 直连 | 直连 | 直连 |
| `ghproxy` | gh.con.sh 代理 | 直连 | 直连 |
| `tsinghua` | 直连 | 直连 | TUNA 镜像 |
| `ustc` | 直连 | 直连 | USTC 镜像 |
| `custom` | 自定义 | 自定义 | 自定义 |

配置通过菜单操作，自动保存到 `config/mirrors.conf`。自定义镜像可在该文件中手动编辑。

## 自定义提交

通过 `config/config` 指定 SUSFS 和 SukiSU 使用的特定 commit，避免上游更新导致编译失败：

```ini
custom=true
gki-android14-6.1=abc123def456
sukisu=def789abc123
```

`custom=true` 时使用指定的 commit，留空则使用对应分支的最新提交。

## Stock Config 伪装

将官方内核的 `/proc/config.gz` 放入 `config/` 目录并命名为 `stock_defconfig`，编译时会自动替换内核中的配置文件。

构建脚本检测到该文件会自动应用，无需手动开关。此功能用于让编译内核的 `/proc/config.gz` 与官方内核一致。


## 构建产物

编译完成后在输出目录生成以下文件：

| 文件 | 说明 |
|:---|:---|
| `Image` / `Image.gz` / `Image.lz4` | 内核镜像（原始 / gzip / lz4 压缩） |
| `*-boot.img` | Boot 分区镜像，可 fastboot 刷入 |
| `*-AnyKernel3.zip` | AnyKernel3 刷入包，可通过 Recovery 刷入 |

默认输出目录为项目根目录下的 `out/`，可在菜单中自定义。

## 常见问题

**Q: 编译中途失败怎么办？**

检查终端输出的错误信息。常见原因：磁盘空间不足、内核源码不完整、缺少编译依赖。修复后用 `--quick` 重新编译即可跳过配置步骤。

**Q: 如何更换内核版本？**

运行 `./build_kernel.sh --reset` 清除旧配置，然后重新运行 `./build_kernel.sh` 进行配置。

**Q: 编译出来的内核无法启动？**

检查内核版本与设备 Android 版本是否匹配，确认 Boot 镜像刷入方式正确。建议先在设备上测试官方 GKI 内核是否能正常启动。

## 许可证

本项目基于 [GPL v2](LICENSE) 开源。

内核源码、KernelSU、SUSFS 等组件各自遵循其原始许可证。
