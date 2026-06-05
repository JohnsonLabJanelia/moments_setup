#!/usr/bin/env bash
# 30_emergent — Emergent eSDK + eCapture, plus the NIC stack it depends on:
# NVIDIA DOCA-OFED (installed from our LOCAL deb via the installer's -m flag),
# Rivermax, the Rivermax license, and nvidia_peermem for GPU-Direct RDMA.
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "30_emergent" "Emergent eSDK $ESDK_VERSION + DOCA $DOCA_VERSION + Rivermax $RIVERMAX_VERSION"
is_done "$STEP_NAME" && { ok "already done"; exit 0; }

require_artifact "$A_ESDK_ZIP"
require_artifact "$A_RIVERMAX_LIC"
if [ ! -e "$A_DOCA_DEB" ]; then
  die "DOCA deb not found: $A_DOCA_DEB
  → The staged DOCA is ubuntu2204-only. On Ubuntu $OS_VERSION, add the matching
    doca-host …${OS_TAG,,}… deb to 20_ofed_rivermax/ and set A_DOCA_DEB."
fi
need_cmd unzip

WORK="$HOME/.moments-setup/esdk_$OS_TAG"
log "unpacking eSDK installer → $WORK"
mkdir -p "$WORK"; unzip -o -q "$A_ESDK_ZIP" -d "$WORK"
[ -f "$WORK/install_eSdk.sh" ] || die "install_eSdk.sh not found in eSDK zip"
chmod +x "$WORK/install_eSdk.sh"

# GPU-Direct: OFED cannot reload while nvidia_peermem holds it. Unload first.
if lsmod | grep -q '^nvidia_peermem'; then log "temporarily unloading nvidia_peermem"; sudo rmmod nvidia_peermem || true; fi

warn "This installs DOCA-OFED and rebuilds the IB/NIC stack — it will briefly disrupt networking."
confirm "Run the Emergent installer (eSDK + DOCA + Rivermax) now?" || die "aborted by user"

# -i Mellanox: ConnectX path · -m <deb>: use our LOCAL DOCA (no download) · -y: non-interactive
( cd "$WORK" && sudo ./install_eSdk.sh -i Mellanox -m "$A_DOCA_DEB" -y )

# Place the Rivermax license (the installer creates the dir but not the .lic).
log "installing Rivermax license → /opt/mellanox/rivermax/rivermax.lic"
sudo mkdir -p /opt/mellanox/rivermax
sudo cp "$A_RIVERMAX_LIC" /opt/mellanox/rivermax/rivermax.lic

# Reload GPU-Direct peer-memory module.
sudo modprobe nvidia_peermem 2>/dev/null || warn "could not load nvidia_peermem (load it after a reboot)"

# Verify
[ -e /opt/EVT/eSDK/lib/libEmergentCamera.so ] || die "eSDK libs missing — installer may have failed"
[ -f /opt/mellanox/rivermax/rivermax.lic ]    || die "Rivermax license not in place"
ok "eSDK libs present; Rivermax license installed"
mark_done "$STEP_NAME"
warn "RECOMMENDED: reboot before streaming so NIC firmware/driver changes fully apply."
warn "  Verify the license covers THIS machine's ConnectX MACs (licenses are node-locked)."
