#!/usr/bin/env bash
# Reproduce the current image-backed Devuan GPU build path. Never auto-load a driver.
set -euo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${MINIDEV_CACHE_DIR:-$SCRIPT_DIR/../gpu-driver-cache}"
CACHE="$(CDPATH= cd -- "$CACHE" && pwd)"
IMAGE="$CACHE/portable-gpu-runtime-12.1.ext4"
MOUNT=/mnt/codex-gpu-runtime
KERNEL_EXPECTED=6.12.57+deb13-amd64
DRIVER_EXPECTED=550.163.01
ACTION="${1:-status}"
say() { printf '[miniDev GPU] %s\n' "$*"; }
die() { printf '[miniDev GPU] ERROR: %s\n' "$*" >&2; exit 1; }
root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"
  else command -v sudo >/dev/null || die "sudo is needed for this action"; sudo "$@"
  fi
}
script() {
  local path="$CACHE/scripts/$1"
  [[ -f "$path" ]] || die "missing source script: $path (keep gpu-driver-cache/scripts with the image)"
  root bash "$path"
}
check_host() {
  [[ "$(uname -m)" == x86_64 ]] || die "requires x86_64"
  . /etc/os-release
  [[ "$ID" == devuan && "$VERSION_ID" == 6 ]] || die "requires Devuan 6"
}
check_seed() {
  [[ -f "$IMAGE" ]] || die "missing ext4 image: $IMAGE"
  [[ -f "$CACHE/nvidia-driver/NVIDIA-Linux-x86_64-$DRIVER_EXPECTED.run" ]] ||
    die "missing pinned NVIDIA 550.163.01 runfile"
  [[ -f "$CACHE/cuda-12.1/cuda_12.1.1_530.30.02_linux.run" ]] ||
    die "missing CUDA 12.1.1 runfile"
  [[ -f "$CACHE/toolchain-apt/manifest.json" ]] || die "missing toolchain manifest"
}
check_mount() {
  mountpoint -q "$MOUNT" || die "image not mounted at $MOUNT; run: bash $0 mount"
  local mounted loops
  mounted="$(findmnt -n -o SOURCE --target "$MOUNT")"
  loops="$(losetup -j "$IMAGE" -O NAME -n 2>/dev/null || true)"
  printf '%s\n' "$loops" | grep -Fxq "$mounted" ||
    die "$MOUNT is mounted from $mounted, not $IMAGE"
}
check_kernel() {
  [[ "$(uname -r)" == "$KERNEL_EXPECTED" ]] ||
    die "kernel mismatch: $(uname -r); required $KERNEL_EXPECTED. Do not load these modules."
}
verify_debs() {
  python3 - "$CACHE/toolchain-apt/manifest.json" "$CACHE/toolchain-apt/archives" <<'PY'
import hashlib, json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
archives = pathlib.Path(sys.argv[2])
packages = manifest["packages"]
if manifest["package_count"] != len(packages):
    raise SystemExit("manifest count mismatch")
for pkg in packages:
    path = archives / pkg["file"]
    if not path.is_file() or path.stat().st_size != pkg["bytes"]:
        raise SystemExit(f"missing or wrong-sized package: {path}")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != pkg["sha256"]:
        raise SystemExit(f"SHA-256 mismatch: {path}")
print(f"verified {len(packages)} cached deb files")
PY
}
case "$ACTION" in
  status)
    check_host
    say "image=$IMAGE"
    say "image_present=$([[ -f "$IMAGE" ]] && echo yes || echo no)"
    say "kernel=$(uname -r); required=$KERNEL_EXPECTED"
    say "mount=$MOUNT"
    if mountpoint -q "$MOUNT"; then check_mount; say "mounted=yes"
    else say "mounted=no"; fi
    say "host_driver=$(test -d /sys/module/nvidia && echo loaded || echo not-loaded)"
    ;;
  mount)
    check_host; check_seed
    if mountpoint -q "$MOUNT"; then check_mount
    else script 00-mount-runtime.sh; check_mount; fi
    say "ext4 mounted; no driver loaded"
    ;;
  prepare)
    check_host; check_kernel; check_seed
    bash "$SCRIPT_DIR/gpu-runtime.sh" mount
    verify_debs
    if [[ ! -x "$MOUNT/toolchain/rootfs/usr/bin/codex-gcc" ]]; then
      script 11-stage-toolchain-rootfs.sh
    fi
    script 12-verify-toolchain.sh
    [[ -f "$MOUNT/rootfs/usr/src/linux-headers-$KERNEL_EXPECTED/Makefile" ]] ||
      die "matching headers are not staged in image; see GPU_RUNTIME.md"
    [[ -x "$MOUNT/extract/nvidia/NVIDIA-Linux-x86_64-$DRIVER_EXPECTED/nvidia-installer" ]] ||
      die "NVIDIA runfile is not extracted inside image; see GPU_RUNTIME.md"
    say "toolchain/headers/driver source ready; nothing loaded"
    ;;
  build-driver)
    [[ "${MINIDEV_ALLOW_VENDOR_BUILD:-}" == 1 ]] ||
      die "review the vendor build-only flags, then set MINIDEV_ALLOW_VENDOR_BUILD=1"
    "$0" prepare
    script 30-build-nvidia-modules.sh
    say "module build requested; inspect image meta/nvidia-build-$KERNEL_EXPECTED.log"
    ;;
  hot-load)
    [[ "${MINIDEV_ALLOW_GPU_SWITCH:-}" == 1 ]] ||
      die "set MINIDEV_ALLOW_GPU_SWITCH=1 after reviewing PCI use and host /lib/modules write"
    check_host; check_kernel; check_seed; check_mount
    [[ -d "$MOUNT/modules/$KERNEL_EXPECTED" ]] || die "prebuilt modules missing"
    say "ATTENTION: this changes the live kernel, copies .ko into host /lib/modules and unbinds nouveau."
    script 20-hot-load-nvidia.sh
    ;;
  vision-candidate)
    check_host
    platform="${2:-x11}"
    case "$platform" in auto|x11|wayland|null) ;; *) die "unsupported platform: $platform" ;; esac
    [[ -n "${CXVISION_INITIAL_IMAGE:-}" ]] || die "set CXVISION_INITIAL_IMAGE to a readable host image"
    [[ -f "$CXVISION_INITIAL_IMAGE" ]] || die "initial image missing: $CXVISION_INITIAL_IMAGE"
    [[ -n "${DISPLAY:-}" || "$platform" != x11 ]] || die "DISPLAY is required for x11"
    launcher="$CACHE/start_codex_ai_vision_candidate.sh"
    [[ -f "$launcher" ]] || die "candidate launcher missing: $launcher"
    [[ -f "$IMAGE" ]] || die "runtime image missing: $IMAGE"
    bash "$SCRIPT_DIR/gpu-runtime.sh" mount
    [[ -f "$MOUNT/rootfs-candidate/.codex-rootfs-candidate" ]] ||
      die "candidate rootfs marker missing; see GPU_RUNTIME.md"
    if [[ "$(id -u)" -eq 0 ]]; then exec "$launcher" run "$platform"
    else exec sudo -E "$launcher" run "$platform"; fi
    ;;
  rollback)
    [[ "${MINIDEV_ALLOW_GPU_SWITCH:-}" == 1 ]] ||
      die "set MINIDEV_ALLOW_GPU_SWITCH=1 to attempt rollback"
    check_host; check_kernel
    script 90-rollback-nouveau.sh
    ;;
  *) die "usage: bash gpu-runtime.sh [status|mount|prepare|build-driver|hot-load|rollback|vision-candidate [x11|wayland|auto|null]]" ;;
esac
