#!/usr/bin/env bash
# ethernet_setup — configure an Emergent camera-facing ConnectX port:
#   static IPv4 on the camera subnet + jumbo frames (MTU 9000), via NetworkManager.
#
# Usage:
#   ./ethernet_setup.sh                                  # uses the defaults below
#   ./ethernet_setup.sh enp33s0f1np1 192.168.31.20/24 cam1
#   IFACE=... HOST_CIDR=... CONN=... MTU=... ./ethernet_setup.sh
#
# The script re-runs itself with sudo if needed (you'll be asked for your password).
# Idempotent: re-running updates the same NetworkManager profile instead of duplicating.
#
# After it succeeds, open eCapture and set the CAMERA's IP to another address on the
# SAME subnet (host is .20 -> set camera to .21).

set -euo pipefail

# --- settings (override via positional args or environment) -----------------
IFACE="${1:-${IFACE:-enp33s0f0np0}}"               # camera-facing NIC port (MAC 54:9b:24:61:69:6c)
HOST_CIDR="${2:-${HOST_CIDR:-192.168.30.20/24}}"   # host IP/prefix on the camera subnet
CONN="${3:-${CONN:-cam0}}"                         # NetworkManager profile name
MTU="${4:-${MTU:-9000}}"                           # jumbo frames — REQUIRED by Emergent streaming

echo "Interface : $IFACE"
echo "Host IP   : $HOST_CIDR"
echo "Profile   : $CONN"
echo "MTU       : $MTU"
echo

# --- elevate (nmcli changes need root) --------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "Re-running with sudo..."
  exec sudo -E "$0" "$IFACE" "$HOST_CIDR" "$CONN" "$MTU"
fi

# --- sanity: the interface exists -------------------------------------------
if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "ERROR: interface '$IFACE' not found. ConnectX ports on this box:"
  ip -br link | grep -E 'enp33' || ip -br link
  exit 1
fi

# --- create or update the NetworkManager profile ----------------------------
if nmcli -t -f NAME connection show | grep -Fxq "$CONN"; then
  echo "Profile '$CONN' exists — updating it."
  nmcli connection modify "$CONN" \
    connection.interface-name "$IFACE" \
    ipv4.method manual ipv4.addresses "$HOST_CIDR" ipv4.gateway "" \
    ipv4.never-default yes ipv6.method ignore 802-3-ethernet.mtu "$MTU"
else
  echo "Creating profile '$CONN'."
  nmcli connection add type ethernet ifname "$IFACE" con-name "$CONN" \
    ipv4.method manual ipv4.addresses "$HOST_CIDR" ipv4.never-default yes \
    ipv6.method ignore 802-3-ethernet.mtu "$MTU"
fi

echo "Bringing up '$CONN'..."
nmcli connection up "$CONN" || {
  echo "Activation failed. Is the camera cabled + powered (link carrier up)?"
  echo "Link state: $(cat /sys/class/net/$IFACE/operstate 2>/dev/null || echo unknown)"
  exit 1
}

# --- verify -----------------------------------------------------------------
echo
echo "=== result ==="
ip -4 addr show "$IFACE" | grep -E 'inet ' || echo "WARNING: no IPv4 assigned"
applied_mtu="$(cat /sys/class/net/$IFACE/mtu 2>/dev/null || echo '?')"
echo "MTU        : $applied_mtu $( [ "$applied_mtu" = "$MTU" ] && echo '(ok)' || echo "(EXPECTED $MTU)" )"
echo "Link state : $(cat /sys/class/net/$IFACE/operstate 2>/dev/null || echo unknown)"
echo
echo "Host side ready. Now in eCapture, set the camera IP to another address on"
echo "${HOST_CIDR%.*}.0/24 (e.g. camera = ${HOST_CIDR%.*}.21)."
