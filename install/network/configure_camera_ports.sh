#!/usr/bin/env bash
# configure_camera_ports.sh — set up all 8 Emergent camera-facing ConnectX ports:
#   one camera per port, each on its own /24, host = .20, jumbo frames (MTU 9000),
#   no default route, IPv6 off. Idempotent: re-running updates the same NM profiles.
#
# Topology (host side .20; set each camera to .21 on the SAME subnet in eCapture):
#   NIC 1 (enp33,  PCI 21:00.x)        NIC 2 (enp241, PCI f1:00.x)
#     f0 -> 192.168.30.20  cam0          f0 -> 192.168.40.20  cam4
#     f1 -> 192.168.31.20  cam1          f1 -> 192.168.41.20  cam5
#     f2 -> 192.168.32.20  cam2          f2 -> 192.168.42.20  cam6
#     f3 -> 192.168.33.20  cam3          f3 -> 192.168.43.20  cam7
#
# Ports with no cabled/powered camera just stay configured (no carrier) — they
# activate automatically when a camera is plugged in. Self-elevates via sudo.

set -uo pipefail
MTU="${MTU:-9000}"

# iface  cidr               profile
# flyrig: card 1 = enp9 (PCI 09:00.x), card 2 = enp225 (PCI e1:00.x)
# Ports matched to each camera's EXISTING persistent IP (camera = .23, host = .20),
# discovered via `evttools -d -o b`. cam3's port has no camera cabled.
#   enp9s0f0np0   <- sn 2012853 @ 192.168.150.23
#   enp9s0f1np1   <- sn 2012855 @ 192.168.160.23
#   enp9s0f2np2   <- sn 2012857 @ 192.168.170.23
#   enp225s0f0np0 <- sn 2012861 @ 192.168.110.23
#   enp225s0f1np1 <- sn 2012631 @ 192.168.120.23
#   enp225s0f2np2 <- sn 2012862 @ 192.168.130.23
#   enp225s0f3np3 <- sn 2012630 @ 192.168.140.23
MAP=(
  "enp9s0f0np0    192.168.150.20/24  cam0"
  "enp9s0f1np1    192.168.160.20/24  cam1"
  "enp9s0f2np2    192.168.170.20/24  cam2"
  "enp9s0f3np3    192.168.33.20/24   cam3"
  "enp225s0f0np0  192.168.110.20/24  cam4"
  "enp225s0f1np1  192.168.120.20/24  cam5"
  "enp225s0f2np2  192.168.130.20/24  cam6"
  "enp225s0f3np3  192.168.140.20/24  cam7"
)

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-running with sudo..."; exec sudo -E "$0" "$@"
fi

for row in "${MAP[@]}"; do
  read -r IFACE CIDR CONN <<<"$row"

  if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "SKIP  $IFACE — interface not present"; continue
  fi

  if nmcli -t -f NAME connection show | grep -Fxq "$CONN"; then
    nmcli connection modify "$CONN" \
      connection.interface-name "$IFACE" \
      ipv4.method manual ipv4.addresses "$CIDR" ipv4.gateway "" \
      ipv4.never-default yes ipv6.method ignore 802-3-ethernet.mtu "$MTU"
  else
    nmcli connection add type ethernet ifname "$IFACE" con-name "$CONN" \
      ipv4.method manual ipv4.addresses "$CIDR" ipv4.never-default yes \
      ipv6.method ignore 802-3-ethernet.mtu "$MTU" >/dev/null
  fi

  # Leave an already-active profile alone (don't bounce a live camera/PTP port).
  if nmcli -t -f NAME connection show --active | grep -Fxq "$CONN"; then
    echo "LIVE  $IFACE -> $CIDR ($CONN) [already active — left untouched]"
  elif [ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" = "1" ]; then
    # Has carrier and isn't up yet: activate it.
    if nmcli connection up "$CONN" >/dev/null 2>&1; then
      echo "UP    $IFACE -> $CIDR ($CONN), MTU $MTU"
    else
      echo "WARN  $IFACE configured ($CONN) but activation failed"
    fi
  else
    echo "CFG   $IFACE -> $CIDR ($CONN) [no carrier yet — will activate when cabled]"
  fi
done

echo
echo "=== current IPv4 on ConnectX ports ==="
for row in "${MAP[@]}"; do read -r IFACE _ _ <<<"$row"
  printf '  %-16s %s\n' "$IFACE" "$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3" "$4}')"
done
