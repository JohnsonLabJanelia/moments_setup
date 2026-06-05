#!/usr/bin/env bash
# install_phase1.sh — orchestrate orange (rob_minimal) bring-up.
# Idempotent & reboot-resumable: re-run after each reboot; finished steps skip.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
_state_init
LOG="$MOMENTS_LOG_DIR/phase1_$(date -u +%Y%m%dT%H%M%SZ).log"

STEPS=(00_preflight 10_nvidia_driver 20_cuda 30_emergent 40_ffmpeg 50_orange)

log "Phase 1 — orange rob_minimal   (log: $LOG)"
log "Artifacts: $ARTIFACTS_DIR    OS: $OS_VERSION"
hr
for s in "${STEPS[@]}"; do
  rc=0; bash "$INSTALL_DIR/$s.sh" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
  if [ "$rc" -eq "$REBOOT_RC" ]; then
    hr; warn "Reboot needed after '$s'. Run 'sudo reboot', then re-run: $0"; exit "$REBOOT_RC"
  elif [ "$rc" -ne 0 ]; then
    hr; die "step '$s' failed (rc=$rc). See $LOG. Fix and re-run: $0"
  fi
done
hr; ok "PHASE 1 COMPLETE — orange is built. (See 50_orange output for run instructions.)"
