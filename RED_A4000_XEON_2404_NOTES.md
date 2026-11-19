# Field notes — red-only viewing/proofreading box: dual Xeon + RTX A4000 / 24.04 / kernel 7.0 (Nov 2026)

Setup of **`red` only** (no `orange`, no cameras) on a **Supermicro X12DAi-N6** dual-Xeon
workstation with a single **RTX A4000**. Its job: view multi-camera recordings (4 cameras
for now) and load **tailcycle predictions** to view and proofread them. No JARVIS/TensorRT
inference (tailcycle isn't wired for TRT yet), so red's ML paths are compiled out.

This is the first **red-only** build and the first on an **Intel Xeon server board**. It
reuses the fully-online recipe from [`INCUBATOR_2404_NOTES.md`](INCUBATOR_2404_NOTES.md)
(same kernel 7.0 + driver 595-open) and the red build from
[`RED_2404_NOTES.md`](RED_2404_NOTES.md) §3. The scripts are committed in
[`install/red-only/`](install/red-only/). Setup was driven by Claude Opus 5.5 (Claude Code)
from this repo's notes.

**Status (2026-11-19):** red `xp` `9654b3e` builds; `test_annotation` **718/718** and
`test_gui` **178/178** pass; ldd/RPATH clean; launcher + pinned dock icon installed.
GUI playback of a real recording is the next user check. **Open item:** the A4000 links at
**PCIe x4** because of BIOS bifurcation (§5) — diagnosed, not yet changed.

---

## 1. The machine

| | This box | Closest precedent: `incubator` |
|---|---|---|
| Board / CPU / RAM | Supermicro **X12DAi-N6** (BIOS 1.2b), **2× Xeon Gold 6348** (Ice Lake-SP, 112 threads), 503 GB | desktop, i7-8700K |
| OS / kernel | 24.04.5 / **7.0.0-43-generic** (HWE) | 24.04.4 / 7.0.0-28 |
| GPU | **1× RTX A4000** (GA104, **sm_86**, 16 GB) — display + decode. Onboard ASPEED = BMC only | RTX PRO 6000 Blackwell |
| Driver | **595.99.02 open** (`nvidia-driver-595-open`, precompiled signed `linux-modules-nvidia-595-open-*`, no DKMS) — kept | 595.71.05 open |
| CUDA | **13.1** (`cuda-toolkit-13-1`, apt, toolkit only) | 13.1 |
| FFmpeg | **n4.4.5 from source** → `~/nvidia/ffmpeg/build` | same |
| Display | X11 (GNOME on Xorg) on the A4000 | — |
| Secure Boot / BAR1 | off / **256 MB** (ReBAR off — irrelevant for red, matters only for orange GPU-Direct) | off / 128 GB |
| Storage | system disk on onboard NVMe (stack `0000:64`); 4-drive NVMe carrier card in CPU1 SLOT5 | — |

### Is the driver/kernel OK for red? Yes — don't touch either

- **595-open** is the line all the 24.04 boxes run. It provides `libnvcuvid.so` (NVDEC,
  red's decode path) and `libcuda`. The kernel modules are the **precompiled Ubuntu**
  ones tracked by `linux-modules-nvidia-595-open-generic-hwe-24.04`, so new kernels get
  matching modules with no DKMS step.
- **Kernel 7.0** is fine *for red*: red has no kernel-module dependency. The 7.0 problems in
  [`ADA_2404_NOTES.md`](ADA_2404_NOTES.md) §2 are OFED/DOCA DKMS (orange's camera NICs),
  which a red-only box doesn't have.

## 2. What red needs (and doesn't) on a red-only box

Authoritative spec: the Linux `else()` branch of red `xp` `CMakeLists.txt` (the red README's
Linux section is for `main`, and lists Arrow, which `xp` doesn't use).

**Needs:** CUDA toolkit (nvcc, cudart, NPP libs, driver API), FFmpeg (pkg-config; prefers
`~/nvidia/ffmpeg/build/lib/pkgconfig`), Eigen 3.4, Ceres 2.2, OpenBLAS (CBLAS), GLFW 3.3,
GLEW, OpenGL, GoogleTest **with gmock in `/usr/local`** (found *before* Ceres; apt alone
isn't enough), `patchelf`, and the `xp` submodules (`implot3d`, `imgui-filebrowser`, …).

**Doesn't need:** Emergent eSDK, DOCA/OFED, Rivermax, the USB payload, gcc-12 (CUDA 13
accepts gcc-13), TensorRT / ONNX Runtime / cuDNN / MuJoCo (auto-detected; absent → ML
compiled out, viewing + tailcycle prediction loading unaffected), Arrow.

`xp` already contains the `trt10-cuda13` work (merged), so adding TRT 10 later is just
[`RED_FLYRIG_2404_TRT10_NOTES.md`](RED_FLYRIG_2404_TRT10_NOTES.md) §2–4 with sm_86 engines.

## 3. Install order that worked

Every apt step was **dry-run first** (`apt-get -s`, no sudo). The CUDA repo was dry-run
*before being added* by building a sandboxed apt state in a scratch dir
(`-o Dir::Etc::SourceParts=… -o Dir::State::Lists=… -o Dir::Etc::PreferencesParts=…
-o Debug::NoLocking=1`) holding the system sources plus the unpacked `cuda-keyring` deb —
a useful trick for previewing a new repo with zero system change.

```bash
cd ~/src/red && git checkout xp && git submodule update --init --recursive
cd ~/src/moments_setup/install/red-only
./10_apt_deps.sh     # 74 new + 8 Mesa point upgrades, 0 removed, nothing NVIDIA/kernel
./20_cuda.sh         # counter-pin → cuda-keyring → cuda-toolkit-13-1 (70 pkgs + a JRE for Nsight)
./30_gtest.sh        # gtest + gmock → /usr/local
./40_ffmpeg.sh       # n4.4.5, ~2 min on 112 threads
./50_build_red.sh    # CUDA_ARCH=86 default; builds, checks, tests, ./install.sh
../desktop/install_launchers.sh --red-only --pin
```

Build output to expect: `Using custom FFmpeg from …/nvidia/ffmpeg/build/lib/pkgconfig`,
`Using CBLAS provider: …/libopenblas.so`, `CUDA compiler … NVIDIA 13.1.115`, and
"TensorRT / ONNX Runtime / MuJoCo not found" (expected). Only warnings:
`av_init_packet` deprecated (harmless on n4.4.5) and one `-Wformat-truncation`.

Verify:
```bash
readelf -d ~/src/red/release/red | grep RPATH    # cuda-13.1 lib + ~/nvidia/ffmpeg/build/lib
ldd ~/.local/opt/red/bin/red | grep 'not found'  # nothing
command -v red                                   # ~/.local/bin/red  (NOT /usr/bin/red = ed)
```

## 4. ⚠ The CUDA repo's pin will swap driver packages — counter-pin it

This applies to **any** box whose driver came from Ubuntu / the graphics-drivers PPA and
that then adds NVIDIA's CUDA apt repo (incubator, Ada boxes, …).

`cuda-keyring` installs `cuda-repository-pin-600` (`Package: *`, `Pin: release l=NVIDIA
CUDA`, priority 600), ranking the whole CUDA repo above Ubuntu. Installing
`cuda-toolkit-13-1` itself is clean, but the simulated **`apt upgrade` afterwards would
replace** `nvidia-settings` (510 → 620.70), `libxnvctrl0` and `libnvidia-egl-wayland1` with
CUDA-repo builds from a newer driver branch. `nvidia-driver-595-open` itself had no
CUDA-repo candidate, so the driver wouldn't swap today — but the pin makes that a matter of
what NVIDIA publishes next.

Fix (written by `20_cuda.sh` *before* the keyring):
```
# /etc/apt/preferences.d/99-keep-ubuntu-nvidia-driver
Package: nvidia-* libnvidia-* libxnvctrl* xserver-xorg-video-nvidia* cuda-drivers* libcuda1* libnvcuvid* libnvidia-encode* firmware-nvidia*
Pin: release l=NVIDIA CUDA
Pin-Priority: -1
```
Note: priority must be **below 100** (installed version's priority) or a newer CUDA-repo
version still wins on a tie; -1 blocks it outright. Verified: with it, the dist-upgrade
simulation pulls nothing NVIDIA from the CUDA repo, and `cuda-toolkit-13-1` still resolves.
Check later with `apt-cache policy nvidia-settings` (installed = Ubuntu 510, the 6xx
CUDA-repo versions show priority -1).

## 5. ⚠ GPU at PCIe x4 in an x16 slot — BIOS bifurcation (open)

Symptom: `nvidia-smi --query-gpu=pcie.link.width.current,pcie.link.width.max` → 4 / 16, and
at boot: `pci 0000:4b:00.0: 63.012 Gb/s available PCIe bandwidth, limited by 16.0 GT/s PCIe
x4 link at 0000:4a:04.0 (capable of … x16 link)`.

Diagnosis (`install/red-only/00_pcie_diag.sh`):
- The **root port** `0000:4a:04.0` has `LnkCap … Width x4`, so the link limit comes from
  the CPU side, not from the card or how it's seated.
- SMBIOS: the stack `0000:4a` slot is **`CPU1 SLOT3 PCI-E 4.0 X16`**, slot bus address
  `0000:4a:02.0`. An x16 configuration gives one x16 root port at `4a:02.0`. Instead
  there's only an x4 port at `4a:04.0` (the third x4 port of a split), so that slot's IIO
  stack is **bifurcated** (likely `x4x4x4x4`) and the card trained on one x4 piece.
- Other stacks on this board are bifurcated on purpose: `0000:30` = **CPU1 SLOT5** with a
  4× NVMe carrier card (`nvme0/1/2/4`, buses 31–34), and `0000:64` = onboard NVMe ports
  (system disk `nvme5n1` at `67:00.0`).

Fix (not yet done — planned):
**BIOS → Advanced → Chipset Configuration → North Bridge → IIO Configuration → CPU1
Configuration** → the IOU entry for **SLOT3** → `x16` (or `Auto`). **Leave SLOT5's entry
at `x4x4x4x4`** or the NVMe carrier loses three drives. Afterwards expect
`cat /sys/bus/pci/devices/<gpu>/current_link_width` = 16 and no "limited by" dmesg line.
(Idle speed dropping to 2.5 GT/s is normal power management; the width is what matters.)

Impact for red is small: NVDEC decodes on the GPU from the compressed bitstream, and the
same GPU renders it, so frames don't cross PCIe. Four compressed streams are far below
Gen4 x4's ~8 GB/s. It's still worth fixing for CPU-side texture uploads and any future
inference.

## 6. Desktop launcher

- `install/desktop/install_launchers.sh` now takes **`--red-only`**. Without it, `--pin`
  also pinned an orange launcher, which has nothing to run on this box.
- **red's window class is `Red` (capital R), not `red`.** Measured with
  `xprop -id <win> WM_CLASS` → `"Red", "Red"` (GLFW 3.3 takes it from the window title).
  `install_launchers.sh` used `StartupWMClass=red`; it's now `Red`, so the running window
  groups under the pinned dock icon.
- red's own `install.sh` also writes a `red.desktop` (generic icon, no `StartupWMClass`).
  The launcher script overwrites it with the lab icon version — run it *after* `install.sh`.

## 7. Gotchas, one line each

- CUDA repo `pin-600` → counter-pin driver-side packages *before* adding the keyring (§4).
- Never install the `cuda` / `cuda-13-x` metapackages — they pull a driver. `cuda-toolkit-13-1` only.
- `xp`'s submodule set differs from `main` (`implot3d`, `imgui-filebrowser`; no `httplib`) — re-run `git submodule update --init --recursive` after switching; an empty leftover `lib/httplib/` is harmless.
- GoogleTest must be in `/usr/local` with gmock, or Ceres' config fails at configure time.
- `~/.local/bin/red` must shadow `/usr/bin/red` (= `ed --restricted`); `hash -r` in old shells.
- Server boards bifurcate slots for NVMe carriers — check GPU width with `00_pcie_diag.sh` before blaming the card.
- `test_annotation` is now 718 tests on `xp` `9654b3e` (673 in older notes) — not a regression.
