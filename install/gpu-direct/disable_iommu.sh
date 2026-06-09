#!/usr/bin/env bash
# disable_iommu_gpudirect.sh — one-time: disable the AMD IOMMU (required by Emergent
# GPU-Direct, per eSDK readme.txt), regenerate GRUB, and reboot.
# Self-elevates via sudo. Safe to abort during the 10s countdown (Ctrl-C).
set -euo pipefail

GRUB=/etc/default/grub

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-running with sudo..."; exec sudo -E "$0" "$@"
fi

echo "== current kernel cmdline =="
cat /proc/cmdline; echo

echo "== current GRUB_CMDLINE_LINUX_DEFAULT =="
grep '^GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB" || {
  echo "ERROR: GRUB_CMDLINE_LINUX_DEFAULT not found in $GRUB"; exit 1; }
echo

# Back up once (don't clobber an earlier backup)
[ -f "${GRUB}.bak" ] || cp -a "$GRUB" "${GRUB}.bak"
echo "Backup: ${GRUB}.bak"; echo

if grep -q 'amd-iommu=on iommu=pt' "$GRUB"; then
  sed -i 's/amd-iommu=on iommu=pt/amd_iommu=off/' "$GRUB"
  echo "Edited: 'amd-iommu=on iommu=pt' -> 'amd_iommu=off'"
elif grep -q 'amd_iommu=off' "$GRUB"; then
  echo "Already amd_iommu=off — no edit needed."
else
  echo "WARNING: expected 'amd-iommu=on iommu=pt' not found; not editing automatically."
  echo "Current line:"; grep '^GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB"
  exit 1
fi
echo

echo "== new GRUB_CMDLINE_LINUX_DEFAULT =="
grep '^GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB"; echo

echo "== update-grub =="
update-grub; echo

echo "GRUB updated. REBOOTING in 10s (Ctrl-C to abort)."
echo "After reboot, verify:"
echo "  cat /proc/cmdline                     # amd_iommu=off, no iommu=pt"
echo "  ls /sys/kernel/iommu_groups | wc -l   # expect 0"
echo "  lsmod | grep -i peermem               # nvidia_peermem auto-loaded"
sleep 10
reboot
