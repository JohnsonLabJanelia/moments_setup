#!/usr/bin/env bash
# 60_tensorrt_cudnn — (Phase 2) TensorRT 8.6.1.6 → $HOME/nvidia, and cuDNN 8.9
# into /usr/local/cuda (TRT 8.6 loads libcudnn.so.8 at runtime).
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "60_tensorrt_cudnn" "TensorRT $TENSORRT_VERSION + cuDNN $CUDNN8_VERSION"
is_done "$STEP_NAME" && { ok "already done"; exit 0; }
require_artifact "$A_TRT_TAR"; require_artifact "$A_CUDNN8_TAR"

# TensorRT
TRT_DIR="$NVIDIA_PREFIX/TensorRT-$TENSORRT_VERSION"
if [ -e "$TRT_DIR/lib/libnvinfer.so" ]; then
  ok "TensorRT already at $TRT_DIR"
else
  log "extracting TensorRT → $NVIDIA_PREFIX"
  extract_zst "$A_TRT_TAR" "$NVIDIA_PREFIX"
  [ -e "$TRT_DIR/lib/libnvinfer.so" ] || die "TensorRT extract failed"
fi

# cuDNN 8.9 into /usr/local/cuda (runtime dep of TRT 8.6)
if [ -e /usr/local/cuda/lib64/libcudnn.so.8 ]; then
  ok "cuDNN 8 already present in /usr/local/cuda"
else
  log "installing cuDNN 8.9 headers+libs into /usr/local/cuda"
  TMP=$(mktemp -d); tar -xf "$A_CUDNN8_TAR" -C "$TMP"
  CD=$(find "$TMP" -maxdepth 1 -type d -name 'cudnn-*')
  sudo cp -P "$CD"/include/* /usr/local/cuda/include/
  sudo cp -P "$CD"/lib/libcudnn* /usr/local/cuda/lib64/
  sudo chmod a+r /usr/local/cuda/include/cudnn*.h /usr/local/cuda/lib64/libcudnn*
  sudo ldconfig; rm -rf "$TMP"
  [ -e /usr/local/cuda/lib64/libcudnn.so.8 ] || die "cuDNN 8 install failed"
fi
ok "TensorRT + cuDNN 8.9 in place"
mark_done "$STEP_NAME"
