# Field notes — Blackwell + Ubuntu 24.04 build (June 2026)

The first real build of the `orange` stack on **next-generation hardware** (NVIDIA
Blackwell GPU, Ubuntu 24.04, CUDA 13). This box differs substantially from the
22.04 / Ampere / CUDA-12.2 **reference machine** that `CLAUDE.md` and the `install/`
scripts were written for. **Read this first** if you're setting up a machine like
this; treat `CLAUDE.md`'s pinned versions (§0) as reference-machine-only.

The whole thing works: live capture, debayer + NVENC on the A16s, FFmpeg mux to
HEVC `.mp4` with a per-frame PTP metadata CSV, previewing on the Blackwell.

---

## 1. What the machine actually is (vs CLAUDE.md's assumptions)

| | CLAUDE.md assumed | This machine (reality) |
|---|---|---|
| Display GPU | A4000 (Ampere, sm_86) | **RTX PRO 4000 Blackwell (sm_120)** |
| Compute GPUs | 2× A16 (8 dies, sm_86) | 2× A16 (8 dies, sm_86) ✓ |
| Total CUDA devices | — | **9** (8 A16 dies + 1 Blackwell) |
| Camera NICs | ConnectX (unspecified) | **2× ConnectX-7 quad-port** (`mlx5_core`) |
| Other NIC | — | Intel i40e (`enp209`) — **not** camera-capable |
| OS / kernel | 24.04 / GA 6.8 | 24.04 / **6.17** (newer; DOCA built fine) |
| Driver | 535.183.06 | **590.48.01** |
| CUDA | 12.2.2 | **13.1** |

**Why the pins changed:** Blackwell is compute capability **12.0 (sm_120)**. The pinned
driver 535 / CUDA 12.2 physically cannot drive it — Blackwell needs driver ≥ ~570 and
CUDA ≥ 12.8. The single NVIDIA kernel driver serves *all* GPUs, so the whole stack had
to move up to driver 590 / CUDA 13. This was an authorized, necessary deviation from
Prime Directive #1.

---

## 2. The stack that actually works

Prefer current online packages over the pinned USB artifacts on this hardware:

| Component | Version | Source |
|---|---|---|
| NVIDIA driver | 590.48.01 (`nvidia-driver-open`) | apt |
| CUDA toolkit | **13.1** (`cuda-toolkit-13-1`, toolkit-only) | NVIDIA apt repo |
| FFmpeg | **n4.4.5** (prebuilt, CUDA) | USB `40_ffmpeg/` (unchanged — see below) |
| EVT eSDK / eCapture | 4.07.01 / 2.14.02 | USB (current 24.04 zip) |
| DOCA-OFED / Rivermax | 3.3.0 / 1.81.21 | bundled with the 24.04 eSDK |

- **CUDA: install `cuda-toolkit-13-1` (toolkit-only).** NOT `cuda` / `cuda-13-1` /
  `cuda-drivers` — those pull a driver and would clobber the working 590. Match the
  toolkit to the driver's max runtime: `nvidia-smi` showed `CUDA Version: 13.1`.
- **FFmpeg stays n4.4.5.** orange's `FFmpegWriter.cpp` uses the pre-FFmpeg-5.0
  non-`const` `AVOutputFormat` API; a newer FFmpeg would force source patches. n4.4.5
  runs fine on 24.04 (glibc forward-compatible). Don't rebuild it.
- **gcc:** CUDA 13's `nvcc` supports gcc-13 (24.04's default), so the gcc-12 hack the
  reference path needs (CUDA 12.2 rejects gcc-13) is **not** required here.

---

## 3. BIOS & boot (do this first — it was the hardest part)

Board: ASUS Pro WS WRX90E-SAGE SE (AMI BIOS). Symptoms hit before any software: POST
hangs at Q-codes **92 / 64 / 98** (all PCIe enumeration / resource assignment), worse
with the display GPU in slot 2.

- **Pull seated-but-unpowered PCIe cards.** A card with no aux power (e.g. A16s
  waiting on cables) is a half-alive endpoint that wedges PCIe enumeration. Remove
  them (or power them) — biggest single fix. Also unplug spare USB sticks; an odd
  bootable USB stalls console/USB init (Q-code 98).
- **Can't catch the "press DEL" prompt?** From Linux: `systemctl reboot --firmware-setup`
  — boots straight into UEFI setup, no key-timing.
- **BIOS settings:** `Above 4G Decoding = ON`, `Re-Size BAR = ON` (verify with
  `nvidia-smi -q | grep -A3 BAR1` → ~16–32 GB, not 256 MB), `Secure Boot = OFF`,
  `CSM = OFF`, and **Boot → "Wait For F1 If Error" = Disabled** (kills the
  PCIe-not-powered prompt). Consider a BIOS update via USB FlashBack on a fresh board.
- **Adding any PCIe card renumbers the bus.** Adding the 2nd NIC and powering the A16s
  each shifted device enumeration. After *any* hardware change, re-check
  `ip -br link` / `install/network/list_camera_nics.sh` and `nvidia-smi`.

---

## 4. Install order that worked

Same spine as `CLAUDE.md` §4, with the versions from §2:

1. **Driver 590** (apt) — reboot, `nvidia-smi` shows 590.48.01.
2. **CUDA 13.1 toolkit** (apt, toolkit-only) — `/usr/local/cuda` → 13.1, driver untouched.
3. **EVT eSDK + DOCA + Rivermax + eCapture** — `install_eSdk.sh -i Mellanox -m <doca-2404 deb>`
   (do **not** pass `-y`; this installer version exits on it). DOCA 3.3 / OFED DKMS
   built cleanly on kernel 6.17 (the feared kernel-too-new risk did not materialize).
4. **FFmpeg n4.4.5** — extract the prebuilt tarball to `~/nvidia/ffmpeg/build/` (no rebuild).
5. **Build orange** — `cmake -S . -B release -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc
   -DCMAKE_CUDA_ARCHITECTURES="86;120"` then `cmake --build release -j$(nproc)`.

**Validate cameras with eCapture FIRST** (before orange): cable one camera, set its IP
(see §6), run `sudo -E /opt/EVT/eCapture/eCapture`. **eCapture must run as root** for
Mellanox/ConnectX NICs (sudo is only optional for Emergent-branded NICs). The Rivermax
license is universal (works for any Emergent NIC) — not node-locked.

---

## 5. orange source changes for CUDA 13 (committed, cross-version)

Committed to the `orange` repo's `rob_minimal` branch, guarded so the **CUDA-12.2
reference box still builds** (the changes key on CUDA *version*, not OS/driver):

- **NVTX:** CUDA 13 removed `libnvToolsExt.so`. Include header-only
  `<nvtx3/nvToolsExt.h>` and drop the `nvToolsExt` link (header-only on 12.x and 13).
- **NPP:** the context-less calls were removed in 13; use the `_Ctx` variants (present
  since CUDA 10.1) with an `NppStreamContext` built once per worker.
- **`cuCtxCreate`:** guarded `#if CUDA_VERSION >= 13000` (`_v4`, 4-arg) vs `_v2` (3-arg).
- **Link:** `-Wl,--disable-new-dtags` (DT_RPATH) so the bundled FFmpeg's transitive
  `libswresample` resolves at runtime.
- **Display GPU:** auto-detected via `cudaGLGetDevices()` + `CUDA_DEVICE_ORDER=PCI_BUS_ID`
  instead of hardcoding device 0 (see §6).
- **Data dir:** reads presets/recordings from `~/orange_data` (was `~/orange_data_dev`).

The CMake default archs are still `75 80` (sm_120 is a build-time `-D`), so the source
isn't Blackwell-locked.

---

## 6. GPU topology, ordering, and per-camera mapping

`nvidia-smi` (PCI-bus order): **0–7 = the 8 A16 dies** (sm_86), **8 = Blackwell** (sm_120).

- **Display** (GL window + interop) must be on the **Blackwell** — it's the only card
  with a monitor output; the A16s are headless. orange auto-detects this with
  `cudaGLGetDevices()`, so no env juggling.
- **Compute** (debayer + NVENC) runs on the **A16 dies**. Each A16 die has one NVENC
  chip → 8 dies = 8 simultaneous camera encodes.
- orange pins `CUDA_DEVICE_ORDER=PCI_BUS_ID`, so config `gpu_id` values match
  `nvidia-smi`: **camera N → `gpu_id` 0…7** (the A16 dies); display = Blackwell (auto).
- Launch: **`sudo -E ~/src/orange/release/orange`** (root for NIC/PTP; `-E` so the root
  process can open your X display, same as eCapture).
- Presets: `~/orange_data/config/local/<preset>/<serial>.json`, keyed by camera serial.

---

## 7. Camera network + PTP

See **`install/network/`** (scripts + README). In short:

- One camera per ConnectX port, each on its own `/24` (host `.20`, camera `.21`),
  **MTU 9000**. Configure with `list_camera_nics.sh` → `configure_camera_ports.sh`.
- **PTP is mandatory before recording.** orange reads `PtpOffset` every frame; without
  a running grandmaster the EVT read throws and hangs orange on stop (see §8). Run
  `ptp_start.sh` + `sync_NICs.sh` first. Confirm camera `PtpStatus = Slave`.

---

## 8. Known issues / TODO (as of June 2026)

- **Record-stop hangs without PTP** — `EVT_CameraGetInt32Param("PtpOffset")` throws
  when no grandmaster is running and the unwind wedges the camera-acquire thread, so
  `stop_camera_streaming()`'s join() never returns. **Workaround:** run PTP first.
  **Fix (TODO):** guard/only-read `PtpOffset` when sync is active, so single-camera
  recording works without PTP and survives a PTP dropout.
- **Camera control sliders** (gain / focus / iris) don't write to the camera, and
  manual lens focus is blocked — the slider→`EVT_CameraSetParam` wiring (camera.cpp /
  gui.cpp) needs fixing.
- **GPU Direct (RDMA NIC→GPU) untested here.** Requires `sudo modprobe nvidia_peermem`,
  then set `"gpu_direct": true` in the camera config. NIC↔Blackwell P2P on this WRX90
  topology is unproven; first light ran with `gpu_direct: false`.
- **Verify the CUDA-12.2 reference build** of the new orange commits (only built on
  CUDA 13 so far).
- Camera reports a **9344×7000** sensor; a configured `width` < 9344 is a horizontal
  crop (OffsetX). Set `width: 9344` for the full sensor.

---

## 9. Verification milestones

```bash
nvidia-smi --query-gpu=index,name,driver_version,compute_cap --format=csv  # 9 GPUs, 590
nvidia-smi -q | grep -A3 "BAR1 Memory Usage"                               # large BAR (ReBAR on)
/usr/local/cuda/bin/nvcc --version | grep release                          # 13.1
ls /opt/EVT/eSDK/lib/libEmergentCamera.so ; cat /opt/mellanox/rivermax/rivermax.lic
~/nvidia/ffmpeg/build/bin/ffmpeg -version | head -1                        # n4.4.5
sudo -E /opt/EVT/eCapture/eCapture        # cameras enumerate + stream
sudo -E ~/src/orange/release/orange       # preview, then (PTP running) record → real .mp4 + CSV
```
