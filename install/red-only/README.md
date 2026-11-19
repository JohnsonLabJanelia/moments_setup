# red-only install (24.04, Ubuntu-packaged NVIDIA driver, no orange)

Small, standalone scripts for a machine that **only runs `red`** (viewing multi-camera
recordings, proofreading predictions) — no cameras, no Emergent/DOCA/Rivermax, no USB
payload. Everything comes from apt or source online. Written and verified on the
Supermicro X12DAi-N6 / RTX A4000 box — see
[`../../RED_A4000_XEON_2404_NOTES.md`](../../RED_A4000_XEON_2404_NOTES.md).

Assumes the NVIDIA driver is **already installed from Ubuntu / the graphics-drivers PPA**
(e.g. `nvidia-driver-595-open`) and that `red` is cloned at `~/src/red` on branch `xp`
(`git checkout xp && git submodule update --init --recursive`).

| Script | sudo? | Does |
|---|---|---|
| `00_pcie_diag.sh` | yes (read-only) | GPU slot label + link width vs root-port width — catches BIOS bifurcation |
| `10_apt_deps.sh` | yes | red build deps from the Ubuntu archive; aborts if apt would remove anything or touch driver/kernel packages |
| `20_cuda.sh` | yes | **counter-pin first**, then `cuda-keyring` + `cuda-toolkit-13-1` (toolkit only), `/etc/profile.d/cuda.sh`, `/etc/ld.so.conf.d/cuda.conf` |
| `30_gtest.sh` | install step | GoogleTest **with gmock** → `/usr/local` (red's CMake requires it before Ceres) |
| `40_ffmpeg.sh` | no | FFmpeg n4.4.5 shared → `~/nvidia/ffmpeg/build` |
| `50_build_red.sh` | no | configure (`CUDA_ARCH`, default 86), build `red` + tests, ldd/RPATH check, headless tests, `./install.sh` |

Then the desktop icon: `../desktop/install_launchers.sh --red-only --pin`.

Run them in order as your normal user (the sudo ones prompt). Each is safe to re-run.

## Why the counter-pin in `20_cuda.sh` matters

`cuda-keyring` installs `/etc/apt/preferences.d/cuda-repository-pin-600`, which ranks
**everything** in NVIDIA's CUDA repo above Ubuntu. That repo also carries driver-side
packages from newer branches, so on a box whose driver came from Ubuntu/the PPA, the next
`apt upgrade` would swap `nvidia-settings`, `libxnvctrl0` and `libnvidia-egl-wayland1` for
620.x builds (dry-run verified, Nov 2026). `20_cuda.sh` first writes
`/etc/apt/preferences.d/99-keep-ubuntu-nvidia-driver` (Pin-Priority -1 for
`nvidia-*`, `libnvidia-*`, `libxnvctrl*`, `xserver-xorg-video-nvidia*`, `cuda-drivers*`, …
from the CUDA repo), then refuses to continue if a simulated `dist-upgrade` would still
pull any of them. CUDA toolkit packages are unaffected.
