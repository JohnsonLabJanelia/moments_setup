#!/usr/bin/env bash
# fix_nvidia_peermem_dkms.sh
# -----------------------------------------------------------------------------
# Ubuntu's PRECOMPILED nvidia driver (linux-modules-nvidia-NNN-open) ships
# nvidia-peermem.ko as a NO-OP STUB: it was built with no IB peer-memory headers
# (Canonical's build env has no MOFED), so it contains none of the nvidia_p2p_* /
# ib_register_peer_memory_client code. `modprobe nvidia_peermem` then fails with
# EINVAL (no dmesg), and EVT GPU-Direct aborts at EVT_CameraOpenStream().
#
# This is NOT a driver<->DOCA version mismatch. The fix is to switch the driver to
# its DKMS flavour so peermem is rebuilt ON THIS MACHINE *with DOCA/MOFED present*
# (the nvidia conftest then finds the peer-memory symbols and builds a real module).
#
# Run this AFTER the eSDK/DOCA install (so MOFED's Module.symvers exists), then
# REBOOT. Self-elevates via sudo. Idempotent-ish: re-running is safe.
# -----------------------------------------------------------------------------
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo "Re-running with sudo..."; exec sudo -E "$0" "$@"; fi

KREL="$(uname -r)"

echo "== preconditions =="
# 1) MOFED/DOCA peer-memory symbols must be present (provided by ib_uverbs / OFED DKMS).
SYMVERS=$(find /usr/src -path '*ofa_kernel*' -name Module.symvers 2>/dev/null | head -1 || true)
if [ -z "$SYMVERS" ] || ! grep -q ib_register_peer_memory_client "$SYMVERS" 2>/dev/null; then
  echo "ERROR: MOFED peer-memory symbols not found. Install the eSDK/DOCA stack first (step 30)."
  exit 1
fi
echo "  MOFED symbols: $SYMVERS"

# 2) Determine the installed open driver branch (NNN) and full DKMS version (X.Y.Z).
NNN=$(dpkg -l 2>/dev/null | awk '/^ii +nvidia-driver-[0-9]+-open /{print $2}' | grep -oE '[0-9]+' | head -1 || true)
[ -n "$NNN" ] || NNN=$(cat /sys/module/nvidia/version 2>/dev/null | cut -d. -f1 || true)
[ -n "$NNN" ] || { echo "ERROR: could not determine nvidia -open driver branch."; exit 1; }
VER=$(cat /sys/module/nvidia/version 2>/dev/null || true)
[ -n "$VER" ] || VER=$(dpkg-query -W -f='${Version}' "nvidia-kernel-source-${NNN}-open" 2>/dev/null | grep -oE '^[0-9.]+' || true)
echo "  driver branch: ${NNN}   version: ${VER}"

# 3) Already real + loaded? then we're done.
if lsmod | grep -q '^nvidia_peermem'; then
  echo "nvidia_peermem already loaded — nothing to do."; exit 0
fi

echo
echo "== install the DKMS driver flavour (rebuilds a MOFED-aware peermem) =="
# The postinst typically aborts because the precompiled modules occupy the same
# path at the same version — that's expected; we force-install next.
apt-get install -y "nvidia-dkms-${NNN}-open" || echo "  (postinst non-zero — expected; continuing)"

echo
echo "== force-install the freshly built modules into /updates/dkms =="
DKVER=$(dkms status nvidia 2>/dev/null | sed -n 's#^nvidia/\([0-9.]*\),.*#\1#p' | head -1)
[ -n "$DKVER" ] || DKVER="$VER"
dkms install --force "nvidia/${DKVER}" -k "$KREL"
depmod -a

echo
echo "== remove the precompiled module flavour so DKMS is the sole provider =="
PRECOMP=$(dpkg -l 2>/dev/null | awk -v k="$KREL" -v n="$NNN" \
  '$2 ~ ("^linux-modules-nvidia-" n "-open") {print $2}' || true)
if [ -n "$PRECOMP" ]; then
  # shellcheck disable=SC2086
  apt-get remove -y $PRECOMP || true
fi
apt-get install -f -y || true

echo
echo "== verify the rebuilt module is REAL (not a stub) =="
KO=$(modinfo -n nvidia_peermem 2>/dev/null || true)
if [ -n "$KO" ]; then
  TMP=/tmp/nvpeermem_check.ko
  if [[ "$KO" == *.zst ]]; then zstd -dqf "$KO" -o "$TMP" 2>/dev/null; else cp "$KO" "$TMP"; fi
  if nm -u "$TMP" 2>/dev/null | grep -q ib_register_peer_memory_client &&
     nm -u "$TMP" 2>/dev/null | grep -q nvidia_p2p_get_pages; then
    echo "  OK: $KO references the IB peer-memory + nvidia_p2p APIs (real module)."
  else
    echo "  WARNING: rebuilt module still looks like a stub — check the DKMS build log."
  fi
fi

# Make sure peermem loads on boot.
if [ -x /etc/init.d/start-nvidia-peermem ]; then update-rc.d start-nvidia-peermem defaults || true; fi

echo
echo "DONE. REBOOT now, then verify:"
echo "  lsmod | grep nvidia_peermem      # loaded; 'ib_uverbs ... N nvidia_peermem' = registered w/ DOCA"
echo "  ls /sys/kernel/iommu_groups | wc -l   # 0 (run disable_iommu / add amd_iommu=off first)"
