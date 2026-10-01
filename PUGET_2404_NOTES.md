# Field notes — `puget-291403`: RTX PRO 4000 Blackwell + 4× HE-5000 (10G) / 24.04 / kernel 6.17 (Sept–Oct 2026)

Setup of the `orange` + `red` stack on **`puget-291403`**, a Puget Threadripper PRO 9965WX
workstation: one **RTX PRO 4000 Blackwell** (display **and** NVENC for now — an **A16** goes in
later), one quad-port **ConnectX-7**, and **4× HE-5000SBL-S-M** (5 MP mono, **10GigE**) cameras.
Second fully-online build (no USB payload), first on **eSDK 4.08.05**, first with **10G**
cameras.

> Driven end-to-end by Claude (Claude Code) from this repo's notes, with Rob at the keyboard
> for reboots, camera cabling/power-cycles and GUI tests. Closest prior recipes:
> [`INCUBATOR_2404_NOTES.md`](INCUBATOR_2404_NOTES.md) (online build, DOCA 3.4) and
> [`ADA_2404_NOTES.md`](ADA_2404_NOTES.md) (keep the preinstalled driver, kernel pin).

**Status (2026-10-01):** 4-camera orange record verified — 4 × 2240 frames @ 100 fps,
2464×2064 HEVC, **0 dropped in acquisition and 0 in encoding**, cross-camera timestamp skew
≤ 3.6 µs, PTP offsets ~−600 ns, NVENC ~43% / 10.7 GB VRAM on the single RTX PRO 4000. red:
718/718 + 178/178 headless tests. **Pending:** A16 install (re-map `gpu_id`s), remove the
temporary NOPASSWD sudoers drop-in when setup is done.

---

## 1. What the machine is

| | `puget-291403` |
|---|---|
| CPU / RAM | Threadripper PRO **9965WX** (24c), 251 GB, **single NUMA node** |
| OS / kernel | 24.04.4 / **6.17.0-35-generic** (HWE metas **held** — §2) |
| GPU | **RTX PRO 4000 Blackwell** 24 GB (sm_120), bus f1 — display + NVENC + GPU-Direct target. BAR1 = 32 GB. A16 later. |
| Driver | **595.71.05** `nvidia-driver-595-open` — preinstalled, already the **DKMS** flavour; kept |
| CUDA | **13.1** (`cuda-toolkit-13-1`, apt, toolkit-only) |
| Camera NIC | **1× ConnectX-7 quad** (MT2910, fw 28.44.1036), `enp33s0f0np0`..`f3np3`, 10G links |
| Uplink | Intel X710 (i40e) `enp210s0f0np0` — **not** mlx5, so `openibd restart` can't cut the network |
| DOCA / OFED / Rivermax / mft | **3.4.0-085000** / 26.04 / **1.90.18** / 4.36.0-147 |
| eSDK / eCapture | **4.08.05** / 2.14.02 (`eSDK_4_08_05_eCap_2_14_02_Ubuntu_24_04_6_17_0_x64.zip`) |
| Cameras | **4× HE-5000SBL-S-M** — 5 MP mono, 2464×2064, 1–123 fps, Mono8/10/12, **no lens control** |
| Payload | none — `~/moments` held only the eSDK zip, `rivermax.lic`, camera FW 3.06, EF-mount FW (not flashed) |

## 2. Kernel: hold, don't purge

The box shipped with the `linux-*-generic-hwe-24.04` metapackages installed and
unattended-upgrades on, with **7.0.0-34 already the candidate** — exactly the flyrig panic
setup (ADA notes §2). A lighter pin than flyrig's purge works:

```bash
sudo apt-mark hold linux-generic-hwe-24.04 linux-image-generic-hwe-24.04 linux-headers-generic-hwe-24.04
apt-get -s dist-upgrade | grep -A2 'kept back'   # the three metas are kept back; no linux-image-7.0 Inst
```
Holds are respected by unattended-upgrades; reversible with `apt-mark unhold`. (DOCA 3.4
*does* build on 7.0 per incubator, but the eSDK zip targets 6.17 and nothing here needs 7.0.)

## 3. Install order that worked (all online)

1. Kernel hold (§2) + apt deps: `cuda-keyring` → `cuda-toolkit-13-1`, `nasm`, cmake/glfw/glew/
   eigen/ceres/turbojpeg/openblas, `libgtest-dev libgmock-dev`, `linuxptp`. Wire
   `/etc/profile.d/cuda.sh` + `/etc/ld.so.conf.d/cuda.conf`. Driver untouched.
2. **FFmpeg n4.4.5 from source** → `~/nvidia/ffmpeg/build` (incubator §3, verbatim; needs `nasm`).
   Note it has no zlib → no PNG encoder; extract frames as `.jpg` for spot checks.
3. googletest+gmock → `/usr/local`; **red** (`xp`, `git submodule update --init --recursive`
   after switching branch — the submodule pins differ from `main`), arch **`86;120`**,
   718/718 + 178/178, `./install.sh`.
4. **DOCA 3.4 first, then the eSDK** (§4) → license → GPU-Direct prep (§5) → **one reboot**.
5. **orange** (`rob_minimal`), arch **`86;120`** (A16-ready, no rebuild when it lands).
6. Camera network (§6), PTP (§7), headless validation, orange.

## 4. eSDK 4.08.05 — pre-install DOCA to dodge both incubator apt fights

4.08.05's installer still self-downloads DOCA 3.4.0 if `-m` is omitted, still dies on `-y`.
Doing DOCA **yourself first** avoids both the `mft` shadowing and the Rivermax-before-OFED
wedge:

```bash
wget https://www.mellanox.com/downloads/DOCA/DOCA_v3.4.0/host/doca-host_3.4.0-085000-26.04-ubuntu2404_amd64.deb
sudo dpkg -i doca-host_3.4.0-085000-26.04-ubuntu2404_amd64.deb && sudo apt-get update
sudo apt-get install -y mft=4.36.0-147 doca-all     # CUDA repo (prio 600) shadows mft 4.36 → pin it
./install_eSdk.sh -i Mellanox -m $PWD/doca-host_3.4.0-085000-26.04-ubuntu2404_amd64.deb   # DOCA step = no-op now
```
All OFED DKMS modules built first try on 6.17. `evt_mellanox_init` **succeeded** at install
here (unlike flyrig) and dropped a `/var/lib/EVT/rivermax.lic` **byte-identical** to the
supplied one (it's Emergent's universal license). Supplied copy also placed at
`/opt/mellanox/rivermax/rivermax.lic` per Emergent's instructions.

**New in 4.08.05:** `libEmergentGPUDirect.so` links **`libcudart.so.13`** — the
`install_cuda12_cudart.sh` shim is **no longer needed** (it was installed before this was
noticed; harmless).

## 5. GPU-Direct: "already DKMS" still has a stub peermem

The driver was already `nvidia-dkms-595-open`, but DKMS had compiled it **before DOCA
existed**, so `nvidia-peermem.ko` was still a stub (`nm -u` shows none of
`ib_register_peer_memory_client` / `nvidia_p2p_get_pages`). `fix_nvidia_peermem_dkms.sh`
assumes the *precompiled* flavour (its apt step is a no-op here and `dkms install --force`
isn't guaranteed to recompile), so rebuild directly — same version, running driver
unaffected until reboot:

```bash
sudo dkms remove  nvidia/595.71.05 -k $(uname -r)
sudo dkms install nvidia/595.71.05 -k $(uname -r)     # recompiles with MOFED present
# verify: zstd -d the .ko from `modinfo -n nvidia_peermem`; nm -u | grep -E 'ib_register_peer|nvidia_p2p_get_pages'
sudo update-rc.d start-nvidia-peermem defaults
```
IOMMU: cmdline had `amd-iommu=on iommu=pt` → the repo's `disable_iommu.sh` sed applies, but
that script **auto-reboots**; done by hand instead (`sed` → `amd_iommu=off`, `update-grub`,
`update-initramfs -u`). After the reboot: 0 iommu groups, `nvidia_peermem` bound into
`ib_uverbs`, `multistream -g 0` 0-drop.

## 6. Camera network — all cameras ship with the SAME IP

Every HE-5000 came at **192.168.1.69**, so read-then-match (`match_camera_ports.sh`) only
works for the first camera — four ports can't share one /24. Final layout: **one subnet per
port, host `.20`, camera `.21`** (also matches `multistream`'s default 192.168.1–4 groups,
and no camera keeps the factory IP, so the next new camera can't collide):

| Port | Serial | Camera | Host (nmcli profile) |
|---|---|---|---|
| `enp33s0f0np0` | 2017179 (Cam0) | 192.168.1.21 | 192.168.1.20 (`cam_2017179`) |
| `enp33s0f1np1` | 2017182 (Cam1) | 192.168.2.21 | 192.168.2.20 (`cam_2017182`) |
| `enp33s0f2np2` | 2017181 (Cam2) | 192.168.3.21 | 192.168.3.20 (`cam_2017181`) |
| `enp33s0f3np3` | 2017180 (Cam3) | 192.168.4.21 | 192.168.4.20 (`cam_2017180`) |

Procedure per port: create the static host profile first (same options as
`match_camera_ports.sh --apply`: manual IPv4, `never-default`, `ipv6.method ignore`,
MTU 9000), then write the camera's persistent IP:
```bash
cd /opt/EVT/eSDK/tools; export LD_LIBRARY_PATH=/opt/EVT/eSDK/lib
sudo -E ./evttools -f 192.168.2.20 -o bp     # camera on that port -> 192.168.2.21, persisted
```
Gotchas:
- **`-f` needs `b` in `-o`** — with `-o p` alone it discovers unicast-only, finds nothing new,
  and silently forces nothing.
- **NetworkManager's stock "Wired connection N" DHCP profiles wipe manual `ip addr add`
  addresses** while they sit in "activating" → discovery flaps. Create the static profile
  instead, and `nmcli con modify "Wired connection N" connection.autoconnect no` (kept, not deleted).
- Discovery still wants an IPv4 on the port first (incubator §5).
- Verified persistent across a camera power-cycle (all four rediscovered at their new IPs,
  4-cam stream 0-drop, PTP re-locked).

`multistream -j` (get/set a param) never parsed for us (0 params); a ~40-line C++ program
against `EmergentCameraAPIs.h` (`EVT_ListDevices` → `EVT_CameraOpen` →
`EVT_CameraGetUInt32Param{,Min,Max}` / `EVT_CameraGetEnumParam{,Range}`) is the quick way to
read sensor limits.

## 7. PTP

`/bin/ptp_start.sh` was installed with this box's `-i enp33s0f0np0 … -i enp33s0f3np3` (the
**repo copy is untouched** — it's machine-specific). All four ports MASTER ~7 s after ptp4l
starts; cameras reach `Slave` within 5 s of `PtpMode=TwoStep`, offsets −550…−700 ns,
within ~90 ns of each other. Because of that ~7 s + lock time, **wait ~15 s after launching
orange before starting a stream** so the gated start computes its gate time on locked clocks.

## 8. orange — config + the exit crash

- Config (`~/orange_data/config/local/default/<serial>.json`, one per camera, `Cam0..Cam3`):
  2464×2064, `offsetx/offsety 0` (sensor has no ROI slack at full res), `Mono8`,
  `color:false`, `frame_rate 100`, `gain 1000`, `exposure 2500`, `color_temp CT_3000K`
  (required key even on mono), `gpu_id 0`, `gpu_direct true`, `lens_control false`,
  `focus/iris 0`. The HE-5000 has no built-in fallback profile in `set_camera_params()`, so
  the JSON is mandatory.
- **NVENC budget** (single RTX PRO 4000, HEVC preset p1): 1 cam = 10% enc / 2.4 GB VRAM;
  4 cams = 42–45% enc / 10.7 GB. Practical ceiling ~7–8 cams at 2464×2064@100 before the A16.
- **Closing the orange window while streaming crashed it** (EVT error 271 flood →
  CUDA invalid-argument in `opengldisplay.cpp` → double free / segfault, exit 134/139): the
  exit path closed cameras and `cudaDeviceReset()` without stopping the capture threads.
  Reproduced on demand. Fix in `orange.cpp`: if `camera_control->subscribe`, call
  `stop_camera_streaming()` before the exit cleanup. Workaround on unfixed builds:
  stop streaming → Close Camera → quit.
- `orange_launcher.sh` now runs orange under `stdbuf -oL -eL`: through `tee`, orange's
  `printf`s were fully buffered — the log showed "Close Camera" thousands of lines late and
  buffered lines were lost on the crash.
- orange's own `install.sh` puts a plain `~/.local/bin/orange` wrapper (no sudo, no PTP)
  **ahead of** `/usr/local/bin/orange` on PATH, and the desktop launcher picks it up too.
  Removed it; `install/desktop/install_launchers.sh --pin` then pins the PTP launcher.

## 9. A16 checklist (when it's installed)

- No driver change: 595.71.05-open runs A16s (flyrig). Apps already built for `sm_86`.
- Expect GPU index reshuffle (`nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv`);
  the display GPU may land mid-stack (flyrig: idx 4). Re-map each camera's `gpu_id` to one
  A16 die; re-run `multistream -n ^ -c 4 -f 100 -g <id>` per die.
- Check `nvidia-smi -q | grep -A3 BAR1` ≈ 16 GB per die (not 256 MB).
- peermem/DKMS: nothing to redo (same driver/kernel).

## 10. Gotchas, one line each

- HWE metas + unattended-upgrades + 7.0 candidate → `apt-mark hold` the three metas.
- Pre-install DOCA (`mft=4.36.0-147 doca-all`) before `install_eSdk.sh -m` → no apt fights.
- eSDK 4.08.05 GPU-Direct links `libcudart.so.13` → no CUDA-12 shim needed.
- Already-DKMS driver compiled before DOCA = stub peermem → `dkms remove` + `dkms install`.
- `disable_iommu.sh` reboots by itself — do the sed/update-grub by hand to batch reboots.
- Identical factory camera IPs → one subnet per port, `evttools -f <host_ip> -o bp` (needs `b`).
- Stock DHCP "Wired connection N" profiles wipe temp IPs → static profile + autoconnect off.
- Wait ~15 s after launching orange before streaming (PTP master + camera lock).
- Don't close the orange window mid-stream on builds without the exit fix.
- orange `install.sh`'s `~/.local/bin/orange` shadows the PTP launcher → remove it.
- Minimal FFmpeg build has no PNG encoder → grab test frames as JPEG.
- `multistream`/`evttools` under pipes: `timeout -s INT` + `stdbuf -oL` (incubator §7).
