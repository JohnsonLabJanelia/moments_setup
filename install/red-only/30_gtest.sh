#!/usr/bin/env bash
# 30_gtest — build GoogleTest WITH gmock and install to /usr/local (sudo for
# the install only). red's xp CMakeLists does
#   find_package(GTest CONFIG HINTS /usr/local/lib/cmake/GTest NO_CMAKE_SYSTEM_PATH)
# before Ceres; the apt libgtest-dev alone doesn't satisfy it.
# Needs /usr/src/googletest from 10_apt_deps.sh (package `googletest`).
#
#   ./30_gtest.sh           (prompts for sudo)
set -euo pipefail
[ -f /usr/src/googletest/CMakeLists.txt ] || { echo "run 10_apt_deps.sh first"; exit 1; }
BUILD=$(mktemp -d); trap 'rm -rf "$BUILD"' EXIT
cmake -S /usr/src/googletest -B "$BUILD" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$(nproc)"
sudo cmake --install "$BUILD"
ls /usr/local/lib/cmake/GTest/GTestConfig.cmake /usr/local/lib/libgmock.a
echo "OK: GoogleTest + gmock in /usr/local"
