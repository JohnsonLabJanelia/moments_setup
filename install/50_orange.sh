#!/usr/bin/env bash
# 50_orange — system GUI deps, extract orange (rob_minimal), build, install,
# and stage the camera config presets.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "50_orange" "Build & install orange (rob_minimal)"
is_done "$STEP_NAME" && { ok "already done"; exit 0; }
require_artifact "$A_ORANGE_TAR"

log "installing GUI build dependencies (apt)"
GCC12_PKGS=""; is_2404 && GCC12_PKGS="gcc-12 g++-12"   # CUDA 12.2 nvcc needs gcc<=12 (24.04 default is 13)
sudo apt-get update
sudo apt-get -y install build-essential cmake pkg-config git \
     libglfw3-dev libglew-dev libgl1-mesa-dev $GCC12_PKGS

ORANGE_DIR="$SRC_PREFIX/orange"
if [ ! -d "$ORANGE_DIR" ]; then
  log "extracting orange source → $SRC_PREFIX"
  mkdir -p "$SRC_PREFIX"; extract_zst "$A_ORANGE_TAR" "$SRC_PREFIX"
else
  ok "orange source already present at $ORANGE_DIR"
fi
[ -d "$ORANGE_DIR/third_party/imgui" ] || die "vendored submodules missing — bad source archive"

log "building orange (Release)"
( cd "$ORANGE_DIR" && cmake -S . -B release -DCMAKE_BUILD_TYPE=Release $(cuda_host_compiler_flag) \
    && cmake --build release -j"$(nproc)" )
[ -x "$ORANGE_DIR/release/orange" ] || die "build failed: release/orange not produced"
ok "built $ORANGE_DIR/release/orange"

# Install launcher/binary into ~/.local
( cd "$ORANGE_DIR" && ./install.sh ) || warn "orange install.sh reported an issue (binary still in release/)"

# Stage camera config presets
if [ -d "$A_ORANGE_DATA" ]; then
  if [ ! -d "$ORANGE_DATA_DIR/config" ]; then
    log "staging camera configs → $ORANGE_DATA_DIR"
    mkdir -p "$ORANGE_DATA_DIR"; cp -a "$A_ORANGE_DATA/." "$ORANGE_DATA_DIR/"
  else
    warn "$ORANGE_DATA_DIR/config already exists — left untouched (review manually if needed)"
  fi
  warn "orange's source default root is ~/orange_data_dev; confirm orange_root_dir points at $ORANGE_DATA_DIR"
fi

mark_done "$STEP_NAME"
hr; ok "Phase 1 build complete."
echo "  Run with:  sudo $ORANGE_DIR/release/orange      (needs root for PTP/NIC access)"
echo "  Ensure ~/.local/bin is on PATH to use the 'orange' launcher."
