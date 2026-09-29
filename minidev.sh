#!/usr/bin/env bash
# miniDev: one entry point for Devuan 6 x86_64 development and runtime.
set -euo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/gpu-driver-cache" ]]; then
  CACHE_DIR="$SCRIPT_DIR/gpu-driver-cache"
elif [[ -d "$SCRIPT_DIR/../gpu-driver-cache" ]]; then
  CACHE_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../gpu-driver-cache" && pwd)"
else
  CACHE_DIR="$SCRIPT_DIR"
fi
if [[ -f "$CACHE_DIR/minidev.conf" ]]; then . "$CACHE_DIR/minidev.conf"; fi
IMAGE="${MINIDEV_IMAGE_PATH:-$CACHE_DIR/portable-gpu-runtime-12.1.ext4}"
MOUNT="${MINIDEV_MOUNT:-/mnt/codex-gpu-runtime}"
VISION="${MINIDEV_VISION_REPO:-$CACHE_DIR/../../Sean_WorkDir/codex-ai-vision/codex-ai-vision-inspection}"
IMGIT="${MINIDEV_IMGIT_REPO:-$CACHE_DIR/../ImGit-master}"
RUNTIME="$MOUNT/opt/codex-ai-vision"
TOOLS="$RUNTIME/toolchains"
SYSROOT="$RUNTIME/sysroot"
ACTION="${1:-setup}"
if [[ $# -gt 0 ]]; then shift; fi
say() { printf '[miniDev] %s\n' "$*"; }
die() { printf '[miniDev] ERROR: %s\n' "$*" >&2; exit 1; }
as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else
    command -v sudo >/dev/null || die "sudo is required for mount/apt; use an interactive terminal"
    sudo "$@"
  fi
}
append_lib() {
  [[ -d "$1" ]] || return 0
  if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then LD_LIBRARY_PATH="$1:$LD_LIBRARY_PATH"
  else LD_LIBRARY_PATH="$1"; fi
  export LD_LIBRARY_PATH
}
check_host() {
  [[ "$(uname -m)" == "x86_64" ]] || die "only x86_64 is supported"
  [[ -r /etc/os-release ]] || die "cannot determine Linux distribution"
  . /etc/os-release
  [[ "$ID" == "devuan" && "$VERSION_ID" == "6" ]] ||
    die "automatic bootstrap is tested only on Devuan 6 x86_64 (detected $ID $VERSION_ID)"
}
download_image_if_configured() {
  [[ -f "$IMAGE" ]] && return 0
  [[ -n "${MINIDEV_IMAGE_URL:-}" ]] || return 0
  [[ -n "${MINIDEV_IMAGE_SHA256:-}" ]] ||
    die "MINIDEV_IMAGE_SHA256 is required for an image download"
  command -v curl >/dev/null || die "curl is needed to download the image"
  command -v sha256sum >/dev/null || die "sha256sum is needed to verify the image"
  mkdir -p "$(dirname -- "$IMAGE")"
  local part="$IMAGE.part"
  local proxy_args=()
  if [[ -n "${MINIDEV_SOCKS_PROXY:-}" ]]; then
    proxy_args=(--proxy "$MINIDEV_SOCKS_PROXY")
  fi
  say "downloading external runtime image to $IMAGE"
  curl --fail --location --retry 3 --continue-at - --output "$part" \
    "${proxy_args[@]}" "$MINIDEV_IMAGE_URL"
  printf '%s  %s\n' "$MINIDEV_IMAGE_SHA256" "$part" | sha256sum --check --status ||
    die "image SHA-256 mismatch; partial file retained at $part"
  mv -- "$part" "$IMAGE"
}
mount_image() {
  [[ -f "$IMAGE" ]] || return 1
  command -v mountpoint >/dev/null || die "mountpoint is required"
  if mountpoint -q "$MOUNT"; then
    local current matched
    current="$(findmnt -n -o SOURCE "$MOUNT")"
    matched="$(losetup -j "$IMAGE" -O NAME -n 2>/dev/null || true)"
    printf '%s\n' "$matched" | grep -Fxq "$current" ||
      die "$MOUNT is mounted from $current, not $IMAGE"
  else
    as_root mkdir -p "$MOUNT"
    as_root mount -o loop,noatime "$IMAGE" "$MOUNT"
  fi
  mountpoint -q "$MOUNT" || die "mount failed: $MOUNT"
  return 0
}
portable_ready() {
  [[ -x "$TOOLS/host-gcc/usr/bin/gcc" &&
     -x "$TOOLS/host-gcc/usr/bin/g++" &&
     -x "$TOOLS/host-tools/bin/gn" &&
     -x "$TOOLS/host-tools/bin/ninja" &&
     -x "$TOOLS/host-tools/bin/cmake" ]]
}
activate_portable() {
  export MINIDEV_MODE=portable
  export CODEX_AI_VISION_RUNTIME="$RUNTIME"
  export CODEX_AI_VISION_SYSROOT="$SYSROOT"
  export CODEX_AI_VISION_TOOLCHAINS="$TOOLS"
  export PATH="$TOOLS/host-gcc/usr/bin:$TOOLS/host-tools/bin:$PATH:$SYSROOT/usr/bin"
  append_lib "$TOOLS/host-gcc/usr/lib/gcc/x86_64-linux-gnu/14"
  append_lib "$TOOLS/host-gcc/usr/lib/x86_64-linux-gnu"
  append_lib "$TOOLS/host-gcc/usr/lib"
  if [[ -d "$SYSROOT/usr/lib/x86_64-linux-gnu" ]]; then
    export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$SYSROOT/usr/lib/x86_64-linux-gnu"
  fi
  export LIBRARY_PATH="$SYSROOT/usr/lib/x86_64-linux-gnu:$SYSROOT/usr/lib:${LIBRARY_PATH:-}"
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:$SYSROOT/usr/share/pkgconfig"
}
activate_host() { export MINIDEV_MODE=host; }
configure_proxy() {
  if [[ -n "${MINIDEV_SOCKS_PROXY:-}" ]]; then
    export http_proxy="$MINIDEV_SOCKS_PROXY"
    export https_proxy="$MINIDEV_SOCKS_PROXY"
    export ALL_PROXY="$MINIDEV_SOCKS_PROXY"
  fi
}
install_host_toolchain() {
  command -v apt-get >/dev/null || die "apt-get is required for fresh-system bootstrap"
  local apt_opts=(-o "Acquire::http::Timeout=20" -o "Acquire::https::Timeout=20" -o "Acquire::Retries=2")
  if [[ -n "${MINIDEV_APT_PROXY:-}" ]]; then
    [[ "$MINIDEV_APT_PROXY" == http://* || "$MINIDEV_APT_PROXY" == https://* ]] ||
      die "MINIDEV_APT_PROXY must be an HTTP(S) proxy, not SOCKS5"
    apt_opts+=(-o "Acquire::http::Proxy=$MINIDEV_APT_PROXY"
               -o "Acquire::https::Proxy=$MINIDEV_APT_PROXY")
  fi
  say "installing base development packages on the Devuan host"
  as_root apt-get "${apt_opts[@]}" update
  as_root apt-get "${apt_opts[@]}" install -y --no-install-recommends \
    ca-certificates curl git build-essential cmake ninja-build generate-ninja \
    pkg-config python3 python3-jinja2 \
    libgl1-mesa-dev libglfw3-dev libx11-dev libxrandr-dev libxinerama-dev \
    libxcursor-dev libxi-dev libgit2-dev libcurl4-openssl-dev
  activate_host
}
tools_ready() {
  local t
  for t in gcc g++ cmake ninja gn python3 git pkg-config; do
    command -v "$t" >/dev/null || return 1
  done
}
prepare() {
  check_host
  configure_proxy
  download_image_if_configured
  if mount_image && portable_ready; then
    activate_portable
    say "using persistent ext4 runtime: $IMAGE"
  elif tools_ready; then
    activate_host
    say "using installed host toolchain"
  elif [[ "$ACTION" == setup ]]; then
    install_host_toolchain
  else
    die "base tools are missing; first run: bash $SCRIPT_DIR/minidev.sh setup"
  fi
  tools_ready || die "toolchain incomplete after setup"
}
diagnose() {
  say "mode=$MINIDEV_MODE"
  say "cache=$CACHE_DIR"
  say "image=$IMAGE"
  say "mount=$MOUNT"
  local t
  for t in gcc g++ cmake ninja gn python3 git; do
    printf '%-8s %s\n' "$t" "$(command -v "$t")"
  done
  if python3 -c 'import jinja2; print("jinja2", jinja2.__version__)' 2>/dev/null; then :
  else say "Jinja2 unavailable; required only by projects that regenerate templates"; fi
}
imgit_run() {
  [[ -d "$IMGIT" ]] || die "ImGit checkout not found: $IMGIT"
  local binary="$IMGIT/bin/ImGit_Linux_x32"
  [[ -x "$binary" ]] || die "ImGit executable not found: $binary"
  append_lib "$IMGIT/bin"
  append_lib "$IMGIT/3rdparty/ImGuiPack"
  append_lib "$IMGIT/build/_deps/curl/lib"
  append_lib "$IMGIT/build/_deps/libgit2/lib"
  append_lib "$SYSROOT/usr/lib/x86_64-linux-gnu"
  if [[ $# -gt 0 ]]; then exec "$binary" "$@"; else exec "$binary" "$IMGIT"; fi
}
vision_run() {
  local launcher="$CACHE_DIR/start_codex_ai_vision_dev.sh"
  [[ -f "$launcher" ]] || die "vision launcher missing: $launcher"
  [[ -d "$VISION/.git" ]] || die "vision repository missing: $VISION"
  exec bash "$launcher" run "$@"
}
case "$ACTION" in
  setup|doctor|shell|run|imgit|vision) ;;
  *) die "usage: bash minidev.sh [setup|doctor|shell|run -- CMD...|imgit [REPO]|vision]" ;;
esac
prepare
case "$ACTION" in
  setup|doctor) diagnose ;;
  shell) say "environment ready; exit the shell to return"; exec bash -i ;;
  run) [[ "${1:-}" == -- ]] && shift; [[ $# -gt 0 ]] || die "run needs a command"; exec "$@" ;;
  imgit) imgit_run "$@" ;;
  vision) vision_run "$@" ;;
esac
