#!/usr/bin/env bash
# 40_ffmpeg — FFmpeg n4.4.5 shared build → ~/nvidia/ffmpeg/build (NO sudo).
# red's CMake prefers this pkg-config dir over system FFmpeg. Recipe from
# moments_setup INCUBATOR_2404_NOTES.md §3 (demux only; NVDEC goes via
# libnvcuvid, not FFmpeg). Needs nasm from 10_apt_deps.sh.
set -euo pipefail
SRC=$HOME/nvidia/ffmpeg-src; PREFIX=$HOME/nvidia/ffmpeg/build
[ -d "$SRC" ] || git clone --depth 1 --branch n4.4.5 https://github.com/FFmpeg/FFmpeg.git "$SRC"
cd "$SRC"
./configure --prefix="$PREFIX" --enable-shared --disable-static --disable-doc --enable-pic
make -j"$(nproc)"
make install
LD_LIBRARY_PATH=$PREFIX/lib "$PREFIX/bin/ffmpeg" -version | head -1
PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig pkg-config --modversion libavcodec libavformat libavutil libswscale
echo "OK: FFmpeg n4.4.5 at $PREFIX"
