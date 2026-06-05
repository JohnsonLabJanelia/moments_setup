#!/usr/bin/env bash
# 70_red — (Phase 2) system deps, extract red (xp), build the main `red` target.
# Bundled ONNX Runtime / cuDNN 9 / (optional) MuJoCo travel inside red/lib/.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "70_red" "Build red (xp) — JARVIS/TensorRT pipeline"
is_done "$STEP_NAME" && { ok "already done"; exit 0; }
require_artifact "$A_RED_TAR"
[ -e "$NVIDIA_PREFIX/TensorRT-$TENSORRT_VERSION/lib/libnvinfer.so" ] || die "run 60_tensorrt_cudnn first"

log "installing red build dependencies (apt)"
sudo apt-get update
sudo apt-get -y install build-essential cmake pkg-config git patchelf \
     libeigen3-dev libceres-dev libglew-dev libglfw3-dev libgl1-mesa-dev \
     libturbojpeg0-dev libopenblas-dev
# NOTE: red's *test* targets need GTest built WITH gmock under /usr/local.
# The main `red` binary does not, so we build only that target here.

RED_DIR="$SRC_PREFIX/red"
if [ ! -d "$RED_DIR" ]; then
  log "extracting red source → $SRC_PREFIX"
  mkdir -p "$SRC_PREFIX"; extract_zst "$A_RED_TAR" "$SRC_PREFIX"
else
  ok "red source already present at $RED_DIR"
fi
[ -d "$RED_DIR/lib/onnxruntime" ] || warn "red/lib/onnxruntime missing — JARVIS prediction will be disabled"

log "configuring + building target 'red'"
( cd "$RED_DIR" && cmake -S . -B release -DCMAKE_BUILD_TYPE=Release \
    && cmake --build release --target red -j"$(nproc)" )
[ -x "$RED_DIR/release/red" ] || die "build failed: release/red not produced"
ok "built $RED_DIR/release/red"
( cd "$RED_DIR" && ./install.sh ) || warn "red install.sh reported an issue (binary still in release/)"
mark_done "$STEP_NAME"
hr; ok "Phase 2 build complete. Run:  $RED_DIR/release/red"
