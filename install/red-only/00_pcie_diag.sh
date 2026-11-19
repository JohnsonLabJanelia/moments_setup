#!/usr/bin/env bash
# 00_pcie_diag — READ-ONLY. For each NVIDIA GPU: which physical slot it sits in,
# and whether its link width is limited by the GPU or by the root port above it
# (a root port with LnkCap x4 under an x16 slot = BIOS bifurcation). Needs sudo
# only to read the SMBIOS slot table and full PCIe capability registers.
#
#   sudo ./00_pcie_diag.sh | tee ~/pcie_diag.txt
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0"; exit 1; }

echo "=== Board / BIOS"
dmidecode -s baseboard-manufacturer; dmidecode -s baseboard-product-name
dmidecode -s bios-version; dmidecode -s bios-release-date

for GPU in $(lspci -D -d 10de: -n | awk '$2 ~ /^03/ {print $1}'); do
  PORT=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$GPU")")")
  BUS=${PORT%:*}                     # e.g. 0000:4a — the root-complex stack
  echo; echo "=== GPU $GPU  (root port $PORT)"
  for d in "$PORT" "$GPU"; do
    echo "--- $d  $(lspci -s "${d#0000:}" | cut -d' ' -f2-)"
    lspci -vvv -s "${d#0000:}" | grep -E 'LnkCap:|LnkSta:|Physical Slot'
  done
  echo "--- SMBIOS slot(s) on stack $BUS"
  dmidecode -t slot | awk -v b="$BUS:" '
    /Designation/ {des=$0} /Type:/ {typ=$0} /Current Usage/ {use=$0}
    /Bus Address/ { if (index($0,b)) print des "\n" typ "\n" use "\n" $0 "\n" }'
done

echo; echo "=== All PCIe bridges (link capability, what is behind them)"
for f in /sys/bus/pci/devices/*; do
  [[ $(cat "$f/class") == 0x0604* ]] || continue
  d=$(basename "$f"); kids=$(ls -d "$f"/0000:* 2>/dev/null | xargs -rn1 basename | tr '\n' ' ')
  printf '%s  capW=x%-2s  curW=x%-2s  %s\n' "$d" "$(cat "$f/max_link_width")" \
    "$(cat "$f/current_link_width")" "${kids:-<empty>}"
done

echo; echo "=== SMBIOS slot table"
dmidecode -t slot | grep -E 'Designation|Type:|Current Usage|Bus Address|^$'

echo; echo "=== Kernel bandwidth messages"
dmesg | grep -E 'available PCIe bandwidth' || echo "(none — every device at full width)"
