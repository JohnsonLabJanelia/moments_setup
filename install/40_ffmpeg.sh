#!/usr/bin/env bash
# 40_ffmpeg — lay down the prebuilt CUDA/NPP FFmpeg (n4.4.5) that orange & red
# link against. CMake hardcodes $HOME/nvidia/ffmpeg, so it MUST go there.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "40_ffmpeg" "Prebuilt CUDA FFmpeg → $NVIDIA_PREFIX"
is_done "$STEP_NAME" && { ok "already done"; exit 0; }

FFBIN="$NVIDIA_PREFIX/ffmpeg/build/bin/ffmpeg"
if [ -x "$FFBIN" ] && "$FFBIN" -version >/dev/null 2>&1; then
  ok "FFmpeg already present at $FFBIN"; mark_done "$STEP_NAME"; exit 0
fi
require_artifact "$A_FFMPEG_TAR"

log "extracting FFmpeg + nv-codec-headers → $NVIDIA_PREFIX"
extract_zst "$A_FFMPEG_TAR" "$NVIDIA_PREFIX"   # contains ffmpeg/ and nv-codec-headers/

[ -x "$FFBIN" ] || die "ffmpeg binary missing after extract"
LD_LIBRARY_PATH="$NVIDIA_PREFIX/ffmpeg/build/lib:${LD_LIBRARY_PATH:-}" "$FFBIN" -version | head -1
ok "FFmpeg in place"
mark_done "$STEP_NAME"
