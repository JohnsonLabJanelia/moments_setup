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

- **Phase A — core red: DONE, VERIFIED & PUSHED.** Builds on 24.04 / gcc-13 / CUDA 13.1;
  the headless suites pass (`test_annotation` 673/673, `test_gui` 178/178) **and Rob
  confirmed GUI playback** of a real orange-recorded video (NVDEC + OpenGL). This is video
  playback, ArUco calibration + bundle adjustment, triangulation, and the v2 annotation/CSV
  layer. Fixes pushed to `red` **`origin/xp` @ `d9d2a09`** (backward-compatible with the
  22.04 reference box).
- **Phase B — ML inference (JARVIS pose + SAM): NOT YET DONE.** Two options:
  - **§4 (option A):** JARVIS on an **A16 (sm_86)** via the existing **TensorRT 8.6** —
    conservative, matches the 22.04 reference box; needs a bundled CUDA-12 runtime.
  - **§5 (option B, PREFERRED):** JARVIS on the **Blackwell GPU (sm_120)** via **TensorRT
    10** — cleaner on this box (no CUDA-12 bundling), needs a TRT bump + its own branch.

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

## 4. Phase B (option A) — JARVIS on an A16 via TensorRT 8.6 — PLAN, not yet done

red's ML is optional, auto-detected by CMake `HAS_*` gates; absent its libs the build
compiles it out (that's what Phase A is). To enable inference on this box.

> **There are two ways to do Phase B.** This §4 is the conservative path: JARVIS on an
> **A16 die (sm_86)** with the existing **TensorRT 8.6**, matching the 22.04 reference box.
> §5 is the path **Rob prefers** — JARVIS on the **Blackwell GPU (sm_120) via TensorRT 10**,
> which is actually *cleaner* on this box (no CUDA-12 bundling) but needs a TRT-version bump
> and its own branch. Read both, then pick; they are mutually exclusive for a given engine
> set (engines are arch- + TRT-version-specific).

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

## 5. Phase B (option B, PREFERRED) — JARVIS on the Blackwell GPU via TensorRT 10

This is the path Rob wants: run JARVIS inference on the **RTX PRO 4000 Blackwell**
(sm_120, `nvidia-smi` idx 8) instead of an A16 die. Researched 2026-06-10; **not yet
attempted**. It is feasible and, on this box, **architecturally cleaner** than §4 — but it
requires moving off TensorRT 8.6, so do it on a **dedicated branch**.

### 5a. The one hard requirement: TensorRT 10
TensorRT **8.6 cannot target Blackwell** — it tops out at sm_90 (Hopper). Running JARVIS on
sm_120 requires **TensorRT 10.x** (use **10.8+** for solid RTX-PRO-Blackwell support).

### 5b. Why this is *less* work than a normal TRT major-version bump
red's TRT runtime code (`src/jarvis_hybridnet.h`, `src/jarvis_tensorrt.h`) is **already
written against the modern name-based API that TRT 8.5→10 share**, so the source migration
is likely near-zero:
- Uses `enqueueV3`, `setTensorAddress`, `setInputShape`, `getTensorShape`,
  `getIOTensorName`, `getNbIOTensors`, `createInferRuntime`, `deserializeCudaEngine`.
- Uses **none** of the binding-index APIs TRT 10 *removed* (`setBindingDimensions`,
  `getNbBindings`, `bindingIndex`).
- Does **no runtime engine-building** (loads prebuilt `.engine` files), so TRT 10's
  builder-API changes (`setMaxWorkspaceSize` → `setMemoryPoolLimit`, etc.) don't touch the
  app — only the offline `scripts/compile_tensorrt_engines.sh`, which just calls `trtexec`.

### 5c. Why it's cleaner than §4 on this box
- **TRT 10 has a CUDA-13 build** → it links the system `/usr/local/cuda` 13.1 directly.
  That **eliminates the entire §4 scaffolding**: no bundled CUDA-12 runtime, no
  `libcudart.so.12` shim, and no cuDNN 8.9 (TRT 10 also dropped the hard cuDNN dependency).
- The ONNX export (`scripts/export_jarvis_onnx.py`) already decomposes InstanceNorm into
  primitives (`ManualInstanceNorm2d/3d`), so the historical `InstanceNormalization_TRT`
  plugin may not even be needed under TRT 10 — one less risk (verify against the shipped
  models).

### 5d. What the work actually is
1. Install **TensorRT 10 (CUDA-13 build)** on the box (e.g. under `$HOME/nvidia/TensorRT-10.x`).
2. Point red's CMake `TENSORRT_DIR` at it (currently hardcoded to `~/nvidia/TensorRT-8.6.1.6`
   at `CMakeLists.txt` Linux branch).
3. **Recompile the 3 JARVIS engines** with TRT 10's `trtexec`, targeting **sm_120**.
4. **Retarget inference to the Blackwell**: thread the Blackwell's device index into
   `gpu_device_id` and fix the two hot-path `cudaSetDevice(0)` hardcodes
   (`src/jarvis_hybridnet.h:869,1161`). (Same device-selection cleanup §4 needs, pointed at
   the other GPU.)
5. Build, run real inference on real video, fix any minor TRT-10 symbol deltas (expected
   tiny given 5b).

### 5e. Backward compatibility (drives the branch decision)
TRT 10 won't build on the **22.04 reference box** (it has TRT 8.6). Two ways to keep both:
- **Guard with `NV_TENSORRT_MAJOR`** — and because the runtime API is already shared, this
  likely needs little/no code divergence; mostly it's *which TRT dir + which engine files*.
  red has **no** such guards today, so they'd be added on this branch.
- Or move the reference box to TRT 10 as well (simpler code, bigger ask for that machine).

### 5f. Use a dedicated branch (e.g. `blackwell-trt10`)
- Coherent, end-to-end-testable unit (TRT bump + engine recompile + device retarget) with
  **real unknowns to validate before touching `xp`**: that TRT 10 builds the *hybrid3d*
  model for sm_120, the plugin situation, and **perf**.
- `xp` is the shared cross-platform branch; Windows also has an optional TRT path
  (`jarvis_tensorrt.h`), so a TRT-version move could ripple — isolate it.
- Clean rollback if TRT 10 + Blackwell hits a wall; merge back to `xp` (guarded) once real
  inference on real video is proven.

### 5g. Caveats to weigh
- The Blackwell is also the **display GPU**, so JARVIS would share it with the GL
  preview/render. For offline labeling that's normally fine — and a single A16 die is a weak
  quarter-card, so the Blackwell is very likely **faster** for inference — but the UI may get
  less responsive during heavy prediction.
- TRT 10 spans a wide arch range, so a CUDA-13 TRT-10 build can target **both** sm_120 and
  sm_86 — you can compile engines for both and keep the A16 as a fallback.

---

## 6. Known issues / TODO

- **GUI playback CONFIRMED (2026-06-10).** Rob opened a video recorded by orange on this box
  and red plays it back fine (NVDEC + OpenGL). Headless suites also pass (851 tests).
- **24.04 apt drift was benign.** red built clean against Ceres **2.2.0** / Eigen **3.4.0**
  (vs the 22.04 reference). No Ceres/Eigen API breakage materialized — the only 24.04
  issues were the three in §2.
- **Phase B (ML inference) is unstarted** — choose §4 (A16 / TRT 8.6) or §5 (Blackwell /
  TRT 10, preferred). Either way, fix the JARVIS device-selection hardcodes.
- **Verify the `xp` `d9d2a09` fixes still build on the 22.04 reference box** — they're
  written to be backward-compatible but have only been built on 24.04 so far.
