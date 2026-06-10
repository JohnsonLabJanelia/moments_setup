# Field notes — `red` on Blackwell + Ubuntu 24.04 / CUDA 13 (June 2026)

Companion to [`BLACKWELL_2404_NOTES.md`](BLACKWELL_2404_NOTES.md) (which covers `orange`
on the same box). This file covers getting **`red`** (the offline multi-camera 3D
keypoint-labeling app, branch `xp`) onto the Blackwell / 24.04 / CUDA-13.1 machine.

`red` has **no Emergent/camera dependency** — it reads recorded video. It shares
orange's NVIDIA toolchain **read-only** (CUDA at `/usr/local/cuda`, custom FFmpeg at
`$HOME/nvidia/ffmpeg`, driver 590) and never installs into or upgrades them. Its own ML
libs live under `red/lib/` with `$ORIGIN/../lib/...` RPATH isolation so they can't collide
with orange's stack.

---

## 0. Status (as of 2026-06-10)

- **Phase A — core red: DONE & VERIFIED.** Builds on 24.04 / gcc-13 / CUDA 13.1; the
  headless suites pass (`test_annotation` 673/673, `test_gui` 178/178). This is video
  playback (NVDEC), ArUco calibration + bundle adjustment, triangulation, and the v2
  annotation/CSV layer. Fixes committed to `red` `xp` as **`d9d2a09`** (backward-compatible
  with the 22.04 reference box).
- **Phase B — ML inference (JARVIS pose + SAM): NOT YET DONE.** Plan in §4. Requires
  staging the TensorRT 8.6 + cuDNN 8.9 + CUDA-12-runtime artifacts on this box.

The GUI itself hasn't been launched here yet (needs a display + a project) — the 851
headless tests are the validation so far. Worth a manual GUI smoke test.

---

## 1. Why red was *easier* than orange

The CUDA-13 source hazards that bit orange were **already handled** in `red`:

| Hazard | orange had to fix | red status |
|---|---|---|
| `cuCtxCreate` 3-arg `_v2` → 4-arg `_v4` | yes | **already guarded** `#if CUDA_VERSION >= 13000` (`src/AppDecUtils.h:145`, from the Windows port) |
| NPP context-less calls removed in 13 → `_Ctx` | yes | **no NPP calls at all** (libs linked but unused — vestigial) |
| NVTX header/lib drift (`libnvToolsExt` gone) | yes | **NVTX not used** |
| TensorRT API | n/a | already on modern `enqueueV3` (forward-compatible to TRT 10) |

So core red needed only the three 24.04/gcc-13 build fixes below — no CUDA-13 source
porting.

---

## 2. The three fixes (committed, cross-version, NOT gated)

All three are safe on both 22.04 and 24.04, so none are `#if`-guarded:

1. **`src/global.h`: add `#include <string>`.** gcc-13's libstdc++ no longer transitively
   pulls `<string>` through `<map>`/`<unordered_map>`; the `std::string` template args in
   the global decls failed (`'string' is not a member of 'std'`). Harmless on 22.04.
2. **`CMakeLists.txt`: find the CBLAS provider instead of hardcoding `-lcblas`.** 24.04
   dropped the `libcblas.so` name; `libopenblas.so` exports the full `cblas_*` API.
   `find_library(RED_CBLAS_LIB NAMES cblas openblas blas)` tries `cblas` first, so the
   reference box still links `libcblas.so`; the new box resolves to
   `/usr/lib/x86_64-linux-gnu/libopenblas.so`.
3. **`CMakeLists.txt`: `-Wl,--disable-new-dtags` on `red` + test targets.** The shared
   FFmpeg's `libavcodec` has a transitive `DT_NEEDED` on `libswresample.so.3` (same dir).
   `DT_RUNPATH` (the linker default) does **not** apply to a dependency's own NEEDED libs,
   so `libswresample.so.3` reported "not found" at load; `DT_RPATH` propagates and resolves
   it. **Same fix orange uses for its bundled FFmpeg.**

---

## 3. Install order that worked (core red)

Internet is available on this box; everything here is online apt + one source build.

```bash
# 0. Prereqs (system, online). Shared with nothing destructive.
sudo apt-get update && sudo apt-get install -y \
    libeigen3-dev libceres-dev libopenblas-dev patchelf libgtest-dev libgmock-dev

# Ceres needs the GTest::gmock target via absl; apt's libgtest-dev (in
# /usr/lib/x86_64-linux-gnu) ships gtest only, so build googletest+gmock to
# /usr/local where red's CMake looks for it first.
cmake -S /usr/src/googletest -B /tmp/gtest-build -DCMAKE_BUILD_TYPE=Release
sudo cmake --build /tmp/gtest-build --target install -j

# 1. Source + submodule (implot3d is a submodule and won't be present on a fresh clone)
cd ~/src/red
git submodule update --init lib/implot3d

# 2. Configure. nvcc is not on PATH → pass it explicitly (same as orange).
#    Archs: 86 = A16, 89 = RTX 4000 Ada, 120 = Blackwell display GPU.
cmake -S . -B release -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
    -DCMAKE_CUDA_ARCHITECTURES="86;89;120"

# 3. Build
cmake --build release --target red test_annotation test_gui -j$(nproc)
```

Already present on this box (shared with orange, do not reinstall): CUDA 13.1
(`/usr/local/cuda`), custom FFmpeg (`$HOME/nvidia/ffmpeg/build/lib/pkgconfig`), glfw3,
GLEW, driver-provided `libnvcuvid.so` (driver 590).

### Verify
```bash
cd ~/src/red
readelf -d release/red | grep -E "RPATH|RUNPATH"   # want RPATH (old dtags)
ldd release/red | grep -i "not found"              # want: nothing
DISPLAY= ./release/test_annotation                  # 673 passed, 0 failed
DISPLAY= ./release/test_gui                          # 178 passed, 0 failed
```

---

## 4. Phase B — ML inference (JARVIS pose + SAM) — PLAN, not yet done

red's ML is optional, auto-detected by CMake `HAS_*` gates; absent its libs the build
compiles it out (that's what Phase A is). To enable inference on this box:

### 4a. JARVIS HybridNet = **TensorRT** (no longer ORT)
As of red `b0325a8` ("HN: rip out ORT"), the HybridNet path **requires TensorRT** — the
ONNX-Runtime fallback was removed and the gate switched from `RED_HAS_ONNXRUNTIME` to
`RED_HAS_TENSORRT_HN`. red is written against **TensorRT 8.6.1.6**, a CUDA-12 library
(links `cudart.12`/`cublas.12`/`cudnn8`) — none of which exist on this CUDA-13 box.

**Recommended approach — bundle, don't shim.** red already RPATH-isolates its ML libs
under `lib/`. So rather than make TRT 8.6 speak CUDA 13 (or do a risky TRT-10 API
migration), bundle a **self-contained CUDA-12 runtime + TRT 8.6 + cuDNN 8.9 under
`lib/`** with `$ORIGIN` RPATH, running on the 590 driver:
- A CUDA-12.x app runs fine on a 590 driver (driver compat is backward).
- JARVIS inference targets an **A16 die (sm_86)**, which TRT 8.6 fully supports.
- Keeps orange's `/usr/local/cuda` (13.1) untouched and preserves backward compat: the
  22.04 reference box keeps using its system TRT at `$HOME/nvidia/TensorRT-8.6.1.6`
  (the CMake `HAS_TENSORRT_HN` check already points there); the 24.04 box uses the bundle.

Engines compile offline via `scripts/compile_tensorrt_engines.sh` (defaults to
`$HOME/nvidia/TensorRT-8.6.1.6`); they are GPU-arch- and TRT-version-specific, so compile
them **on an A16** here.

⚠️ **Device-pinning gotcha (must fix for Phase B).** JARVIS hardcodes `cudaSetDevice(0)`
(`src/jarvis_hybridnet.h:869,1161`) and red.cpp does **not** pin
`CUDA_DEVICE_ORDER=PCI_BUS_ID` the way orange does. On this box, default CUDA ordering can
make device 0 the **Blackwell (sm_120)** — which TRT 8.6 **cannot** run. Inference must be
pinned to an sm_86 A16 (e.g. set `CUDA_DEVICE_ORDER=PCI_BUS_ID` so device 0 = first A16,
or enumerate for an sm_86 device). This is the red-side analogue of orange's GPU-ordering
work.

### 4b. SAM (MobileSAM) = ONNX Runtime, still used
SAM and an older `jarvis_inference.h` path still use ORT (gated by `RED_HAS_ONNXRUNTIME`).
red's design bundles an ORT GPU build + **cuDNN 9** under `lib/onnxruntime` + `lib/cudnn`
(distinct from TRT's cuDNN 8.9) with a `patchelf` RPATH fix on
`libonnxruntime_providers_cuda.so` (CMakeLists handles this when `patchelf` is present —
already installed in §3). The ORT build must match: CUDA-12 ORT + cuDNN 9 + the bundled
CUDA-12 runtime. Stage an ORT release that supports CUDA 12 into `lib/onnxruntime`.

### Phase-B checklist
- [ ] Stage TRT 8.6.1.6 + cuDNN 8.9 + a CUDA-12 runtime under `red/lib/`, RPATH-isolated.
- [ ] Pin JARVIS inference to an A16 (sm_86); don't let it land on the Blackwell.
- [ ] Compile JARVIS engines on an A16 via `scripts/compile_tensorrt_engines.sh`.
- [ ] Stage CUDA-12 ORT + cuDNN 9 under `lib/onnxruntime` / `lib/cudnn` for SAM.
- [ ] (optional) MuJoCo under `lib/mujoco` for body-model IK.

---

## 5. Known issues / TODO

- **GUI not yet smoke-tested on this box.** Only the 851 headless tests have run. Launch
  `./release/red` with a display + a project to confirm NVDEC playback + OpenGL render.
- **24.04 apt drift was benign.** red built clean against Ceres **2.2.0** / Eigen **3.4.0**
  (vs the 22.04 reference). No Ceres/Eigen API breakage materialized — the only 24.04
  issues were the three in §2.
- **Phase B (ML inference) is unstarted** — see §4, especially the sm_86 device-pinning.
