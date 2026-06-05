#!/usr/bin/env bash
# 20_cuda — install CUDA 12.2.2 TOOLKIT only (driver already installed in step 10).
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "20_cuda" "CUDA $CUDA_VERSION toolkit (NPP + NVENC headers)"
is_done "$STEP_NAME" && { ok "already done"; exit 0; }

if [ -x /usr/local/cuda/bin/nvcc ] && /usr/local/cuda/bin/nvcc --version | grep -q "release $CUDA_VERSION"; then
  ok "CUDA $CUDA_VERSION already installed at /usr/local/cuda"; mark_done "$STEP_NAME"; exit 0
fi
require_artifact "$A_CUDA_RUN"
have_cmd nvidia-smi || warn "nvidia-smi not found — install the driver (step 10) first"

log "installing CUDA toolkit (no bundled driver) — this takes a few minutes"
confirm "Install CUDA $CUDA_VERSION toolkit now?" || die "aborted by user"
sudo sh "$A_CUDA_RUN" --toolkit --silent --override

# PATH + linker config (idempotent)
echo 'export PATH=/usr/local/cuda/bin:$PATH' | sudo tee /etc/profile.d/cuda.sh >/dev/null
echo '/usr/local/cuda/lib64' | sudo tee /etc/ld.so.conf.d/cuda.conf >/dev/null
sudo ldconfig

[ -x /usr/local/cuda/bin/nvcc ] || die "nvcc not found after install"
ok "$(/usr/local/cuda/bin/nvcc --version | grep release)"
mark_done "$STEP_NAME"
