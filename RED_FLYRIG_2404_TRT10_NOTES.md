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

## 8. Adding another JARVIS model from `.pth` (export → compile → wire)

§2–6 assume you already have the ONNX (Fly50 came pre-exported). When you only have training
output (`config.yaml` + `models/{CenterDetect,KeypointDetect,HybridNet}/Run_*/…_final.pth`) you
must first **export ONNX** (needs GPU torch — `trtexec` can't read `.pth`). Worked example:
`fly44_l_V4` (44-kp "5-leg" model, `/mnt/johnsonlab/Elliott_Abe/fly44_l_V4/models`).

### 8a. One-time: build the export env on flyrig

No conda ships on flyrig. Install miniconda user-space (no sudo), then create the env. **The new
conda gates the anaconda `defaults` channels behind a ToS accept — use `--override-channels -c
conda-forge` to avoid it entirely.** `torch` cu121 wheels run on driver 595 (backward compat).
Pin all GPU work to the Ada (§1).

```bash
curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/mc.sh
bash /tmp/mc.sh -b -p $HOME/miniconda3
CONDA=$HOME/miniconda3/bin/conda; ENV=$HOME/miniconda3/envs/red_trt_export
$CONDA create -n red_trt_export --override-channels -c conda-forge python=3.10 libstdcxx-ng -y
$ENV/bin/pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
$ENV/bin/pip install onnx onnxruntime-gpu yacs numpy scipy opencv-python-headless matplotlib
# jarvis package (imported via PYTHONPATH, not installed):
#   /mnt/johnsonlab/clusterfly/JARVIS-HybridNet   (has jarvis/efficienttrack/model.py)
# verify: PYTHONPATH=$JARVIS $ENV/bin/python -c "import torch,onnx,yacs,cv2; \
#   from jarvis.efficienttrack.model import EfficientTrackBackbone; print(torch.cuda.is_available())"
```

### 8b. Export ONNX — `--world_scale 0.1` for the telecentric fly

```bash
ENV=$HOME/miniconda3/envs/red_trt_export; JARVIS=/mnt/johnsonlab/clusterfly/JARVIS-HybridNet
M=<model>/models; OUT=<project>/jarvis_<name>
ADA=$(nvidia-smi --query-gpu=index,name --format=csv,noheader | awk -F', ' '/RTX 4000 Ada/{print $1; exit}')
PYTHONPATH=$JARVIS LD_LIBRARY_PATH=$ENV/lib CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$ADA \
$ENV/bin/python ~/src/red/scripts/export_jarvis_onnx.py \
  --config <model>/config.yaml \
  --center-pth $M/CenterDetect/Run_*/EfficientTrack-medium_final.pth \
  --keypoint-pth $M/KeypointDetect/Run_*/EfficientTrack-medium_final.pth \
  --hybridnet-pth $M/HybridNet/Run_*/HybridNet-medium_final.pth \
  --output-dir $OUT --jarvis-src $JARVIS --world_scale 0.1
```
The script reads `NUM_JOINTS`/`NUM_CAMERAS`/`ROI`/`GRID` from the config and writes 4 `.onnx` +
`manifest.json` + `training_config.yaml`. The 2D stages print **"FAIL"** (benign — strict 1e-2
tolerance on raw heatmaps); what matters is `hybrid3d`'s `points3D` diff (~0.005 mm with
`--world_scale 0.1`; ~10× larger without it). fly44 → 44 joints, roi 52→5.2 mm, grid 1→0.1 mm.

### 8c. Compile — manifest-driven (works for any joint/camera count)

`scripts/compile_tensorrt_engines.sh` hardcodes wrong shapes; use this instead. It reads
joints/cameras/sizes from `manifest.json`, so the same script serves fly44 (44), Fly50 (50), etc.
Drop it in the model folder as `compile_engines_trt10.sh` and run it:

```bash
#!/usr/bin/env bash
set -euo pipefail; cd "$(dirname "$0")"
read J N CS BB < <(python3 -c 'import json;m=json.load(open("manifest.json"))["training_config_summary"];print(m["num_joints"],m["num_cameras"],m["center_image_size"],m["keypoint_bbox_size"])')
PAD=$(( BB/2 + 2 ))                                   # hybrid3d padded_hw
ADA=$(nvidia-smi --query-gpu=index,name --format=csv,noheader | awk -F', ' '/RTX 4000 Ada/{print $1; exit}')
export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$ADA   # keep off the A16 capture dies
T=$(command -v trtexec); WS="--memPoolSize=workspace:4096"      # TRT-10: not --workspace
"$T" --onnx=center_detect.onnx --saveEngine=center_detect.engine $WS \
  --minShapes=input:${N}x3x${CS}x${CS} --optShapes=input:${N}x3x${CS}x${CS} --maxShapes=input:${N}x3x${CS}x${CS}
"$T" --onnx=hybridnet_efftrack.onnx --saveEngine=hybridnet_efftrack.engine $WS \
  --minShapes=input:${N}x3x${BB}x${BB} --optShapes=input:${N}x3x${BB}x${BB} --maxShapes=input:${N}x3x${BB}x${BB}
SH="heatmaps_padded:1x${N}x${J}x${PAD}x${PAD},centerHM:1x${N}x2,center3D:1x3,cameraMatrices:1x${N}x4x3"
"$T" --onnx=hybrid3d.onnx --saveEngine=hybrid3d.engine $WS --minShapes=$SH --optShapes=$SH --maxShapes=$SH
for e in center_detect hybridnet_efftrack hybrid3d; do "$T" --loadEngine=$e.engine 2>&1 | grep -oE 'PASSED|FAILED'; done
```
TRT 10 builds `hybrid3d` with **no `InstanceNormalization_TRT` plugin** (export decomposes it).

### 8d. Wire it in — **skeleton coupling decides one project vs a new one**

red writes predictions **positionally** (model joint `j` → project-skeleton slot `j`) and the
skeleton is fixed **per project**. So:

- **Same skeleton as an existing project** (e.g. another training run of the same 50-kp layout) →
  just add a second entry to that project's `jarvis_models[]` and it appears in the Predict
  dropdown. `active_jarvis_model` picks the default.
- **Different skeleton** (fly44's 44-kp order diverges from Fly50 at index 10) → a shared dropdown
  would **misalign** joints. Make a **separate project** with a matching skeleton. red has only a
  `Fly50` preset, so generate the skeleton JSON from the model manifest and load it via
  `load_skeleton_from_json`:
  ```bash
  python3 - <<'PY'
  import json
  m=json.load(open("<model>/manifest.json"))["training_config_summary"]
  names=m["keypoint_names"]; idx={n:i for i,n in enumerate(names)}
  sk={"name":"Fly44","num_nodes":len(names),"num_edges":len(m["skeleton"]),
      "edges":[[idx[a],idx[b]] for a,b in m["skeleton"]],"node_names":names}
  json.dump(sk, open("<project>/fly44_skeleton.json","w"), indent=2)
  PY
  ```
  Then in the `.redproj`: `"load_skeleton_from_json": true`, `"skeleton_file": ".../fly44_skeleton.json"`,
  and `jarvis_models[]` → the `jarvis_<name>` folder with `num_joints` set (44). "Choose the model"
  = open the project whose skeleton matches it. Videos can be referenced in place (absolute
  `media_folder`); a local-NVMe path like `/mnt/localflydrive3/...` needs no copy.

### 8e. Launcher (per project, Ada-pinned)

```bash
#!/usr/bin/env bash
set -euo pipefail
ADA=$(nvidia-smi --query-gpu=index,name --format=csv,noheader | awk -F', ' '/RTX 4000 Ada/{print $1; exit}')
export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="${ADA:?no RTX 4000 Ada}"
exec red <project>/<project>.redproj
```
Working flyrig examples: `/home/rob/red_data/fly_posts39a_0708/` (Fly50_V5, 50-kp) and
`/home/rob/red_data/5legtest/` (fly44_l_V4, 44-kp, generated Fly44 skeleton, videos referenced
in place). Both verified: `[HybridNet] load SUCCEEDED` with the right joint count.
