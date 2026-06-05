#!/usr/bin/env bash
# 05_kernel_check — gate: the running kernel must be one the pinned NVIDIA driver
# (535.183.06) can build a module against, and headers must be available.
# Driver 535.183.06 is validated up to ~kernel 6.8; 6.9+ (e.g. 24.04 HWE 6.11)
# will likely fail to build the module. This blocks BEFORE the driver step so you
# don't discover it mid-install. Override (at your own risk): MOMENTS_ALLOW_KERNEL=1
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALL_DIR/config.env"; source "$INSTALL_DIR/lib/common.sh"
step_begin "05_kernel_check" "Kernel compatibility with driver $DRIVER_VERSION"

KVER="$(uname -r)"
read -r MAJ MIN <<<"$(echo "$KVER" | awk -F. '{print $1, $2}')"
log "running kernel: $KVER   (target: 6.8 GA series)"

# Too new? (major>6, or 6.9+) → pinned driver won't build.
too_new=0
if [ "$MAJ" -gt 6 ] || { [ "$MAJ" -eq 6 ] && [ "$MIN" -gt 8 ]; }; then too_new=1; fi

if [ "$too_new" -eq 1 ]; then
  err "kernel $KVER is newer than 6.8 — driver $DRIVER_VERSION likely will NOT build its module."
  if is_2404; then
    err "Fix on Ubuntu 24.04: boot the GA 6.8 kernel instead of HWE. e.g."
    err "    sudo apt-get install -y linux-image-generic linux-headers-generic   # GA 6.8"
    err "    # then remove/avoid the HWE 6.11 kernel and reboot into 6.8"
  fi
  [ "${MOMENTS_ALLOW_KERNEL:-0}" = "1" ] && warn "MOMENTS_ALLOW_KERNEL=1 set — continuing anyway." \
    || die "stopping before the driver step. Boot a 6.8 kernel, or set MOMENTS_ALLOW_KERNEL=1 to force."
else
  ok "kernel $KVER is within the supported range for driver $DRIVER_VERSION"
fi

# 24.04 GA is 6.8; flag if on 24.04 but not 6.8 (e.g. someone forced an older/newer one).
if is_2404 && [ "$MIN" != "8" ]; then
  warn "on 24.04 but kernel is 6.$MIN, not the GA 6.8 — eSDK targets 6.8.0; prefer GA 6.8."
fi

# Headers must be installable for the .run / DKMS to build the module.
if dpkg -s "linux-headers-$KVER" >/dev/null 2>&1; then
  ok "linux-headers-$KVER already installed"
elif apt-cache show "linux-headers-$KVER" >/dev/null 2>&1; then
  ok "linux-headers-$KVER available from apt (step 10 installs it)"
else
  warn "linux-headers-$KVER not found via apt — the driver module build may fail. Ensure the"
  warn "matching headers package is available before running step 10."
fi
