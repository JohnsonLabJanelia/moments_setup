#!/usr/bin/env bash
# sync_NICs.sh — discipline the system clock from the PTP hardware clock that
# ptp_start.sh (ptp4l) is driving, and keep all NIC PHCs aligned.
# Run in a SECOND terminal, after ptp_start.sh is running. Needs root. Ctrl-C to stop.
# Per the orange docs: https://moments-behavior.github.io/docs/orange/ptp/

sudo phc2sys -a -rr -m
