#!/usr/bin/env bash
# ptp_start.sh — run this host as the PTP boundary/grandmaster clock for the
# Emergent cameras. Per the orange docs: https://moments-behavior.github.io/docs/orange/ptp/
# Run in its own terminal; run sync_NICs.sh (phc2sys) in a second terminal.
# Needs root (ptp4l programs the NIC PTP hardware clocks). Ctrl-C to stop.
#
# Both ConnectX-7 (mlx5_core) quad-port camera NICs on this machine:
#   enp33s0f0..3  (card 1, PCI 21:00.x)   enp241s0f0..3  (card 2, PCI f1:00.x)
# The Intel enp209 (i40e) is NOT a camera NIC and is excluded.
# Ports without a camera/link will report FAULTY in the log — harmless; ptp4l keeps
# serving the active ports.

sudo ptp4l \
  -i enp33s0f0np0  -i enp33s0f1np1  -i enp33s0f2np2  -i enp33s0f3np3 \
  -i enp241s0f0np0 -i enp241s0f1np1 -i enp241s0f2np2 -i enp241s0f3np3 \
  -f /etc/ptp4l.conf
