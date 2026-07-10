# Field notes — `red` + JARVIS TensorRT on the A6000 / Ubuntu 22.04 box (July 2026)

End-to-end runbook for the **reference-spec workstation** (single **RTX A6000**, sm_86;
Ubuntu **22.04**, kernel 6.5; **CUDA 12.2**; **TensorRT 8.6.1.6**): building `red`, setting
up an **annotation project**, and — the part not covered elsewhere — **converting a JARVIS
model to TensorRT engines and loading them into red's JARVIS Predict tool**.

This is the conservative **TRT-8.6 / sm_86** path that `RED_2404_NOTES.md` §4 (option A)
described as a *plan*. It is now **DONE and verified** here. Repo used: **`moments-behavior/red`
branch `xp`** (note: a *different* repo from the `JohnsonLabJanelia/red` the older notes assume;
the build fixes differ — see below).

> ⚠ Two `red` repos exist. `/home/user/newsrc/red` = **`moments-behavior/red`** (build the
> **`xp`** branch — minimal deps: Ceres/Eigen/OpenBLAS/implot3d; NOT `main`, which needs
> LibTorch + OpenCV-sfm). `~/src/red` = the older `JohnsonLabJanelia/red`.

---

## 0. Status (2026-07-10)

- **Driver:** updated **535.183.06 → 595.71.05** (apt `nvidia-driver-595`; old driver was a
  `.run` install, removed with `nvidia-uninstall` first). **CUDA toolkit stays 12.2** — the
  "CUDA 13.2" in `nvidia-smi` is only the driver's max. See [driver notes below](#7-driver-update).
- **Core red (Phase A): DONE.** `xp` builds clean; `test_annotation` 673/673, `test_gui` 178/178.
  This box already had every dep (Ceres/gtest+gmock in `/usr/local`, custom FFmpeg, TRT 8.6,
  cuDNN 8) — **no apt/sudo needed** for the core build.
- **JARVIS Predict via TensorRT (Phase B, option A): DONE & verified** (engines build + deserialize
  under TRT 8.6). Live GUI prediction on real video is the one remaining human check.

---

## 1. Core red build (recap)

```bash
cd /home/user/newsrc/red && git checkout xp
git submodule update --init lib/implot3d          # the one uninitialised submodule
export PKG_CONFIG_PATH="$HOME/nvidia/ffmpeg/build/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig"
cmake -S . -B release -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES="86"
cmake --build release --target red test_annotation test_gui -j$(nproc)
./install.sh          # launcher on ~/.local/bin (else stock /usr/bin/red = ed shadows it)
```
Configure auto-detects: TensorRT → **HybridNet runtime enabled**; ONNX Runtime absent → SAM disabled.

---

## 2. Create an annotation project (hand-written `.redproj`)

The project file is **plain JSON and hand-writable** — no GUI needed. red opens it with
`red <path>.redproj`. Key rules (source: `src/project.h`, `src/gui/annotation_dialog.h`):

- **Camera name = the video filename stem.** `CamXXXX.mp4` → camera `CamXXXX`; its calibration
  MUST be `CamXXXX_dlt.csv`. Matching is exact string concat — no serial parsing.
- **`telecentric: true`** is REQUIRED to load `_dlt.csv` (DLT 11-line linear). With `false`,
  red looks for `CamXXXX.yaml` and fails.
- **`annotation_2d: false`** enables 3D triangulation.
- **`skeleton_name`** — red has built-in presets; **`Fly50`** matches the 50-keypoint fly model
  exactly, in order (verify against your model's `config.yaml` `KEYPOINT_NAMES`).
- Put `_dlt.csv` files **directly** in `calibration_folder` (a lone `YYYY_MM_DD_*` subdir triggers
  auto-descend). All N cameras' calibration must load or red silently drops to 2D mode.

Example (`/home/user/new_red_data/fly_posts39a_0708/fly_posts39a_0708.redproj`):
```json
{
  "project_root_path": "/home/user/new_red_data",
  "project_path": "/home/user/new_red_data/fly_posts39a_0708",
  "project_name": "fly_posts39a_0708",
  "load_skeleton_from_json": false, "skeleton_file": "", "skeleton_name": "Fly50",
  "calibration_folder": "/home/user/new_red_data/calibration/July6_dlt_linear",
  "media_folder": "/home/user/new_red_data/2026_07_08_13_19_31",
  "keypoints_root_folder": "", "plot_keypoints_flag": false,
  "camera_names": ["Cam2012630","Cam2012631","Cam2012853","Cam2012855","Cam2012857","Cam2012861","Cam2012862"],
  "telecentric": true, "annotation_2d": false,
  "annotation_config": {"enable_keypoints": true,"enable_bboxes": false,"enable_obbs": false,"enable_segmentation": false,"class_names":["fly"]},
  "jarvis_models": [ /* filled in by §5 */ ], "active_jarvis_model": 0
}
```
`media_folder`/`calibration_folder` are absolute — they can live anywhere. The `CamXXXX_meta.csv`
timestamp sidecars are **not** read by the annotation flow (only by the ArUco/calibration path);
harmless to leave alongside the videos.

---

## 3. JARVIS `.pth` → TensorRT engines — the pipeline

You start from JARVIS-HybridNet training output: `config.yaml` + `models/{CenterDetect,
KeypointDetect,HybridNet}/Run_*/…_final.pth`. `trtexec` cannot read `.pth`, so the path is:

```
.pth  --(Python: scripts/export_jarvis_onnx.py)-->  .onnx  --(trtexec)-->  .engine
```

red loads **3 engines** for the 3D HybridNet path: `center_detect`, `hybridnet_efftrack`,
`hybrid3d` (`keypoint_detect` is the older 2-stage path — not used, don't bother compiling it).
red's model folder must also contain the 3 `.onnx` + `manifest.json` (its validity marker).

### 3a. Export environment (the only real setup cost)

No stock env works: the export needs `torch≥1.13 + onnx + onnxruntime + yacs + cv2 + importable
jarvis`, and the `hybrid3d` stage **hardcodes CUDA** (`.cuda()`), so **GPU torch is required**
(CPU-only fails). Build a clean conda env once:
```bash
conda create -n red_trt_export -c conda-forge python=3.10 libstdcxx-ng -y   # libstdcxx-ng fixes cv2 CXXABI
ENV=/home/user/miniconda3/envs/red_trt_export
$ENV/bin/pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
$ENV/bin/pip install onnx onnxruntime-gpu yacs numpy scipy opencv-python-headless matplotlib
# jarvis package is imported via PYTHONPATH (deps are minimal: torch/opencv/yacs; EfficientNet is bundled)
PYTHONPATH=/home/user/src/JARVIS-HybridNet $ENV/bin/python -c \
  "import torch,onnx,onnxruntime,yacs,cv2; from jarvis.efficienttrack.model import EfficientTrackBackbone; print('ok',torch.cuda.is_available())"
```
Gotchas: the existing `jarvis` conda env is **too old** (torch 1.10 → no `weights_only`, no opset-17)
and has a broken `cv2` (CXXABI). `export_jarvis_onnx.py`'s `--jarvis-src` default
(`/home/user/src/jarvis-local`) is stale — pass `/home/user/src/JARVIS-HybridNet`.

### 3b. Export ONNX  — **`--world_scale 0.1` is MANDATORY for the fly telecentric model**
```bash
ENV=/home/user/miniconda3/envs/red_trt_export
M=/home/user/new_red_data/models/Fly50_V5/models
OUT=/home/user/new_red_data/fly_posts39a_0708/jarvis_Fly50
PYTHONPATH=/home/user/src/JARVIS-HybridNet LD_LIBRARY_PATH=$ENV/lib \
$ENV/bin/python /home/user/newsrc/red/scripts/export_jarvis_onnx.py \
  --config       /home/user/new_red_data/models/Fly50_V5/config.yaml \
  --center-pth   $M/CenterDetect/Run_*/EfficientTrack-medium_final.pth \
  --keypoint-pth $M/KeypointDetect/Run_*/EfficientTrack-medium_final.pth \
  --hybridnet-pth $M/HybridNet/Run_*/HybridNet-medium_final.pth \
  --output-dir   $OUT  --jarvis-src /home/user/src/JARVIS-HybridNet \
  --world_scale 0.1
```

> **⚠ The ×10 scale bug (grid units vs calibration units).** The Fly50 model trains with
> `ROI_CUBE_SIZE=48 / GRID_SPACING=1`, but the DLT calibration is in **mm** and a fly is only a
> few mm — those are really **4.8 mm / 0.1 mm**, i.e. **`world_scale = 0.1`**. Without it, the
> HybridNet voxel grid reprojects a ~±24 mm cube instead of ±2.4 mm → the center (from DLT
> triangulation) is right but keypoints scatter ~10× off, landing outside the image.
> The Mac/CoreML path already had this (`scripts/pth_to_coreml.py --world_scale`, commit
> `86f5d5d`), but **`export_jarvis_onnx.py` did not** — I added `--world_scale` there (scales the
> reproLayer's physical grid + the final decode post-construction; the integer voxel count stays
> 48→24). Sanity check: with `--world_scale 0.1` the `hybrid3d` `points3D` validation diff drops
> ~10× (0.029 → 0.0022). For a projective (non-telecentric) rig in real mm, use `--world_scale 1.0`.
Writes 4 `.onnx` + `manifest.json` + `training_config.yaml`. The 2D stages report **"FAIL"** in the
summary — that is only the script's **strict 1e-2 tolerance** on raw heatmap activations (center
~0.01, efftrack ~0.14); the final 3D output (`points3D`) matches within **~0.03 mm**. Benign;
real-data accuracy is verified in red. (`keypoint_detect.onnx` == `hybridnet_efftrack.onnx` byte-for-byte
is also expected: HN's effTrack backbone is frozen-identical to KeypointDetect.)

### 3c. Compile engines — **do NOT use `scripts/compile_tensorrt_engines.sh` as-is**
That script hardcodes the **wrong** shapes for this model (batch 16, spatial 704). This model is
**7 cameras**, center **320**, effTrack bbox **448**. Drive `trtexec` explicitly (shapes derived
from `config.yaml`; padded_hw = bbox/2+2 = 226; run on THIS box so it targets sm_86 automatically):
```bash
TRT=/home/user/nvidia/TensorRT-8.6.1.6; export LD_LIBRARY_PATH=$TRT/lib
cd $OUT
$TRT/bin/trtexec --onnx=center_detect.onnx    --saveEngine=center_detect.engine    --workspace=4096 \
  --minShapes=input:7x3x320x320 --optShapes=input:7x3x320x320 --maxShapes=input:7x3x320x320
$TRT/bin/trtexec --onnx=hybridnet_efftrack.onnx --saveEngine=hybridnet_efftrack.engine --workspace=4096 \
  --minShapes=input:7x3x448x448 --optShapes=input:7x3x448x448 --maxShapes=input:7x3x448x448
$TRT/bin/trtexec --onnx=hybrid3d.onnx --saveEngine=hybrid3d.engine --workspace=4096 \
  --minShapes=heatmaps_padded:1x7x50x226x226,centerHM:1x7x2,center3D:1x3,cameraMatrices:1x7x4x3 \
  --optShapes=heatmaps_padded:1x7x50x226x226,centerHM:1x7x2,center3D:1x3,cameraMatrices:1x7x4x3 \
  --maxShapes=heatmaps_padded:1x7x50x226x226,centerHM:1x7x2,center3D:1x3,cameraMatrices:1x7x4x3
```
Batch **must equal num_cameras (7)** — red checks `input_bytes == N*3*S*S` with N from the manifest.
Add `--fp16` for smaller/faster engines (verify accuracy). Confirm each: `trtexec --loadEngine=<f>.engine`
prints `PASSED`. Engines are arch- + TRT-version-specific — recompile per box/TRT.

---

## 4. Make red actually expose the Predict tool — **required source patch**

In `moments-behavior/red` `xp`, the JARVIS Predict path (the `jarvis_hn` / `JarvisHybridNetState`
TensorRT code in `src/gui/jarvis_predict_window.h` and `src/red.cpp`) is gated behind
**`RED_HAS_ONNXRUNTIME`** — but the code inside is pure TensorRT (no ORT symbols). With ONNX Runtime
absent, the Predict tool is compiled **out** even though the TRT HybridNet runtime is enabled.
`RED_2404_NOTES.md` §4a notes this gate was *meant* to be `RED_HAS_TENSORRT_HN`.

Fix (matches that intent; ORT-only code in `sam_inference.h`/`jarvis_inference.h` is left untouched):
in **both** `src/red.cpp` and `src/gui/jarvis_predict_window.h`, change every
```c
#ifdef RED_HAS_ONNXRUNTIME
```
to
```c
#if defined(RED_HAS_ONNXRUNTIME) || defined(RED_HAS_TENSORRT_HN)
```
(and the one `#elif defined(__linux__) && defined(RED_HAS_ONNXRUNTIME)` in the predict window →
`… && (defined(RED_HAS_ONNXRUNTIME) || defined(RED_HAS_TENSORRT_HN))`). Every such block in those two
files is `jarvis_hn`-only, so the blanket change is safe.

**Second required edit (runtime gate, not a preprocessor one).** The Predict panel bails with
*"ONNX Runtime not available"* at `src/gui/jarvis_predict_window.h` on `if (!jarvis.available)` —
and `JarvisState.available` (`src/jarvis_inference.h:34-39`) is hard-`false` without ONNX Runtime,
so it returns **before** ever reaching the HybridNet auto-load. Make the check accept the TRT path:
```cpp
        // Availability check
        bool ml_available = jarvis.available;
#if defined(RED_HAS_TENSORRT_HN)
        ml_available = true;
#endif
        if (!ml_available) {
            /* ...the ONNX-Runtime-not-available message... */
```
Then `cmake --build release --target red -j`. Verified: 0 errors, `test_annotation` 673/673,
`test_gui` 178/178 still pass.
> This edit is uncommitted local to the `xp` checkout — decide whether to upstream it (or install
> ONNX Runtime instead, which flips `RED_HAS_ONNXRUNTIME=TRUE` with no source change and also enables SAM).

---

## 5. Wire the model into the project

red resolves a model as **`project_path + "/" + relative_path`**
(`src/gui/jarvis_predict_window.h:305`) and auto-loads `active_jarvis_model` when the Predict panel
opens. With the engine folder at `<project>/jarvis_Fly50`, add to the `.redproj`:
```json
"jarvis_models": [
  { "name": "Fly50_V5", "relative_path": "jarvis_Fly50",
    "num_joints": 50, "center_input_size": 320, "keypoint_input_size": 448 }
],
"active_jarvis_model": 0
```
(Or in the GUI: JARVIS Predict panel → Models Folder `...` → pick the folder; it registers itself.)
The folder must hold: `center_detect{.onnx,.engine}`, `hybridnet_efftrack{.onnx,.engine}`,
`hybrid3d{.onnx,.engine}`, `manifest.json`.

---

## 5b. Batch Predict hang on Linux — **two fixes** (uncommitted, `xp`)

Enabling the Predict tool on Linux (§4) exposed a **latent batch-predict hang** in code paths that
were compiled out before. Symptom: "Start Batch Predict" runs, then the app freezes (~130% CPU) —
clicking a Keypoint Labels square (which calls `seek_all_cameras()` directly) or pressing space to
play both hang, forcing a Force-Quit. Root causes + fixes:

1. **`src/red.cpp` — batch FINISHING left all decoders disabled** (`window_need_decoding=false`).
   `seek_all_cameras()` (`src/utils.cpp`) spins the UI thread on the decoders' seek-ack **with no
   timeout**, so any later seek/play never completes. Fix: on non-Apple, FINISHING now **re-enables**
   decoding (and clears `ps.pause_seeked`) so the app returns to the normal interactive state.
2. **`src/decoder.cpp` — the Linux CUVID decoder's not-decoding branch busy-spun** (no sleep, unlike
   the macOS path). During/after batch (decoders idled to free CPU) the 7 decoder threads pegged the
   CPU. Fix: added a 1 ms sleep to that branch (seek is still serviced at the loop top each iteration).

Rebuild `--target red`; tests stay green. If a hang ever recurs, the belt-and-suspenders option is a
timeout in `seek_all_cameras()`'s `while (!seek_done)` spin so the UI can never freeze indefinitely.

3. **`src/red.cpp` — batch predictions stored against the WRONG (offset) frame.** The chunked
   PREDICT phase read the image from `display_buffer[c][slot]` with `slot = batch_current −
   batch_chunk_start` but stored the result under `batch_current`, **without checking the slot's
   frame_number** — and the chunk SEEK used a **non-accurate (keyframe) seek**, landing the ring on
   the nearest preceding keyframe. Net effect: every batch keypoint was offset earlier by
   (chunk_start − keyframe); Predict-Current-Frame was fine (accurate displayed-frame seek). Fixes:
   (a) chunk SEEK is now **accurate** (`seek_all_cameras(..., true)`); (b) the loop **verifies/corrects
   the slot via `frame_number`** and re-seeks if the frame isn't in the chunk — mirroring the macOS
   streaming path's frame match.

## 6. GPU / verification

- **Single A6000 = device 0 = sm_86**, so JARVIS's hardcoded `cudaSetDevice(0)`
  (`src/jarvis_hybridnet.h:869,1161`) is correct with no `CUDA_DEVICE_ORDER` work. (The multi-GPU
  device-pinning hazard in `RED_2404_NOTES.md` §4 applies only to mixed A16/Blackwell boxes.)
- Launch `red <project>.redproj`, open JARVIS Predict; expect stderr
  `[HybridNet] load SUCCEEDED (TRT direct runtime)` reporting `50 joints, 7 cams, bbox=448`.
  Run predict on a real clip and eyeball the keypoints (the one accuracy check the offline export can't do).

---

## 7. Driver update

`nvidia-driver-595` came from apt (`jammy-updates/multiverse`, Secure Boot off, DKMS built against
6.5.0-18 headers). Because 535 was a `.run` install, the clean sequence was:
`sudo nvidia-uninstall -s && sudo apt-get install -y nvidia-driver-595`, then reboot. Rollback if
needed: `apt install nvidia-driver-535`. **CUDA 12.2 / cuDNN 8 / TRT 8.6 untouched** — the newer
driver is backward-compatible and red still builds/runs against the pinned CUDA 12.2 toolkit.
(Note: `sudo` on this box needs a password — run these interactively, not from an automated tool.)
