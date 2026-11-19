#!/usr/bin/env bash
# 10_apt_deps — red build dependencies from the Ubuntu archive (sudo).
# Dry-run verified 2026-11-19: 74 new + 8 Mesa point upgrades, 0 removed,
# nothing NVIDIA/kernel/DKMS. Re-checks that before installing.
#
#   ./10_apt_deps.sh        (prompts for sudo)
set -euo pipefail
PKGS=(cmake build-essential pkg-config git patchelf
      libeigen3-dev libceres-dev libopenblas-dev
      libglfw3-dev libglew-dev libgl-dev
      libgtest-dev libgmock-dev googletest
      mesa-utils nasm)

sudo apt-get update
SIM=$(apt-get -s install "${PKGS[@]}")
if grep -qE '^Remv' <<<"$SIM" || grep -E '^Inst' <<<"$SIM" | grep -qiE 'nvidia|linux-(image|headers|modules)|dkms'; then
  echo "ABORT: apt would remove packages or touch driver/kernel packages:"
  grep -E '^Remv|^Inst' <<<"$SIM" | grep -iE 'Remv|nvidia|linux-|dkms'
  exit 1
fi
grep -E 'upgraded,' <<<"$SIM"
sudo apt-get install -y "${PKGS[@]}"
echo "OK: red apt dependencies installed"
