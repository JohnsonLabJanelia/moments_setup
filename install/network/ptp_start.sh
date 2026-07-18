#!/usr/bin/env bash
# ptp_start.sh — run this host as the PTP boundary/grandmaster clock for the
# Emergent cameras. Per the orange docs: https://moments-behavior.github.io/docs/orange/ptp/
# Run in its own terminal; run sync_NICs.sh (phc2sys) in a second terminal.
# Needs root (ptp4l programs the NIC PTP hardware clocks). Ctrl-C to stop.
#
# Both ConnectX-7 (mlx5_core) quad-port camera NICs on this machine:
#   enp9s0f0..3  (card 1, PCI 09:00.x)   enp225s0f0..3  (card 2, PCI e1:00.x)
# The Intel eno1/eno2 (i40e) are NOT camera NICs and are excluded.
# Ports without a camera/link will report FAULTY in the log — harmless; ptp4l keeps
# serving the active ports.

sudo ptp4l \
  -i enp2s0f0np0 \
  -f /etc/ptp4l.conf
