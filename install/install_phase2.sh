#!/usr/bin/env bash
# install_phase2.sh — orchestrate red (xp). Run only after Phase 1 succeeds.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
_state_init
LOG="$MOMENTS_LOG_DIR/phase2_$(date -u +%Y%m%dT%H%M%SZ).log"

is_done 50_orange || warn "Phase 1 (50_orange) not marked done — red shares orange's CUDA/FFmpeg/driver."

STEPS=(60_tensorrt_cudnn 70_red)
log "Phase 2 — red xp   (log: $LOG)"; hr
for s in "${STEPS[@]}"; do
  rc=0; bash "$INSTALL_DIR/$s.sh" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || { hr; die "step '$s' failed (rc=$rc). See $LOG."; }
done
hr; ok "PHASE 2 COMPLETE — red is built."
