<div align="center">

# GKI-Kernel-Source_Compile

**GKI 内核本地编译工具**


</div>




## 简介

由GKI内核云端编译项目[zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)项目修改而来，专注于本地编译Droidspaces内核，带有镜像源使用功能，可以在无直连github的环境下拉取并编译GKI-Droidspaces内核。

支持的内核版本：5.10-6.12（GKI）

注：脚本代码95%由claude code+deepseek生成，应该会有bug，有问题欢迎issues反馈

<img width="1648" height="556" alt="image" src="https://github.com/user-attachments/assets/603f66a5-8a74-425d-8676-9c9d20781373" />

---

## 🚀 快速开始

1.克隆本项目到本地
```bash
git clone https://github.com/404-GCross/Droidspaces_GKI_Buildin_Local.git
```

2.进入项目文件夹
```bash
cd Droidspaces_GKI_Buildin_Local
```

3.给脚本授予运行权限
```bash
chmod +x build_kernel.sh
```

4.运行脚本
```bash
./build_kernel.sh
```

## 🛠 脚本功能

交互式脚本提供以下功能：

版本选择：支持 Android 12 ~ 16，内核版本 5.10 / 5.15 / 6.1 / 6.6 / 6.12

镜像加速：可以使用镜像源进行源码拉取以及编译中涉及的github项目拉取

自定义镜像：支持手动输入任意镜像 URL

源码拉取：结合[GKI-Kernel-Source_Fetch](https://github.com/404-GCross/GKI-Kernel-Source_Fetch)项目，一站式源码拉取与编译

Droidspaces&NTsync支持：本项目核心目的，6.12内核以下提供不同补丁选择

Built-in可选：可以选择noroot、ResukiSU、SukiSU Ultra（未测试，不建议使用）、KernelSU（不建议使用）

自定义功能：可自定义内核版本名称，构建时间


## 📊 支持的内核版本
Android 12	5.10	66 / 81 / 101 / 110 / 198 / 246 等 22 个版本

Android 13	5.15	74 / 78 / 94 / 104 / 170 / 194 等 20 个版本

Android 14	6.1	25 / 43 / 57 / 68 / 129 / 162 等 23 个版本

Android 15	6.6	50 / 56 / 57 / 58 / 77 / 127 等 15 个版本

Android 16	6.12	23 / 30 / 38 / 58  （编译出来的6.12内核有问题，请暂时不要使用该脚本编译6.12内核）

包含 lts 长期支持版本（小版本号标记为 X）。


## 🔗 相关链接
原项目：[GKI_KernelSU_SUSFS - 自动化构建 GKI 内核 | 集成 KernelSU + SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)

内核源码拉取项目：[GKI-Kernel-Source_Fetch](https://github.com/404-GCross/GKI-Kernel-Source_Fetch)





## 许可证

本项目基于 [GPL v2](LICENSE) 开源。

内核源码、KernelSU等组件各自遵循其原始许可证。
