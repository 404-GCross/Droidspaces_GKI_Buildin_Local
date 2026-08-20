<div align="center">

# Droidspaces_GKI_Buildin_Local

**GKI 内核本地编译工具**


</div>




## 简介

由GKI内核云端编译项目[zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)项目修改而来，专注于本地编译Droidspaces内核，带有镜像源使用功能，可以在无直连github的环境下拉取并编译GKI-Droidspaces内核。

支持的内核版本：5.10-6.18（GKI）

注：脚本代码99%由claude code+deepseek生成，应该会有bug，有问题欢迎issues反馈

脚本截图：

<img width="999" height="509" alt="image" src="https://github.com/user-attachments/assets/18ceeef2-83c5-46ab-9a9a-ca43d9fecdc9" />


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

版本选择：支持 Android 12 ~ 17，内核版本 5.10 / 5.15 / 6.1 / 6.6 / 6.12 / 6.18

镜像加速：可以使用镜像源进行源码拉取以及编译中涉及的github项目拉取

自定义镜像：支持手动输入任意镜像 URL

源码拉取：结合[GKI-Kernel-Source_Fetch](https://github.com/404-GCross/GKI-Kernel-Source_Fetch)项目，一站式源码拉取与编译

Droidspaces&NTsync支持：本项目核心目的，6.12 以下提供不同槽位补丁，6.12 及以上提供开关式适配

Built-in可选：可以选择noroot、ReSukiSU、KernelSU（不建议使用）

自定义功能：可自定义内核版本名称，构建时间


## 📊 支持的内核版本
Android 12	5.10	43 / 66 / 81 / 101 / 198 / 246 / 256 等版本

Android 13	5.15	41 / 74 / 78 / 94 / 170 / 194 / 207 等版本

Android 14	6.1	25 / 43 / 57 / 68 / 129 / 162 / 172 / 173 等版本

Android 15	6.6	50 / 56 / 57 / 58 / 77 / 127 / 139 等版本

Android 16	6.12	23 / 30 / 38 / 58 / 69 / 81 等版本（编译出来的6.12内核米系设备无法使用，请暂时不要使用该脚本为米系设备编译6.12内核）

Android 17	6.18	21 等版本（新增适配，请先小范围测试）

包含 lts 长期支持版本（小版本号标记为 X），当前对齐拉取脚本记录的 LTS 为 5.10.264 / 5.15.211 / 6.1.176 / 6.6.142 / 6.12.92 / 6.18.32。


## 🔗 相关链接
原项目：[GKI_KernelSU_SUSFS - 自动化构建 GKI 内核 | 集成 KernelSU + SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)

内核源码拉取项目：[GKI-Kernel-Source_Fetch](https://github.com/404-GCross/GKI-Kernel-Source_Fetch)





## 许可证

本项目基于 [GPL v2](LICENSE) 开源。

内核源码、KernelSU等组件各自遵循其原始许可证。
