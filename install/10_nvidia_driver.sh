#!/usr/bin/env bash
# 10_nvidia_driver — blacklist nouveau, install NVIDIA driver 535.183.06.
# Two-phase across a reboot: (A) blacklist nouveau + reboot, (B) install driver.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "10_nvidia_driver" "NVIDIA display driver $DRIVER_VERSION"
is_done "$STEP_NAME" && { ok "already done"; exit 0; }

# Already running the right driver?
if have_cmd nvidia-smi && nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | grep -q "$DRIVER_VERSION"; then
  ok "driver $DRIVER_VERSION already active"; mark_done "$STEP_NAME"; exit 0
fi
require_artifact "$A_DRIVER_RUN"; require_artifact "$A_NOUVEAU_CONF"

# --- Phase A: blacklist nouveau, then reboot ---------------------------------
if ! is_done "10_nouveau"; then
  if lsmod | grep -q '^nouveau'; then
    log "blacklisting nouveau (Emergent-provided conf) and rebuilding initramfs"
    sudo cp "$A_NOUVEAU_CONF" /etc/modprobe.d/evt-disable-nouveau.conf
    sudo update-initramfs -u
    mark_done "10_nouveau"
    request_reboot "nouveau blacklisted."
  else
    ok "nouveau not loaded"; mark_done "10_nouveau"
  fi
fi

# --- Phase B: install the driver ---------------------------------------------
if lsmod | grep -q '^nouveau'; then
  die "nouveau is still loaded — reboot, then re-run (initramfs blacklist not yet active)"
fi
log "installing driver from $(basename "$A_DRIVER_RUN")"
confirm "Install NVIDIA driver $DRIVER_VERSION now?" || die "aborted by user"
sudo sh "$A_DRIVER_RUN" --silent --no-x-check --no-cc-version-check --install-libglvnd
mark_done "$STEP_NAME"
request_reboot "driver $DRIVER_VERSION installed."
