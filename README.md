# miniDev — Devuan 6 x86_64 一命令开发入口

本仓库只发布流程、配置模板和运行脚本。不包含镜像、deb 包、动态库、静态库、图像、案例、压缩包或可执行程序。

## 当前工作盘

把本仓库克隆到 gpu-driver-cache 的同级目录：

    cd /media/devuan/249C15F29C15BF6C/Codex-WorkDir/dev
    git clone https://github.com/Sean-Cai-X/miniDev.git
    bash miniDev/minidev.sh setup

setup 是重启后唯一需要执行的初始化命令：发现本地 ext4 镜像时验证来源并挂载，复用镜像中的 GCC、GN、Ninja、CMake；否则检测宿主工具，缺失时通过 Devuan APT 下载并安装基础开发包。重复运行不会重复安装已就绪环境。

其他命令：

    bash miniDev/minidev.sh doctor
    bash miniDev/minidev.sh shell
    bash miniDev/minidev.sh run -- gn --version
    bash miniDev/minidev.sh imgit /path/to/repository
    bash miniDev/minidev.sh vision

shell 会打开带环境变量的开发 shell。imgit 只给该进程配置 ImGit 所需动态库路径；vision 调用原有 vision 启动脚本。项目源码、程序和项目专用依赖不会由 miniDev 创建。

## 全新机器与下载源

当前盘上的 portable-gpu-runtime-12.1.ext4 约 44 GiB，不在 Git 中。全新机器没有此镜像时，入口会走 Devuan 6 宿主 APT 安装基础工具链；这会修改宿主包数据库和 /usr，但不会加载 NVIDIA 驱动、覆盖整个 /usr 或替换系统动态链接器。

如需自动取回同一镜像，须提供你控制的镜像 URL 与 SHA-256：复制 minidev.conf.example 到 gpu-driver-cache/minidev.conf 并填写。脚本下载到 .part，校验成功才改名。没有可信 URL/hash 时不会伪装成已恢复原镜像。

Git/curl 可以用 MINIDEV_SOCKS_PROXY=socks5h://127.0.0.1:7897。APT 需要 HTTP(S) 代理，设置 MINIDEV_APT_PROXY=http://127.0.0.1:7897（本机已验证该端口同时接受 HTTP 代理协议；其他机器需先核对）；单独的 SOCKS5 地址不传给 APT。未设置 APT 代理则直接使用当前系统软件源。

无镜像时的 APT 自动安装范围：GCC/GN/Ninja/CMake、Python/Jinja2、Git、OpenGL/GLFW/X11 与 libgit2/curl 开发头文件。OCCT、OpenCV、libtorch、CUDA、NVIDIA 专有驱动、应用程序及项目源码需要各项目独立的锁版本清单和合法下载源，不能由 miniDev 猜测版本。运行 GUI 还需要有效的图形会话、DISPLAY/XDG_RUNTIME_DIR 和驱动。

不需要以 root 启动 ImGit 或业务程序；仅镜像挂载和 APT 安装会使用 sudo。不要通过此脚本热替换宿主 /usr。
