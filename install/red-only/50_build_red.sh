#!/usr/bin/env bash
# 50_build_red — configure, build, test and install red (xp) (NO sudo).
# CUDA arch defaults to the A4000 (sm_86); override with CUDA_ARCH=89 etc.
# No TensorRT / ONNX Runtime: ML inference compiles out.
set -euo pipefail
RED=${RED_DIR:-$HOME/src/red}
cd "$RED"
[ "$(git rev-parse --abbrev-ref HEAD)" = xp ] || { echo "red is not on branch xp"; exit 1; }
git submodule update --init --recursive

cmake -S . -B release -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH:-86}"
cmake --build release --target red test_annotation test_gui -j"$(nproc)"

echo "=== link checks"
readelf -d release/red | grep -E 'RPATH|RUNPATH'
if ldd release/red | grep -i 'not found'; then echo "FAIL: unresolved libs"; exit 1; fi
echo "=== headless tests"
DISPLAY= ./release/test_annotation | tail -3
DISPLAY= ./release/test_gui | tail -3

echo "=== install launcher (~/.local/bin/red shadows Ubuntu's /usr/bin/red = ed)"
./install.sh
hash -r; command -v red
echo "OK: red built and installed"
