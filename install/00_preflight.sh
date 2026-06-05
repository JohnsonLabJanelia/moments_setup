#!/usr/bin/env bash
# 00_preflight — read-only checks before any install. Never modifies the system.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "00_preflight" "Pre-flight environment & payload checks"

fail=0

# OS
log "OS: Ubuntu $OS_VERSION  (target tag: $OS_TAG)"
case "$OS_VERSION" in
  22.04) ok "22.04 — matches the reference machine (safest)";;
  24.04) ok "24.04 — DOCA 3.3.0/2404 + eSDK 24.04 staged; CUDA 12.2 build uses gcc-12 (auto)";;
  *) err "unsupported Ubuntu '$OS_VERSION' (need 22.04 or 24.04)"; fail=1;;
esac

# CPU / RAM / disk
log "CPU: $(LANG=C lscpu | awk -F: '/Model name/{print $2; exit}' | xargs)"
log "RAM: $(free -h | awk '/^Mem:/{print $2}')   Free disk on /home: $(df -h "$HOME" | awk 'NR==2{print $4}')"

# GPUs
if have_cmd lspci; then
  gpus=$(lspci | grep -i nvidia | grep -ciE '3D controller|VGA compatible') || true
  log "NVIDIA PCI display/3D devices detected: ${gpus:-0}"
  [ "${gpus:-0}" -ge 1 ] || { err "no NVIDIA GPU detected on PCI bus"; fail=1; }
fi

# Resizable BAR / Above-4G hint (informational — real check is in BIOS)
warn "BIOS: confirm 'Resizable BAR' + 'Above 4G Decoding' are ENABLED (mandatory for GPU-Direct)."

# Internet for apt (soft)
if timeout 5 bash -c 'exec 3<>/dev/tcp/archive.ubuntu.com/80' 2>/dev/null; then
  ok "apt network reachable (system .deb dependencies can be fetched)"
else
  warn "no apt network — small distro packages (cmake, glfw, ceres, …) may need pre-staging"
fi

# Payload presence
log "Artifacts dir: $ARTIFACTS_DIR"
[ -d "$ARTIFACTS_DIR" ] || { err "artifacts dir not found — mount the USB or set ARTIFACTS_DIR"; fail=1; }
for a in "$A_DRIVER_RUN" "$A_CUDA_RUN" "$A_NOUVEAU_CONF" "$A_DOCA_DEB" "$A_RIVERMAX_DEB" \
         "$A_RIVERMAX_LIC" "$A_ESDK_ZIP" "$A_FFMPEG_TAR" "$A_ORANGE_TAR"; do
  if [ -e "$a" ]; then ok "found $(basename "$a")"; else err "MISSING $a"; fail=1; fi
done
[ -d "$A_ORANGE_DATA" ] && ok "found orange_data/" || warn "orange_data/ not found (camera config presets) — optional but recommended"

# Optional checksum verification
if [ -f "$ARTIFACTS_DIR/CHECKSUMS.sha256" ] && confirm "Verify payload checksums (slow, reads ~6 GB)?"; then
  ( cd "$ARTIFACTS_DIR" && sha256sum --quiet -c CHECKSUMS.sha256 ) && ok "checksums OK" || { err "checksum mismatch"; fail=1; }
fi

hr
if [ "$fail" -eq 0 ]; then ok "pre-flight passed — ready to install"; else die "pre-flight found blockers (see above)"; fi
