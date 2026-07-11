# Field notes — `red` + JARVIS TensorRT-10 on flyrig (Ada / 24.04 / CUDA-13) — July 2026

End-to-end runbook for enabling **JARVIS HybridNet 3D pose inference in `red`** on the
**flyrig** box (hostname `flyrig`: 2× A16 sm_86 + **RTX 4000 Ada sm_89**, Ubuntu **24.04.4**,
**CUDA 13.1**, driver 595). This is the **option B (TensorRT 10, CUDA-13 native)** path that
[`RED_2404_NOTES.md`](RED_2404_NOTES.md) §5 described as *preferred but not yet attempted* —
it is now **DONE & verified** (load path). Companion to the TRT-8.6 runbook for the reference
box, [`RED_A6000_2204_TENSORRT_NOTES.md`](RED_A6000_2204_TENSORRT_NOTES.md).

Repo: **`moments-behavior/red`**, branch **`trt10-cuda13`** (off `xp`).

---

## 0. Result

- Chose **TRT 10 over the §4 TRT-8.6 bundle**: TRT 10 has a CUDA-13 build, so it links the
  system `/usr/local/cuda` 13.1 directly — **no** bundled CUDA-12 runtime / cuDNN-8.9 / shim.
- red's TRT runtime needed **zero source-API changes** (as §5b predicted) — only a CMake
  detection change + a device-pinning fix. Both are committed on `trt10-cuda13`.
- All 3 Fly50_V5 engines recompiled from the portable ONNX with TRT-10 `trtexec` and **load in
  red**: `[HybridNet] load SUCCEEDED (TRT direct runtime)` — 50 joints, 7 cams, bbox 448,
  roi 4.8 mm / grid 0.1 mm (`--world_scale 0.1`). Remaining: the human GUI accuracy eyeball.

## 1. ⚠ orange runs live capture on this box — protect it

`orange` captures on the **8 A16 dies**; the **RTX 4000 Ada (nvidia-smi index 4)** is the
display GPU and is free for compute. Before/after:

- **Any apt change: dry-run first** (`apt-get install -s …`, no sudo, no change) and confirm
  it's additive (`0 upgraded, 0 to remove`) and pulls **no** driver / CUDA / FFmpeg / DKMS
  package. The TRT-10 install below is purely additive and restarts nothing, so it does **not**
  disturb a running capture. Let the operator pick the timing anyway.
- **Pin every red/trtexec GPU step to the Ada** so it can't touch a capture die:
  `CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=<ada-index>`. The helper scripts below
  auto-resolve the Ada by name.

## 2. Install TensorRT 10 (apt, CUDA-13 build)

The CUDA apt repo is already configured on flyrig. Pin to **10.16** — the bare `tensorrt`
metapackage now resolves to **TRT 11**, which we did not want. `sudo` is password-gated here,
so run it in a real terminal:

```bash
sudo apt-get install -y \
    libnvinfer10=10.16.1.11-1+cuda13.2 \
    libnvinfer-plugin10=10.16.1.11-1+cuda13.2 \
    libnvonnxparsers10=10.16.1.11-1+cuda13.2 \
    libnvinfer-headers-dev=10.16.1.11-1+cuda13.2 \
    libnvinfer-safe-headers-dev=10.16.1.11-1+cuda13.2 \
    libnvinfer-headers-plugin-dev=10.16.1.11-1+cuda13.2 \
    libnvinfer-dev=10.16.1.11-1+cuda13.2 \
    libnvinfer-plugin-dev=10.16.1.11-1+cuda13.2 \
    libnvinfer-bin=10.16.1.11-1+cuda13.2
```

Gotchas: `libnvinfer-dev`/`-plugin-dev` pull `libnvinfer-safe-headers-dev` /
`libnvinfer-headers-plugin-dev` — pin **those to 10.16 too** or apt drags in the TRT-11
headers and the resolve fails. `libnvinfer-bin` provides **`trtexec` at `/usr/bin/trtexec`**.
Headers land in `/usr/include/x86_64-linux-gnu`, libs (`libnvinfer.so`→`.so.10`,
`libnvinfer_plugin.so`→`.so.10`) in `/usr/lib/x86_64-linux-gnu`.

## 3. The red source change (committed on `trt10-cuda13`)

1. **`CMakeLists.txt` — dual-layout TRT detection.** The Linux branch hardcoded the reference
   box's tarball (`$HOME/nvidia/TensorRT-8.6.1.6`, `<dir>/include` + `<dir>/lib`). Now it tries
   that tarball first (backward-compatible; still `-DTENSORRT_DIR=`-overridable), then falls
   back to a **system/apt** install via `find_path(NvInfer.h)` / `find_library(nvinfer,
   nvinfer_plugin)`, routing include/link/RPATH through the resolved
   `TENSORRT_INCLUDE_DIR`/`TENSORRT_LIB`/`TENSORRT_PLUGIN_LIB`/`TENSORRT_LIB_DIR`. On a system
   install, no build-tree RPATH into `$HOME` is needed (libs are on the default loader path).
2. **`src/jarvis_hybridnet.h` — device pinning.** The two predict-path `cudaSetDevice(0)` were
   hardcoded; `jarvis_hybridnet_load` takes a `gpu_device_id`. Store it in
   `JarvisHybridNetState` and use it at both predict sites so inference stays on the device
   that holds the engine memory (matters on this A16+Ada box). With `CUDA_VISIBLE_DEVICES`
   masking to the Ada, device 0 = Ada, so the default `gpu_device_id=0` is already correct.

No `enqueueV3`/`setTensorAddress`/… changes: red loads prebuilt engines and already uses only
the name-based API shared across TRT 8.5–11.

Build (leave CPU headroom for capture):
```bash
cd ~/src/red && git checkout trt10-cuda13
cmake -S . -B release -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES="86;89"
cmake --build release --target red -j$(( $(nproc)/2 ))
```
Configure should print `TensorRT found in system paths: /usr/lib/x86_64-linux-gnu/libnvinfer.so`.
Confirm the binary links TRT 10: `ldd release/red | grep nvinfer` → `libnvinfer.so.10`.

## 4. Recompile the 3 engines with TRT-10 `trtexec` (on the Ada)

`scripts/compile_tensorrt_engines.sh` hardcodes the wrong shapes for this model (batch 16,
spatial 704). Drive `trtexec` with the Fly50 shapes (7 cams; center 320; effTrack bbox 448;
padded_hw = bbox/2+2 = 226), pinned to the Ada. TRT-10 note: `--workspace` → **`--memPoolSize=workspace:4096`**.

```bash
ADA=$(nvidia-smi --query-gpu=index,name --format=csv,noheader | awk -F', ' '/RTX 4000 Ada/{print $1; exit}')
export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$ADA
cd <project>/jarvis_Fly50
trtexec --onnx=center_detect.onnx      --saveEngine=center_detect.engine      --memPoolSize=workspace:4096 \
  --minShapes=input:7x3x320x320 --optShapes=input:7x3x320x320 --maxShapes=input:7x3x320x320
trtexec --onnx=hybridnet_efftrack.onnx --saveEngine=hybridnet_efftrack.engine --memPoolSize=workspace:4096 \
  --minShapes=input:7x3x448x448 --optShapes=input:7x3x448x448 --maxShapes=input:7x3x448x448
trtexec --onnx=hybrid3d.onnx           --saveEngine=hybrid3d.engine           --memPoolSize=workspace:4096 \
  --minShapes=heatmaps_padded:1x7x50x226x226,centerHM:1x7x2,center3D:1x3,cameraMatrices:1x7x4x3 \
  --optShapes=heatmaps_padded:1x7x50x226x226,centerHM:1x7x2,center3D:1x3,cameraMatrices:1x7x4x3 \
  --maxShapes=heatmaps_padded:1x7x50x226x226,centerHM:1x7x2,center3D:1x3,cameraMatrices:1x7x4x3
```
Each prints `&&&& PASSED`. **`hybrid3d` builds with no `InstanceNormalization_TRT` plugin** —
TRT 10 handles the export's decomposed InstanceNorm natively (§5c prediction confirmed).
Engines are arch- + TRT-version-specific: these are sm_89-selected TRT-10.16; recompile per box.
(A ready-to-run version of this lives at `<project>/jarvis_Fly50/compile_engines_trt10.sh`.)

## 5. Verify + run

- **Headless load check** (what we used): a throwaway `test_fly50_load` target that calls red's
  own `jarvis_hybridnet_load` on the model dir — exercises manifest + all 3 engine
  deserializations + red's I/O-tensor validation (more than `trtexec --loadEngine`). Expect
  `[HybridNet] load SUCCEEDED (TRT direct runtime)` / `joints=50 cams=7 bbox=448`. Reverted
  after use; re-add to the Linux `foreach(TEST_NAME …)` if you want it again.
- **GUI (the accuracy eyeball):** launch pinned to the Ada, open JARVIS Predict (auto-loads
  `active_jarvis_model`), run Predict on a clip:
  ```bash
  CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$ADA red <project>.redproj
  ```

## 6. Project layout (same as the A6000 runbook §2/§5)

`telecentric: true`, `annotation_2d: false`, `skeleton_name: "Fly50"`, camera names = video
stems (`CamXXXX.mp4` + `CamXXXX_dlt.csv`), `jarvis_models[].relative_path` → the
`jarvis_Fly50` folder (must hold the 3 `.onnx` + 3 `.engine` + `manifest.json`). Working
example on flyrig: `/home/rob/red_data/fly_posts39a_0708/`.

## 7. Backward compatibility

The tarball path is untouched, so the 22.04 reference box keeps using its
`$HOME/nvidia/TensorRT-8.6.1.6` with no change. The Blackwell box (sm_120) should follow this
same recipe (TRT-10 apt + recompile engines targeting sm_120) — untested there but expected to
work identically given the shared runtime API.
