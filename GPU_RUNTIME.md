# portable-gpu-runtime-12.1.ext4：构建、复用与驱动热加载

本流程针对当前同一块工作盘上的 Devuan 6 x86_64 Live 主机。入口是 `miniDev/gpu-runtime.sh`；44 GiB 镜像、下载包及编译产物仅留在相邻的 `gpu-driver-cache/`，**不进入 Git**。脚本复用该目录已有的、可审查的 `scripts/*.sh`；只有 miniDev 源码而没有镜像和种子文件，不可能还原同一环境。

## 已核实的基线（2026-10-08）

| 项目 | 当前约束 |
| --- | --- |
| 系统 / 内核 | Devuan 6 x86_64；模块构建与加载限定 `6.12.57+deb13-amd64` |
| 镜像 | `../gpu-driver-cache/portable-gpu-runtime-12.1.ext4`，47,244,640,256 字节（44 GiB），ext4 放在 NTFS 工作盘 |
| 挂载 | `/mnt/codex-gpu-runtime`，loop/noatime；目前检查时未挂载 |
| NVIDIA | `NVIDIA-Linux-x86_64-550.163.01.run`，原包在 `gpu-driver-cache/nvidia-driver/` |
| CUDA | `cuda_12.1.1_530.30.02_linux.run`，原包在 `gpu-driver-cache/cuda-12.1/` |
| 工具链包 | `gpu-driver-cache/toolchain-apt/archives/` 的 42 个 deb，按 `manifest.json` 的大小和 SHA-256 核对 |
| 源脚本 | `gpu-driver-cache/scripts/{00,11,12,20,30,90}-*.sh`；同盘保留，不能只复制本仓库 |

镜像内的 GCC/GN/Ninja/CMake、sysroot 与项目依赖是持久数据；`minidev.sh setup` 挂载并把它们加入当前子进程环境。`gpu-runtime.sh` 负责驱动构建链，不会调用宿主 APT，也不会自动切换 GPU。程序可由普通 devuan 用户运行；只有挂载、写镜像内部的 rootfs 和驱动切换需要 sudo。

## 同盘重启后的操作

在普通用户终端执行：

```bash
cd /media/devuan/249C15F29C15BF6C/Codex-WorkDir/dev
bash miniDev/gpu-runtime.sh status
bash miniDev/gpu-runtime.sh mount
bash miniDev/minidev.sh setup
bash miniDev/gpu-runtime.sh prepare
bash miniDev/minidev.sh doctor
```

`mount` 核对挂载来源，拒绝占用挂载点的其他镜像。`prepare` 要求内核版本一致，核对 42 个 deb 的大小和 SHA-256，只在镜像内缺少 `codex-gcc` 时执行 `11-stage-toolchain-rootfs.sh`，随后用 `12-verify-toolchain.sh` 冒烟。它还要求镜像内已有匹配的 kernel headers 和解压后的 NVIDIA 550.163.01 源。**这一步不加载驱动，也不覆盖宿主 `/usr`。**

`minidev.sh setup` 与 `gpu-runtime.sh prepare` 用途不同：前者激活通用开发环境；后者验证驱动构建输入。若没有镜像，`minidev.sh setup` 会退回宿主 APT 安装；要坚持免安装镜像模式，先运行 `gpu-runtime.sh mount` 并在失败时停止，不应继续退回 APT。

## 首次构建镜像 / 迁移到同条件机器

1. 保存原始 NVIDIA/CUDA runfile、42 个 deb 及其 `manifest.json`、与运行内核**完全一致**的 headers deb，放在同名目录。先用 `sha256sum` 校验 vendor runfile 的可信来源；`prepare` 自动核验的是工具链 deb，**不是** runfile。更换 kernel/driver/CUDA 版本属于新环境，先更新锁版本、脚本和测试，不能复用现有模块。
2. 没有现成镜像时，在足够空间的工作盘创建**新的** ext4 文件，例如 `truncate -s 44G portable-gpu-runtime-12.1.ext4`、`mkfs.ext4 -F portable-gpu-runtime-12.1.ext4`。这两条仅适用于确认目标文件不存在的全新镜像；**绝不可对已有镜像运行 mkfs**。最好优先复制经过校验的现有镜像，因为目前 Git 仓库尚未锁定镜像内每个 sysroot/工具链/项目依赖的下载 URL 与散列，不能宣称从空镜像完全复现 44 GiB 内容。
3. 挂载新镜像后，把 headers deb 用 `dpkg-deb -x <包> /mnt/codex-gpu-runtime/rootfs` 解包；把 NVIDIA runfile以 vendor 的 `--extract-only` 模式解压至 `/mnt/codex-gpu-runtime/extract/nvidia/`。CUDA 原包只按项目需要解压到镜像，**不要运行系统安装选项**。验证 `rootfs/usr/src/linux-headers-$(uname -r)/Makefile` 和 `extract/nvidia/NVIDIA-Linux-x86_64-550.163.01/nvidia-installer` 存在。
4. `11-stage-toolchain-rootfs.sh` 只执行 `dpkg-deb -x` 到镜像 `toolchain/rootfs`；它不执行 deb maintainer scripts、不更新 Live 系统包数据库。GN/Ninja/CMake、GCC host 工具链、sysroot/GLAD2 等应用开发内容必须按各项目锁定来源放到 `opt/codex-ai-vision/`。运行 `miniDev/minidev.sh doctor`、`gpu-runtime.sh prepare` 和项目自己的 GN 构建/健康检查，不能把“镜像可挂载”当成“应用可运行”。
5. 镜像复制到别的机器后，先验证镜像 SHA-256、文件系统及架构/内核/PCI 设备，再运行同一入口。镜像不随 miniDev Git 发布，也不要提交 deb、`.so`、`.a`、`.ko`、图像、压缩包或可执行文件。

## 典型案例：candidate 根环境热启动视觉程序（X11）

在已有图形会话的普通 `devuan` 用户终端，按当前工作盘实际路径运行：

```bash
CXVISION_INITIAL_IMAGE=/media/devuan/249C15F29C15BF6C/Codex-WorkDir/dev/codex-ai-vision/workspace/01.jpg
export CXVISION_INITIAL_IMAGE
sudo -E /media/devuan/249C15F29C15BF6C/Codex-WorkDir/dev/gpu-driver-cache/start_codex_ai_vision_candidate.sh run x11
```

也可通过本仓库入口运行同一案例（会先核对镜像来源、初始图像、`DISPLAY` 和 candidate 标记）：

```bash
export CXVISION_INITIAL_IMAGE=/media/devuan/249C15F29C15BF6C/Codex-WorkDir/dev/codex-ai-vision/workspace/01.jpg
bash /media/devuan/249C15F29C15BF6C/Codex-WorkDir/dev/miniDev/gpu-runtime.sh vision-candidate x11
```

`start_codex_ai_vision_candidate.sh` 在私有 mount namespace 中挂载 `/dev`、`/proc`、`/sys`，把镜像中的 `rootfs-candidate` 用作 chroot 根。程序看到的 `/usr`、libc 和动态加载器来自 candidate，而不是覆盖宿主 `/usr`。宿主 `Codex-WorkDir` bind 到隔离环境的 `/codex-data`，项目 bind 到 `/workspace`。启动脚本现已把传入的宿主 `CXVISION_INITIAL_IMAGE` 路径映射为隔离环境的 `/codex-data/dev/codex-ai-vision/workspace/01.jpg`，因此这条原样命令可在 chroot 内找到图像。

这里的“系统无污染”严格指**不替换运行中的宿主 `/usr`、libc、加载器，也不通过 APT 安装应用**；并非零写入。首次挂载会建立宿主 loop 挂载点；`run` 会在绑定的项目目录执行 GN/Ninja，并可能写入 `out/linux`、日志或应用数据；程序在 chroot 内当前以 root 身份运行，生成文件可能归 root。不要把这个案例与 NVIDIA `hot-load` 混为一谈：candidate 程序运行不自动卸载 nouveau 或加载 NVIDIA 模块。关闭 GUI 后检查 `out/linux` 权属，必要时由管理员定点修正，避免对整个工作盘递归 `chown`。

运行前确认 X11 会话的 `DISPLAY` 可用，必要时设置 `XAUTHORITY`；确认镜像中有 `rootfs-candidate/.codex-rootfs-candidate`、相应 GN 工具链与应用依赖。若需先做无窗口冒烟，可运行 `sudo -E .../start_codex_ai_vision_candidate.sh smoke null`。本案例只完成了文件、脚本与路径映射的静态检查；本次没有实际启动 GUI 或改动驱动状态。

## 驱动模块：构建、热加载、回退

先审查 `gpu-driver-cache/scripts/30-build-nvidia-modules.sh` 中 NVIDIA vendor installer 的 build-only 参数和写入路径。它把模块放到镜像 `modules/$(uname -r)`，日志放在镜像 `meta/`，**不会自动加载**。现有 vendor installer 仍需在真实机器上验证是否只写入指定镜像位置；因此必须显式授权：

```bash
MINIDEV_ALLOW_VENDOR_BUILD=1 bash miniDev/gpu-runtime.sh build-driver
```

检查日志及 `modules/$(uname -r)/nvidia*.ko*` 后，只有在 GPU 用户进程退出、确认 NVIDIA PCI 设备为 `0000:01:00.0` 且具备本地控制台/回退手段时，才执行：

```bash
MINIDEV_ALLOW_GPU_SWITCH=1 bash miniDev/gpu-runtime.sh hot-load
nvidia-smi
```

`hot-load` 会再次要求交互输入 `y`；现有 `20-hot-load-nvidia.sh` 会**临时写入 Live 宿主 `/lib/modules/$(uname -r)`、运行 depmod、解绑/卸载 nouveau、加载 NVIDIA 模块**。它不执行 APT 安装，也不改持久系统盘，但绝非“零宿主状态变更”。可能影响图形会话和远程连接；不要在无人值守的 SSH 会话里执行。失败后可在本地控制台尝试：

```bash
MINIDEV_ALLOW_GPU_SWITCH=1 bash miniDev/gpu-runtime.sh rollback
```

回退脚本只是尝试卸载 NVIDIA 并重新绑定 nouveau，不能保证恢复所有图形进程；必要时重启 Live 系统。普通 GN 编译、ImGit 和视觉程序的 Intel/Mesa 路径不要求加载 NVIDIA。切勿为开发便捷将镜像的整个 `/usr` bind-mount 到正在运行的宿主；若要测试新 libc/loader，使用独立 rootfs candidate 与 mount namespace/chroot 或独立启动项。

## 对其他线程 / AI 的操作边界

先读本文件、`miniDev/README.md`、`minidev.sh` 和 `gpu-runtime.sh`，再运行 `status`。默认只允许运行 `mount`、`prepare`、`minidev.sh doctor`、项目构建/测试。没有显式的 `MINIDEV_ALLOW_VENDOR_BUILD=1` 不构建驱动；没有 `MINIDEV_ALLOW_GPU_SWITCH=1` 不热加载或回退。不得清空/重建已有 ext4 镜像，不得上传本地镜像、包或产物。项目源码路径可变，但环境镜像、挂载点、sysroot 和内核锁版本必须通过检查保持一致。
