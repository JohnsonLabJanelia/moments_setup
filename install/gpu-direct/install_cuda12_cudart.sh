#!/usr/bin/env bash
# install_cuda12_cudart_gpudirect.sh
# Emergent eSDK 4.07 GPUDirect libs (libEmergentGPUDirect.so, libEmergentP2PGPU.so) have a
# hard ELF NEEDED on libcudart.so.12 (they were built against CUDA 12). This box runs CUDA
# 13.1, so that runtime is absent and EVT_CameraOpenStream() fails with ENOENT under
# gpu_direct. Fix: install the CUDA 12 cudart runtime alongside CUDA 13 and expose just
# libcudart.so.12 on the system linker path. orange keeps using libcudart.so.13 (its own
# SONAME) — the two coexist. No reboot needed. Self-elevates via sudo.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "Re-running with sudo..."; exec sudo -E "$0" "$@"; fi

EVT_LIB=/opt/EVT/eSDK/lib/libEmergentGPUDirect.so

echo "== before: how does the EVT GPUDirect lib resolve libcudart? =="
ldd "$EVT_LIB" 2>/dev/null | grep -i cudart || echo "  libcudart.so.12 => not found (expected)"
echo

echo "== finding the newest available cuda-cudart-12-x package =="
apt-get update -qq || true
PKG=$(apt-cache search '^cuda-cudart-12' | awk '/^cuda-cudart-12-[0-9]+ /{print $1}' | sort -V | tail -1)
[ -n "$PKG" ] || { echo "ERROR: no cuda-cudart-12-x in apt (is the NVIDIA cuda repo configured?)"; exit 1; }
echo "  installing: $PKG"
apt-get install -y "$PKG"
echo

# Locate the installed libcudart.so.12 and symlink it onto the system linker path.
VER=${PKG#cuda-cudart-}; VER=${VER/-/.}                       # e.g. cuda-cudart-12-9 -> 12.9
SRC=$(find "/usr/local/cuda-$VER" -name 'libcudart.so.12' 2>/dev/null | head -1)
[ -n "$SRC" ] || SRC=$(find /usr/local -path '*cuda-12*' -name 'libcudart.so.12' 2>/dev/null | head -1)
[ -n "$SRC" ] || { echo "ERROR: installed $PKG but could not find libcudart.so.12"; exit 1; }
echo "  found: $SRC"

ln -sf "$SRC" /usr/lib/x86_64-linux-gnu/libcudart.so.12
ldconfig
echo

echo "== verify =="
ldconfig -p | grep 'libcudart.so.12' || { echo "ERROR: libcudart.so.12 not registered with ldconfig"; exit 1; }
echo "-- EVT GPUDirect lib now resolves: --"
ldd "$EVT_LIB" 2>/dev/null | grep -i cudart || echo "  WARN: still not resolving — check the path above"
echo
echo "Done — no reboot needed. orange still uses CUDA 13 (libcudart.so.13)."
echo "Re-run the GPUDirect test (PTP first):"
echo "  T1: sudo ptp4l -i enp33s0f0np0 -f /etc/ptp4l.conf"
echo "  T2: sudo /bin/sync_NICs.sh"
echo "  T3: sudo -E ~/src/orange/release/orange     # aphid -> HEVC -> stream + record"
