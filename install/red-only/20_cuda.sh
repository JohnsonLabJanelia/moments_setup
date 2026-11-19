#!/usr/bin/env bash
# 20_cuda — CUDA 13.1 toolkit ONLY from NVIDIA's apt repo (sudo). The 595
# driver (Ubuntu/graphics-drivers PPA) is NOT touched.
#
# The cuda-keyring installs a Pin-Priority 600 for the NVIDIA repo. Without a
# counter-pin, a later `apt upgrade` would replace nvidia-settings /
# libxnvctrl0 / libnvidia-egl-wayland1 with 620.x builds from the CUDA repo
# (dry-run verified 2026-11-19). 99-keep-ubuntu-nvidia-driver blocks every
# driver-side package from that repo.
#
#   ./20_cuda.sh            (prompts for sudo)
set -euo pipefail
CUDA_PKG=cuda-toolkit-13-1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 1. Counter-pin FIRST, so the repo never gets a chance to win.
sudo tee /etc/apt/preferences.d/99-keep-ubuntu-nvidia-driver >/dev/null <<'EOF'
# Driver-side NVIDIA packages must come from Ubuntu / graphics-drivers PPA
# (matching the installed 595 driver), never from the CUDA repo, whose
# 600 pin would otherwise swap them for other driver branches.
Package: nvidia-* libnvidia-* libxnvctrl* xserver-xorg-video-nvidia* cuda-drivers* libcuda1* libnvcuvid* libnvidia-encode* firmware-nvidia*
Pin: release l=NVIDIA CUDA
Pin-Priority: -1
EOF

# 2. Repo keyring.
if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  curl -fsSL -o "$TMP/cuda-keyring.deb" \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i "$TMP/cuda-keyring.deb"
fi
sudo apt-get update

# 3. Safety re-check, then install the toolkit.
SIM=$(apt-get -s install "$CUDA_PKG")
if grep -qE '^Remv' <<<"$SIM" || grep -E '^Inst' <<<"$SIM" | grep -qiE '^Inst (nvidia-|libnvidia-|linux-|.*dkms|cuda-drivers)'; then
  echo "ABORT: $CUDA_PKG would remove packages or pull driver/kernel packages:"
  grep -E '^Remv|^Inst' <<<"$SIM" | grep -iE 'Remv|nvidia-|linux-|dkms|cuda-drivers'
  exit 1
fi
SIMU=$(apt-get -s dist-upgrade)
if grep -E '^Inst' <<<"$SIMU" | grep 'NVIDIA CUDA' | grep -qiE '^Inst (nvidia-|libnvidia|libxnvctrl|xserver-xorg-video-nvidia)'; then
  echo "ABORT: counter-pin is not holding; a later apt upgrade would swap driver packages"; exit 1
fi
grep -E 'upgraded,' <<<"$SIM"
sudo apt-get install -y "$CUDA_PKG"

# 4. PATH / loader wiring (same as incubator).
sudo tee /etc/profile.d/cuda.sh >/dev/null <<'EOF'
export PATH=/usr/local/cuda/bin${PATH:+:$PATH}
EOF
echo /usr/local/cuda/lib64 | sudo tee /etc/ld.so.conf.d/cuda.conf >/dev/null
sudo ldconfig

# 5. Verify.
readlink -f /usr/local/cuda
/usr/local/cuda/bin/nvcc --version | tail -2
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
apt-cache policy nvidia-settings | sed -n 2,3p
echo "OK: CUDA toolkit installed (open a new shell, or: source /etc/profile.d/cuda.sh)"
