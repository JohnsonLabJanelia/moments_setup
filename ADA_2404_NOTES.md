# Field notes — RTX 4000 Ada + Ubuntu 24.04 / CUDA 13 (June 2026)

Setup of the full `orange` + `red` stack on a **second 24.04 box**, this one with an
**RTX 4000 Ada** display GPU (not Blackwell) and a **pre-installed driver 595**. Read this
**first** if your machine is 24.04 with a modern NVIDIA driver already on it — it is the
easiest path we've found and is mostly *headless* (you can validate the whole capture stack
without a monitor or the GUI).

> Companions: [`BLACKWELL_2404_NOTES.md`](BLACKWELL_2404_NOTES.md) (Blackwell GPU / driver 590),
> [`RED_2404_NOTES.md`](RED_2404_NOTES.md) (red on 24.04/CUDA-13), and the pinned reference path
> in [`CLAUDE.md`](CLAUDE.md) (22.04 / driver 535 / CUDA 12.2). Treat `config.env`'s pins as
> reference-machine-only.

The whole thing works: live 7-camera capture, debayer + NVENC on the A16s, FFmpeg mux to HEVC
`.mp4` + per-frame PTP metadata CSV, **GPU-Direct RDMA** (camera → A16 VRAM), 0 dropped frames.

---

## 1. What the machine is

| | This box (`flyrig`) | Blackwell box | Reference (CLAUDE.md) |
|---|---|---|---|
| CPU / board | Threadripper PRO 7965WX, WRX90 (**NPS4 = 4 NUMA nodes**) | 7965WX WRX90 | 7965WX WRX90 |
| OS / kernel | 24.04.4 / **6.17** | 24.04 / 6.17 | 22.04 / 6.5 |
| Display GPU | **RTX 4000 Ada (sm_89)** | RTX PRO 4000 Blackwell (sm_120) | A4000 (sm_86) |
| Compute GPUs | 2× A16 (8 dies, sm_86) | 2× A16 | 2× A16 |
| Driver | **595.71.05** (`nvidia-driver-595-open`, apt) | 590.48.01 | 535.183.06 |
| CUDA toolkit | **13.1** (`cuda-toolkit-13-1`) | 13.1 | 12.2.2 |
| DOCA-OFED / Rivermax | 3.3.0 (OFED 26.01) / 1.81.21 | 3.3.0 / 1.81.21 | 3.0.0 / 1.70.32 |
| eSDK / eCapture | 4.07.01 / 2.14.02 | 4.07.01 / 2.14.02 | 4.07.01 / 2.60.x |
| Camera NICs | 2× ConnectX-7 quad-port | 2× ConnectX-7 quad | ConnectX-6 + 7 |
| Cameras | 7× HB-2800SC | — | — |

**Key takeaway:** an Ada (or any non-Blackwell) GPU on 24.04 does **not** need a driver swap. Keep
whatever modern `nvidia-driver-*-open` is already installed, add the CUDA toolkit, and build the
apps for `sm_86;89`. The only invasive step is the **GPU-Direct peermem rebuild** (§6) — and even
that keeps your driver version.

---

## 2. The stack that works

| Component | Version | Source |
|---|---|---|
| NVIDIA driver | **595.71.05** (`nvidia-driver-595-open`) — *but rebuilt via DKMS*, see §6 | apt |
| CUDA toolkit | **13.1** (`cuda-toolkit-13-1`, toolkit-only) | NVIDIA apt repo |
| FFmpeg | n4.4.5 (prebuilt, CUDA) | USB `40_ffmpeg/` (unchanged) |
| EVT eSDK / eCapture | 4.07.01 / 2.14.02 | USB `30_emergent/` (24.04 zip) |
| DOCA-OFED / Rivermax | 3.3.0 / 1.81.21 | installed by the eSDK installer |

- **CUDA: `cuda-toolkit-13-1` (toolkit-only).** NOT `cuda` / `cuda-drivers` (those clobber the
  working driver). Wire up `/usr/local/cuda` → 13.1, `/etc/profile.d/cuda.sh`, `/etc/ld.so.conf.d/cuda.conf`.
- **Driver 590 is no longer apt-installable on 24.04** — every `nvidia-*-590-*` package is now a
  *transitional stub that pulls 595*. So you cannot "downgrade to match the Blackwell box." Use the
  driver that's there (595) and fix peermem via DKMS (§6).
- **gcc:** CUDA 13's `nvcc` accepts gcc-13 (24.04 default) — the gcc-12 hack from the reference path
  is **not** needed.

---

## 3. BIOS — verify, don't assume

On this box **ReBAR + Above-4G were already on** (it shipped configured). Don't re-flash blindly —
just verify from Linux:
```bash
nvidia-smi -q | grep -A3 "BAR1 Memory Usage"   # Total ~16 GB per A16 (NOT 256 MB) → ReBAR+Above4G on
mokutil --sb-state                              # SecureBoot disabled (needed for DKMS/unsigned)
```
If BAR1 reads ~256 MB, then enable **Above 4G Decoding** + **Re-Size BAR** in BIOS (see
`install/BIOS_NIC_CHECKLIST.md`). 16 GB per A16 here = good.

---

## 4. Install order that worked

Same spine as the other 24.04 box. Steps that were *headless* are marked 🖥️-free.

1. **CUDA 13.1 toolkit** (apt, toolkit-only) — driver untouched. 🖥️-free
2. **FFmpeg n4.4.5** — extract the prebuilt tarball to `~/nvidia/ffmpeg/build/`. **Fix the baked
   path** if your username ≠ the build user (§7). 🖥️-free
3. **red** — build + run the 851 headless tests (no cameras needed). See `RED_2404_NOTES.md`. 🖥️-free
4. **eSDK + DOCA + Rivermax** — `install_eSdk.sh -i Mellanox -m <doca-2404 deb>` (do **not** pass
   `-y`; the installer exits on it). DOCA/OFED DKMS builds fine on 6.17. *Reboot after.* 🖥️-free
5. **orange** — build for `sm_86;89` (§7). 🖥️-free
6. **NIC IPs + PTP** — read-then-match camera IPs, configure ports, start the grandmaster (§8). 🖥️-free
7. **Validate streaming headless** — `evttools` + `multistream` (§9). 🖥️-free
8. **GPU-Direct** — rebuild peermem (DKMS), disable IOMMU, libcudart.so.12 shim (§6). *Reboot.* 🖥️-free
9. **orange record test** — the *only* step that needs the GUI + a monitor.

> Doing red (step 3) early is a great confidence check: it exercises CUDA + the custom FFmpeg +
> the whole build toolchain and passes 851 tests with no cameras and no display.

eSDK install notes:
- `check_system()` only matches the **distro string** (`24.04`) — it is kernel-agnostic, so 6.17 is fine.
- At install time `evt_mellanox_init.service` **fails** (the new mlx5 can't load while `fwctl` is
  held by `cxl_core`, so the NIC is briefly down and its firmware check errors). **This clears on the
  reboot** — don't chase it.

---

## 5. GPU topology, NUMA, and camera→GPU pairing

`nvidia-smi` (PCI-bus order, orange pins `CUDA_DEVICE_ORDER=PCI_BUS_ID`):

| idx | GPU | NUMA | role |
|---|---|---|---|
| 0–3 | A16 dies (bus 05–08) | **node 3** | compute/NVENC |
| **4** | **RTX 4000 Ada** (bus c1) | node 0 | **display only** |
| 5–8 | A16 dies (bus c6–c9) | **node 0** | compute/NVENC |

> ⚠ Unlike the Blackwell box (display GPU at idx 8, A16s 0–7), here the **display GPU sits in the
> middle at idx 4**. Camera `gpu_id` values must skip 4. orange auto-detects the display GPU via
> `cudaGLGetDevices()`, so the *preview* is automatic — but per-camera compute `gpu_id` is still a
> config choice and must avoid the display card.

**One camera → one A16 NVENC die, on the NIC's NUMA-local A16 card.** Each high-speed camera nearly
saturates one NVENC chip, so do **not** stack multiple cameras on one die. Find the pairing with:
```bash
nvidia-smi topo -m                                    # GPU↔NIC affinity (PIX/PHB/SYS)
cat /sys/class/net/<ifname>/device/numa_node          # NIC's NUMA node
nvidia-smi --query-gpu=index,pci.bus_id --format=csv  # GPU bus → NUMA
```
On this box (NPS4, all cross-node distances equal at 12, so PCIe bus proximity is the tie-breaker):
- **enp9** (PCI 09, mlx5_4-6, NUMA 3) → A16 **card 1** dies → `gpu_id` 0,1,2
- **enp225** (PCI e1, mlx5_0-3, NUMA 1) → A16 **card 2** dies → `gpu_id` 5,6,7,8

Set these per camera in the config JSON (one die each, Ada idx 4 unused, gpu3 spare).

---

## 6. GPU-Direct: the peermem gotcha (the hard part)

GPU-Direct needs three things; on this box only the third was the real fight.

### 6a. `nvidia_peermem` is a **stub** on the precompiled driver — rebuild it via DKMS
**Symptom:** `modprobe nvidia_peermem` → `Invalid argument` (EINVAL), **no dmesg**. eCapture/orange
GPU-Direct then hard-aborts at `EVT_CameraOpenStream()`.

**Root cause:** Ubuntu's **precompiled** `linux-modules-nvidia-NNN-open` ships `nvidia-peermem.ko`
built **without** the IB peer-memory API (Canonical's build env has no MOFED headers). It's a no-op
stub — `nm` shows it referencing *none* of `nvidia_p2p_*` / `ib_register_peer_memory_client`. Its
init just returns EINVAL. **This is NOT a driver↔DOCA version mismatch** (a red herring we chased).

**Fix:** switch the driver to its **DKMS** flavour so peermem is *rebuilt on the machine with DOCA
present* (its conftest then finds MOFED's peer-memory symbols). Use the helper:
```bash
sudo install/gpu-direct/fix_nvidia_peermem_dkms.sh    # does the whole dance below
```
What it does (driver 595 shown; substitute your NNN):
```bash
sudo apt-get install -y nvidia-dkms-NNN-open          # builds real peermem (postinst aborts on path conflict — expected)
sudo dkms install --force nvidia/<ver> -k "$(uname -r)"   # land modules in /updates/dkms/
sudo apt-get remove -y linux-modules-nvidia-NNN-open-"$(uname -r)" \
                       linux-modules-nvidia-NNN-open-generic-hwe-24.04   # DKMS = sole provider
sudo depmod -a
```
Verify the rebuilt module is **real** (not a stub):
```bash
KO=$(modinfo -n nvidia_peermem); zstd -dqf "$KO" -o /tmp/pm.ko 2>/dev/null || cp "$KO" /tmp/pm.ko
nm -u /tmp/pm.ko | grep -E "ib_register_peer_memory_client|nvidia_p2p_get_pages"   # both present = good
```
Then **reboot** (loads the consistent DKMS module set), and confirm:
```bash
lsmod | grep nvidia_peermem    # loaded AND bound: "ib_uverbs ... N nvidia_peermem,..." = registered with DOCA
```
> ❌ Do **not** use the EVT-bundled `nvidia-peer-memory(-dkms)_1.1` (`nv_peer_mem`). It is years old
> and its `nvidia_p2p_*` symbol CRCs disagree with any recent driver → it builds but won't load.

### 6b. IOMMU off — *add* the param if the cmdline has none
`disable_iommu.sh` only edits an existing `amd-iommu=on iommu=pt`. If `/proc/cmdline` has **no** iommu
param (ours was just `quiet splash`), you must **add** it:
```bash
sudo sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 amd_iommu=off"/' /etc/default/grub
sudo update-grub      # then reboot; verify: ls /sys/kernel/iommu_groups | wc -l  → 0
```

### 6c. `libcudart.so.12` shim (CUDA 13 only)
The eSDK GPU-Direct libs hard-link `libcudart.so.12`. On CUDA 13 install it alongside:
```bash
sudo install/gpu-direct/install_cuda12_cudart.sh     # installs cuda-cudart-12-x, symlinks .so.12
```
Enable the peermem service for boot: `sudo update-rc.d start-nvidia-peermem defaults`.

---

## 7. orange / red build specifics

- **Arch:** build both with `-DCMAKE_CUDA_ARCHITECTURES="86;89"` (86 = A16, 89 = RTX 4000 Ada).
- **Prebuilt FFmpeg `.pc` paths are baked to the build machine's `$HOME`.** Ours said
  `/home/user/...`; our user is `rob`. orange reads `$HOME` directly (fine), but **red's pkg-config**
  uses the baked prefix and fails. Fix once after extracting:
  ```bash
  sed -i "s#/home/user/nvidia/ffmpeg/build#$HOME/nvidia/ffmpeg/build#g" \
      "$HOME/nvidia/ffmpeg/build/lib/pkgconfig/"*.pc
  ```
  (The `.so` files have **no** baked RPATH, so only the `.pc` files need this.)
- **orange links both FFmpeg ABIs** — its own n4.4.5 (`libav*.so.58/56`, `libswresample.so.3`) **and**
  the system `so.60/58/4` pulled transitively by the eSDK. Different sonames → they coexist; the ld
  "may conflict" warning is cosmetic.
- **red prerequisites:** `git submodule update --init lib/implot3d` (not in a fresh clone), and build
  GoogleTest **with gmock** to `/usr/local` (Ceres/absl needs `GTest::gmock`). Full steps in
  `RED_2404_NOTES.md`.

---

## 8. Camera network — *read-then-match* (easier than ForceIP)

The cameras keep their **existing persistent IPs** (here `192.168.1X0.23`). Rather than push new IPs
onto them, **read each camera's IP and set the host NIC port to the same /24** (host `.20`, camera
`.23`). This is faster and fully headless.

```bash
# 1. Discover every camera, its IP, serial, and which host port it's on (broadcast works across
#    a subnet mismatch, so you can discover BEFORE matching the host IPs):
sudo LD_LIBRARY_PATH=/opt/EVT/eSDK/lib /opt/EVT/eSDK/tools/evttools -d -o b
#    -> "Camera 00: 192.168.110.23 (sn 2012861 ...) on: 192.168.40.20"  (the host IP = that port)

# 2. Set each NIC port to its camera's subnet, host .20 (edit install/network/configure_camera_ports.sh
#    MAP to the discovered subnets, then run it). Re-activate live ports so new IPs apply:
sudo ./configure_camera_ports.sh
for c in cam0 cam1 cam2 cam4 cam5 cam6 cam7; do sudo nmcli connection up "$c"; done

# 3. Confirm: every camera pingable + discovered on its matching host subnet:
for n in 110 120 130 140 150 160 170; do ping -c1 -W1 192.168.$n.23 >/dev/null && echo "$n ok"; done
```
Interface names are PCI-derived — always re-map `configure_camera_ports.sh` (MAP) **and**
`ptp_start.sh` (`-i` list) to `list_camera_nics.sh` output. See `install/network/README.md`.

---

## 9. Validate the WHOLE capture stack headless (no GUI, no monitor)

This is the biggest time-saver: you can prove NIC → DOCA → Rivermax → eSDK → cameras → GPU-Direct
**before** ever opening orange.

```bash
cd /opt/EVT/eSDK/tools; export LD_LIBRARY_PATH=/opt/EVT/eSDK/lib

sudo -E ./evttools -d -o b                  # discovery + IPs (see §8)
sudo -E ./multistream -n ^ -c 7             # stream all 7 cams (host-staged). Watch: f:N/N d:0 m:0
sudo -E ./multistream -n ^ -c 7 -g 0        # SAME but GPU-Direct into GPU0. If peermem/IOMMU are
                                            #   wrong this hard-aborts at open; success = GPU-Direct OK
```
`-n ^` puts every camera in one group regardless of IP (quick test). `f:21/21 d:0 m:0` per camera =
21 received / 21 expected, 0 dropped, 0 missed. red's headless tests (`DISPLAY= ./release/test_*`)
similarly validate the labeling side without a display.

---

## 10. orange app behavior (as of June 2026, pushed to `rob_minimal`)

- **PTP Stream Sync is always on.** The checkbox was removed; `ptp_stream_sync` defaults true and
  stays on across record cycles (the `orange` launcher always runs a grandmaster, and recording
  already forced it). Preview now uses the same gated multi-camera acquisition as recording.
- **"Start PTP Logging" no longer crashes.** It used to spawn a worker that did its **own** GVCP on
  cameras the capture threads were already polling → concurrent GVCP on one camera's control channel
  collides (`GVCP ACK error 0300`) and segfaults the SDK. Now the capture threads publish each
  frame's `PtpOffset` to a lock-free cache and the worker just reads it (no GVCP), throttled to ~10 Hz.
  It writes `~/orange_data/logs/ptp_offsets_<ts>.csv` (column per camera serial; values = camera PTP
  offset from the grandmaster in ns, ~0 when locked) — a sync-quality diagnostic.
- **General lesson:** the EVT SDK's per-camera GVCP control channel is **not thread-safe**. Never
  read/write camera parameters from a second thread while the capture thread is running — cache and
  share instead.

---

## 11. Gotchas, one-line each

- Driver 590 is gone from 24.04 apt (transitional → 595). Don't try to downgrade; rebuild peermem.
- Precompiled `nvidia-peermem.ko` is a stub → DKMS-rebuild the driver *after* DOCA (§6a).
- EVT `nv_peer_mem` 1.1 is too old for modern drivers — don't use it.
- `disable_iommu.sh` only edits an existing iommu param; **add** `amd_iommu=off` if there is none (§6b).
- Display GPU can sit mid-stack (idx 4 here) — camera `gpu_id` must skip it.
- One camera per A16 NVENC die, on the NIC's NUMA-local card (§5).
- Prebuilt FFmpeg `.pc` files bake the build user's `$HOME` — sed-fix for red's pkg-config (§7).
- eSDK installer: no `-y`; `evt_mellanox_init.service` failing at install is expected (clears on reboot).
- `red` needs `lib/implot3d` submodule + GoogleTest **with gmock** at `/usr/local`.
- Validate everything headless with `evttools` + `multistream -g` before touching the GUI (§9).
