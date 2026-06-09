# CLAUDE.md — operating guide for setting up the moments stack on a NEW machine

You (Claude) are helping Rob set up a **fresh Threadripper Pro workstation** to run two
in-house apps — **`orange`** (multi-camera capture/recording) and **`red`** (3D keypoint
labeling). This repo (`moments_setup`) contains the installer scripts and docs. Read this
whole file before doing anything. The stack is **brittle and version-pinned** — your job is
to follow the proven path exactly, not to "improve" or update versions.

> 🆕 **Setting up a Blackwell GPU / Ubuntu 24.04 box?** This file and the `install/`
> scripts target the 22.04 / Ampere / CUDA-12.2 **reference** machine. A Blackwell
> display GPU (sm_120) cannot run the pinned driver 535 / CUDA 12.2, so that build
> needs driver 590 / CUDA 13.1 and a few code/process changes. **Read
> [`BLACKWELL_2404_NOTES.md`](BLACKWELL_2404_NOTES.md) first** — it's the field-tested
> runbook from the June-2026 build (hardware reality, BIOS/boot, versions, the orange
> CUDA-13 changes, GPU ordering, and camera network + PTP setup in `install/network/`).

---

## 0. Prime directives (read first)

1. **Do not change pinned versions.** Driver 535.183.06, CUDA 12.2.2, eSDK 4.07.01, TensorRT
   8.6.1.6, cuDNN 8.9.3.28, etc. are pinned because the stack is fragile. If something is
   missing, get *that exact version*, don't substitute a newer one, unless Rob explicitly says so.
2. **The scripts are the source of truth.** Everything is automated in `install/`. Prefer running
   the numbered scripts over hand-typing commands. Don't reimplement them inline.
3. **Destructive steps need care.** Steps 10 (driver), 30 (DOCA/NIC) modify the kernel/driver and
   the network stack. Confirm with Rob before running them. Never run the installers as `root`
   (they `sudo` internally and write user files to `~`).
4. **Work the steps in order and let reboots happen.** The install is reboot-gated (driver). After
   a reboot, just re-run `./install_phase1.sh` — it resumes via state markers.
5. **When something fails, read the log and the step's own checks** before improvising. Logs are in
   `~/.moments-setup/logs/`. State markers are in `~/.moments-setup/state/`.
6. **Report honestly.** If a step failed or was skipped, say so with the real output. Don't claim
   success you didn't verify.

---

## 1. The machine & the target OS

- **Hardware:** AMD Threadripper PRO 9000-series (Zen 5) on a WRX90-class board, **2× NVIDIA A16**
  (each A16 = 4 GPU dies → 8 dies, compute 8.6) + **1× NVIDIA A4000** (compute 8.6), and **2×
  quad-port NVIDIA ConnectX 25 GbE NICs** (from Emergent) for the cameras.
- **OS:** **Ubuntu 24.04**, on the **GA 6.8 kernel** (the machine ships with 24.04; we keep it).
  ⚠ Do **not** run a newer HWE kernel (6.11) — the pinned driver 535.183.06 won't build against it.
  The kernel gate (`05_kernel_check.sh`) enforces this.
- **Internet:** available during install — so small `apt` packages install automatically; you only
  rely on the USB payload for the big NVIDIA/Emergent/Rivermax pieces.
- This is a brand-new platform. If you hit a hardware-support oddity (NIC/chipset), suspect the
  kernel first.

There is a **reference machine** (the one this repo was authored on) that already runs both apps:
Ubuntu **22.04**, kernel 6.5, driver 535.183.06, CUDA 12.2, eSDK 2.60.01. It's the known-good
oracle. The new box differs in OS (24.04) — see §5 for what that changes.

---

## 2. The two phases

- **Phase 1 (do first):** `orange` (branch `rob_minimal`). Minimal capture build — CUDA/NPP debayer
  → NVENC → FFmpeg mux, GLFW/ImGui preview. **No OpenCV/TensorRT/cuDNN.** Needs: driver, CUDA,
  Emergent eSDK + DOCA/Rivermax, custom FFmpeg.
- **Phase 2 (after orange works):** `red` (branch `xp`). Offline video labeling + JARVIS pose. Needs
  everything orange shares **plus** TensorRT 8.6 + cuDNN 8.9 + ONNX Runtime. **red has NO Emergent
  dependency** (it doesn't talk to cameras).

Get orange fully working before touching red.

---

## 3. The artifact payload (USB)

The big binaries live in a folder called **`moments_artifacts/`** that Rob carries on a USB drive
(it is intentionally **NOT** in this git repo — ~14 GB + a node-locked license). It contains the
NVIDIA driver/CUDA `.run`s, DOCA-OFED debs (22.04 **and** 24.04), Rivermax + license, the Emergent
eSDK installers, prebuilt CUDA FFmpeg, TensorRT/cuDNN, and the orange/red source tarballs. It has
its own `README.md` (manifest + version watch-items) and `CHECKSUMS.sha256`.

**First thing to do:** find where the USB is mounted and point the scripts at it:
```bash
ls /media/$USER/            # or /mnt — find the moments_artifacts folder
export ARTIFACTS_DIR=/media/$USER/<usb>/moments_artifacts
( cd "$ARTIFACTS_DIR" && sha256sum --quiet -c CHECKSUMS.sha256 )   # verify the copy
```
If `ARTIFACTS_DIR` isn't set, `config.env` guesses; always set it explicitly to be safe.

---

## 4. The install sequence (what to actually run)

All commands run from `install/` as the **normal user** (not root). Hardware/BIOS first.

### 4a. Hardware & BIOS (at the keyboard, before/around OS)
Walk Rob through **`install/BIOS_NIC_CHECKLIST.md`**. The non-negotiables:
- BIOS: **Resizable BAR = ON**, **Above 4G Decoding = ON**, **Secure Boot = OFF** (unsigned
  NVIDIA/DOCA modules), UEFI / no CSM.
- NICs seated in CPU-direct slots; GPUs seated + powered.

### 4b. Phase 1 — orange
```bash
cd install
export ARTIFACTS_DIR=/media/$USER/<usb>/moments_artifacts
./00_preflight.sh          # read-only sanity; must pass before continuing
./install_phase1.sh        # runs steps 05 → 50
```
`install_phase1.sh` runs: `05_kernel_check → 10_nvidia_driver → 20_cuda → 30_emergent → 40_ffmpeg
→ 50_orange`. **Step 10 reboots twice** (nouveau blacklist, then after driver install). Each time
it prints "REBOOT REQUIRED"; have Rob `sudo reboot`, then **re-run `./install_phase1.sh`** — it
fast-forwards past completed steps (markers in `~/.moments-setup/state/`).

When it finishes: orange is built at `~/src/orange/release/orange`. Run with `sudo` (needs root
for PTP/NIC access).

### 4c. Phase 2 — red (only after orange works)
```bash
./install_phase2.sh        # runs 60_tensorrt_cudnn → 70_red
```
Builds `~/src/red/release/red`.

### What each step does (so you can debug it)
| Step | Action | Done-when |
|---|---|---|
| `00_preflight` | OS/GPU/payload checks | "pre-flight passed" |
| `05_kernel_check` | kernel ≤ 6.8 + headers available | "within the supported range" |
| `10_nvidia_driver` | headers+tools, blacklist nouveau (reboot), driver 535.183.06 (reboot) | `nvidia-smi` shows 535.183.06 |
| `20_cuda` | CUDA 12.2.2 toolkit (`--toolkit`, no bundled driver) | `nvcc --version` shows 12.2 |
| `30_emergent` | eSDK 4.07 installer drives DOCA + Rivermax + eSDK + eCapture (via `-m` local deb), places license, loads `nvidia_peermem` | `/opt/EVT/eSDK/lib/libEmergentCamera.so` + `/opt/mellanox/rivermax/rivermax.lic` exist |
| `40_ffmpeg` | prebuilt CUDA FFmpeg → `~/nvidia/ffmpeg` | `~/nvidia/ffmpeg/build/bin/ffmpeg -version` works |
| `50_orange` | apt GUI deps (+gcc-12 on 24.04), build orange, stage `~/orange_data` | `~/src/orange/release/orange` exists |
| `60_tensorrt_cudnn` | TensorRT 8.6 → `~/nvidia`; cuDNN 8.9 → `/usr/local/cuda` | `libnvinfer.so` + `/usr/local/cuda/lib64/libcudnn.so.8` |
| `70_red` | apt deps (+gcc-12), build `red` | `~/src/red/release/red` exists |

---

## 5. What's different on 24.04 (and already handled)

The scripts are OS-aware (`config.env` keys off `OS_VERSION`). On **24.04** vs the 22.04 reference:

1. **DOCA / Rivermax versions differ.** 24.04 uses **DOCA 3.3.0** + **Rivermax 1.81.21** (Rivermax
   ships inside the 24.04 eSDK zip); 22.04 uses DOCA 3.0.0 + Rivermax 1.70.32. Both DOCA debs are in
   the payload; `config.env` picks the right one. *Handled.*
2. **CUDA 12.2 nvcc rejects gcc-13** (24.04's default compiler). Steps 50/70 install **gcc-12** and
   pass `-DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-12`. *Handled* — but if you see a build error like
   *"unsupported GNU version! gcc versions later than 12 are not supported"*, this is why; confirm
   gcc-12 is installed and the flag is being passed.
3. **Kernel.** 24.04 GA is 6.8 (good). If the box booted a 6.11 HWE kernel, `05_kernel_check` blocks;
   install the GA kernel (`sudo apt install linux-image-generic linux-headers-generic`) and reboot
   into 6.8.
4. **apt library drift.** 24.04 ships newer Ceres/Eigen/glfw than the reference. Expected to be fine,
   but **orange/red have NOT been build-verified on 24.04** (the dev box was 22.04). If a compile
   error mentions Ceres/Eigen API, that's the most likely culprit — capture the exact error for Rob.

The prebuilt FFmpeg and TensorRT were built on 22.04; they run on 24.04 fine (glibc is forward-
compatible) — don't rebuild them.

---

## 6. The gotchas that will actually bite (with fixes)

- **Secure Boot on** → driver/DOCA kernel modules won't load. Fix: disable Secure Boot in BIOS.
- **nouveau still loaded** → driver install fails. Step 10 blacklists it and reboots; if it persists,
  confirm `lsmod | grep nouveau` is empty after reboot.
- **Resizable BAR didn't take** → `nvidia-smi -q | grep -A3 "BAR1"` shows ~256 MB instead of ~16 GB.
  Fix in BIOS (ReBAR + Above-4G). Camera streaming needs the big BAR.
- **Rivermax license is node-locked to the NIC MACs.** This machine has *new* NICs vs the reference,
  so the staged `rivermax.lic` **may not be valid here**. If Rivermax reports an invalid/missing
  license, Rob must get a license bound to *this* machine's ConnectX serials from Emergent. Check:
  `cat /opt/mellanox/rivermax/rivermax.lic` exists; `dpkg -l | grep -i rivermax`.
- **NIC interface renaming.** The reference renames ports to `mlnxN_pM_25g` via **MAC-based udev
  rules**; the new NICs have different MACs, so ports will appear under default names. Don't assume
  `mlnx*` names exist — check `ip -br link`. Set **MTU 9000** and an IP on the camera subnet for each
  camera-facing port.
- **gcc-13 vs CUDA** — see §5.2.
- **Wrong kernel** — see §5.3.

---

## 7. Verifying success at each milestone

```bash
# GPUs + driver
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv   # 535.183.06, 8.6/8.6
nvidia-smi -q | grep -A3 "BAR1 Memory Usage"                          # Total ~16 GB (ReBAR on)
# CUDA
/usr/local/cuda/bin/nvcc --version | grep release                     # 12.2
# Emergent + Rivermax + NIC
ls /opt/EVT/eSDK/lib/libEmergentCamera.so ; ofed_info -s ; ibstat | head
ls -l /opt/mellanox/rivermax/rivermax.lic ; lsmod | grep nvidia_peermem
/opt/EVT/eCapture/eCapture          # GUI: cameras should enumerate
# FFmpeg
~/nvidia/ffmpeg/build/bin/ffmpeg -version | head -1
# Apps
sudo ~/src/orange/release/orange    # Phase 1 success = live camera preview
~/src/red/release/red               # Phase 2 success = app launches
```

orange's runtime camera presets live in `~/orange_data/config/<preset>/<serial>.json` (keyed by
camera serial). Confirm each camera's serial has a matching config.

---

## 8. Troubleshooting playbook

| Symptom | Likely cause → fix |
|---|---|
| `05_kernel_check` blocks | kernel > 6.8 → boot GA 6.8 (`apt install linux-image-generic`), reboot |
| driver `.run` fails to build module | Secure Boot on; or missing `linux-headers-$(uname -r)`; or kernel too new |
| `nvidia-smi`: "No devices" after install | reboot; check `dmesg | grep -i nvidia`; nouveau not blacklisted |
| BAR1 ≈ 256 MB | ReBAR/Above-4G off in BIOS |
| nvcc "gcc later than 12 not supported" | install gcc-12, ensure `-DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-12` (24.04) |
| `30_emergent` OFED step disrupts network / fails | NIC in chipset slot; or DOCA deb OS mismatch — check `config.env` picked the 2404 deb |
| Rivermax "license invalid/not found" | node-lock mismatch for new NICs → Rob gets a new license from Emergent |
| cameras don't appear in eCapture | host port not on camera subnet, MTU≠9000, link down, or renamed iface |
| orange/red compile error re: Ceres/Eigen/Onnx | 24.04 apt-version drift — capture exact error, report to Rob, check `red/CMakeLists.txt` |
| a step "already done" but you want to redo it | `rm ~/.moments-setup/state/<step>.done` then re-run |

To resume after any reboot or fix: just re-run `./install_phase1.sh` (or `phase2`). Read the latest
log in `~/.moments-setup/logs/` for the full output of the last run.

---

## 9. What is and isn't proven

- **Verified on the reference machine (22.04):** orange builds clean against eSDK 4.07 (0 unresolved
  Emergent symbols); red xp builds against TensorRT 8.6. The scripts pass `bash -n` and the
  read-only preflight runs green.
- **NOT yet verified:** the full destructive install (driver/DOCA), and **any build on 24.04**. The
  new machine is the first real run. Treat build/runtime failures as new information, capture exact
  output, and work with Rob — don't paper over them.

---

## 10. Pointers

- `install/README.md` — how the scripts/flags/state/resume work.
- `install/BIOS_NIC_CHECKLIST.md` — the at-the-keyboard hardware steps (do these first).
- `install/config.env` — pinned versions + artifact paths (single source of truth; OS-aware).
- `moments_artifacts/README.md` (on the USB) — payload manifest + version watch-items.
- The `orange` and `red` repos build from source on this machine; `red/CMakeLists.txt` (Linux
  `else()` branch) is the authoritative red dependency spec (the red README's Linux section is stale).
