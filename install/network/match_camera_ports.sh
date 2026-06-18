#!/usr/bin/env bash
# match_camera_ports.sh — READ-THEN-MATCH camera networking, fully automated.
#
# Discovers each Emergent camera (broadcast, so it works even before the host ports
# are on the right subnet), reads each camera's EXISTING IP and which ConnectX port
# it's cabled to, and sets that port onto the SAME /24 (host = .HOST_OCTET). The
# cameras are never written to.
#
# Usage:
#   sudo ./match_camera_ports.sh            # DRY RUN: just print the discovered plan
#   sudo ./match_camera_ports.sh --apply    # configure the ports (persistent nmcli profiles)
#
# Env: MTU (default 9000), HOST_OCTET (default 20).
set -uo pipefail

APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
MTU="${MTU:-9000}"; HOST_OCTET="${HOST_OCTET:-20}"
ESDK=/opt/EVT/eSDK; EVTTOOLS="$ESDK/tools/evttools"

if [ "$(id -u)" -ne 0 ]; then echo "Re-running with sudo..."; exec sudo -E "$0" "$@"; fi
[ -x "$EVTTOOLS" ] || { echo "ERROR: $EVTTOOLS not found — install the eSDK first."; exit 1; }

# Bring mlx5 (ConnectX) ports up, and give any IP-less one a temporary address so the
# broadcast reply has a receiving-interface IP to report in evttools' "on:" field.
t=11
for i in $(ls /sys/class/net | grep -E '^en'); do
  [ "$(basename "$(readlink -f "/sys/class/net/$i/device/driver" 2>/dev/null)" 2>/dev/null)" = mlx5_core ] || continue
  ip link set "$i" up 2>/dev/null || true
  if ! ip -4 addr show "$i" 2>/dev/null | grep -q 'inet '; then
    ip addr add "192.168.$t.20/24" dev "$i" 2>/dev/null || true; t=$((t+1))
  fi
done
sleep 1

echo "== discovering cameras (broadcast) =="
DISC=$(LD_LIBRARY_PATH="$ESDK/lib" "$EVTTOOLS" -d -o b 2>/dev/null) || true
CAMS=$(echo "$DISC" | grep -E "Camera [0-9]+:") || true
[ -n "$CAMS" ] || { echo "No cameras found. Check cabling/power and that the ports are up."; exit 1; }

# host-IP -> interface name (from current addresses)
declare -A IP2IF
while read -r ifc ip; do [ -n "$ip" ] && IP2IF["$ip"]="$ifc"; done \
  < <(ip -4 -br addr show | awk '{for(j=3;j<=NF;j++){split($j,a,"/"); print $1, a[1]}}')

printf '%-16s %-18s %-16s %s\n' IFACE HOST_IP CAMERA_IP SERIAL
printf '%-16s %-18s %-16s %s\n' ----- ------- --------- ------
PLAN=()
while IFS= read -r line; do
  cam_ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  host_ip=$(echo "$line" | sed -n 's/.* on: *\([0-9.]*\).*/\1/p')
  sn=$(echo "$line" | sed -n 's/.*sn: *\([0-9]*\).*/\1/p')
  iface="${IP2IF[$host_ip]:-}"
  subnet="${cam_ip%.*}"; cam_octet="${cam_ip##*.}"
  ho="$HOST_OCTET"; [ "$ho" = "$cam_octet" ] && ho=$([ "$cam_octet" = 1 ] && echo 2 || echo 1)
  host_cidr="$subnet.$ho/24"
  if [ -z "$iface" ]; then
    printf '%-16s %-18s %-16s %s\n' "??" "$host_ip" "$cam_ip" "$sn  (no iface for host IP)"
    continue
  fi
  printf '%-16s %-18s %-16s %s\n' "$iface" "$host_cidr" "$cam_ip" "$sn"
  PLAN+=("$iface|$host_cidr|cam_$sn")
done <<< "$CAMS"

if [ "$APPLY" -ne 1 ]; then
  echo; echo "DRY RUN — re-run with --apply to configure the ports above (MTU $MTU, no default route)."
  exit 0
fi

echo; echo "== applying (persistent nmcli profiles) =="
for row in "${PLAN[@]}"; do
  IFS='|' read -r iface cidr conn <<<"$row"
  if nmcli -t -f NAME connection show | grep -Fxq "$conn"; then
    nmcli connection modify "$conn" connection.interface-name "$iface" \
      ipv4.method manual ipv4.addresses "$cidr" ipv4.gateway "" \
      ipv4.never-default yes ipv6.method ignore 802-3-ethernet.mtu "$MTU" >/dev/null
  else
    nmcli connection add type ethernet ifname "$iface" con-name "$conn" \
      ipv4.method manual ipv4.addresses "$cidr" ipv4.never-default yes \
      ipv6.method ignore 802-3-ethernet.mtu "$MTU" >/dev/null
  fi
  nmcli connection up "$conn" >/dev/null 2>&1 && echo "  $iface -> $cidr ($conn)" \
    || echo "  WARN $iface -> $cidr ($conn) activation failed"
done

echo; echo "== verify: ping each camera =="
while IFS= read -r line; do
  cam_ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  ping -c1 -W1 "$cam_ip" >/dev/null 2>&1 && echo "  $cam_ip reachable" || echo "  $cam_ip NO reply"
done <<< "$CAMS"

echo; echo "Done. PTP next: edit ptp_start.sh -i list to the ConnectX ports, then run the orange launcher."
