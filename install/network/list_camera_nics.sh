#!/usr/bin/env bash
# list_camera_nics.sh — identify the camera-facing NIC ports on THIS machine.
#
# Interface names (enpXXs0fYnpZ) are derived from PCI bus position and CHANGE when
# you add/remove PCIe cards (NICs or GPUs). So always re-run this after any hardware
# change, then update configure_camera_ports.sh and ptp_start.sh to match.
#
# The Emergent cameras run over the Mellanox/NVIDIA ConnectX NICs (driver mlx5_core)
# — those are the ones you cable cameras to and run PTP on. Intel (i40e), Realtek,
# USB (cdc_ether) NICs are NOT camera NICs (no Rivermax/RDMA).

set -uo pipefail

printf '%-18s %-12s %-7s %-5s %s\n' IFACE DRIVER STATE PHC MAC
printf '%-18s %-12s %-7s %-5s %s\n' ----- ------ ----- --- ---
for i in $(ls /sys/class/net | grep -E '^en'); do
  drv=$(basename "$(readlink -f "/sys/class/net/$i/device/driver" 2>/dev/null)" 2>/dev/null)
  phc=$(ethtool -T "$i" 2>/dev/null | awk -F': ' '/PTP Hardware Clock/{print $2}')
  state=$(cat "/sys/class/net/$i/operstate" 2>/dev/null)
  mac=$(cat "/sys/class/net/$i/address" 2>/dev/null)
  mark=""; [ "$drv" = mlx5_core ] && mark="  <- ConnectX camera NIC"
  printf '%-18s %-12s %-7s %-5s %s%s\n' "$i" "${drv:-?}" "$state" "${phc:-none}" "$mac" "$mark"
done

echo
echo "ConnectX (mlx5_core) ports above are your camera NICs. Use those names in:"
echo "  - configure_camera_ports.sh  (one /24 subnet per port, host .20)"
echo "  - ptp_start.sh               (ptp4l -i <each camera port>)"
