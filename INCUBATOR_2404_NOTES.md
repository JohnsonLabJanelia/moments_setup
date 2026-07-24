# Field notes — `incubator`: single-Blackwell desktop + Ubuntu 24.04 / kernel 7.0 / CUDA 13.1 (July 2026)

Setup of the `orange` + `red` stack on **`incubator`**, a small **single-GPU desktop**
(not a Threadripper rig): one **RTX PRO 6000 Blackwell** doing display + compute + NVENC,
one dual-port **ConnectX-5**, and a single **HB-65000GM** 65 MP mono camera. This was also
the first build done **without the USB artifact payload** (fully online, FFmpeg rebuilt from
source) and the first on a **kernel 7.0** HWE kernel and an **Intel** CPU (both firsts have
gotchas — see §6/§8).

> The entire setup was driven end-to-end by **Claude Fable 5** (Claude Code) working from
> this repo's notes, with Rob at the keyboard for reboots, camera power-cycles, and GUI
> tests. Companions: [`ADA_2404_NOTES.md`](ADA_2404_NOTES.md) (the closest prior recipe —
> keep-the-preinstalled-driver path), [`BLACKWELL_2404_NOTES.md`](BLACKWELL_2404_NOTES.md),
> [`RED_2404_NOTES.md`](RED_2404_NOTES.md).

**Status: setup complete (2026-07-24).** Headless capture validated host-staged **and
GPU-Direct** (0 drops both ways); orange live streaming **and recording** with GPU-Direct
confirmed in the GUI (16 s / 480 frames @ 8192×7000 HEVC, 0 drops, PTP offsets ~−400 ns);
the recording **opens and scrubs in red**. red: 673/673 + 178/178 headless tests pass,
launcher + desktop icons installed. The NOPASSWD sudoers drop-in has been removed.
One post-setup quirk surfaced on the first camera power-on after a cold host boot —
RS-FEC does not persist (§5).

---

## 1. What the machine is

| | `incubator` (this box) | flyrig / Blackwell boxes |
|---|---|---|
| CPU / RAM | **Intel i7-8700K (6c/12t), 62 GB** — consumer desktop | Threadripper PRO 7965WX, WRX90 |
| OS / kernel | 24.04.4 / **7.0.0-28-generic (HWE)** | 24.04 / 6.17 |
| GPU | **1× RTX PRO 6000 Blackwell 96 GB (sm_120)** — display **and** compute **and** NVENC | Ada/Blackwell display + 2× A16 compute |
| Driver | **595.71.05** (preinstalled `nvidia-driver-595-open`) — kept | 595 / 590 |
| CUDA | **13.1** (`cuda-toolkit-13-1`, apt, toolkit-only) | 13.1 |
| Camera NIC | **1× ConnectX-5 dual-port 25G** (MT27800, fw 16.35.3502), `enp2s0f0np0/np1` | ConnectX-6/7 quad-port |
| DOCA / Rivermax / mft | **3.4.0-085000** (OFED 26.04) / **1.90.18** / 4.36.0-147 | 3.3.0 / 1.81.21 |
| eSDK / eCapture | **4.07.02** / 2.14.02 (`eSDK_..._Ubuntu_24_04_6_14_0` zip) | 4.07.01 / 2.14.02 |
| Camera | **1× HB-65000GM** (65 MP **mono**, 9344×7000), serial 2002743, IP 192.168.2.66, **25GBase-LR fiber** | 7× HB-2800SC etc. |
| Payload | **no USB `moments_artifacts`** — only the eSDK zip + `rivermax.lic` in `~/moments`; everything else online | USB payload |

Single-camera rig by design: one camera at a time, `gpu_id 0` (the only GPU). PTP is still
required (rob_minimal's PTP stream-sync is always-on) — one grandmaster, one slave, works fine.

BIOS was already correct out of the box (**BAR1 = 128 GB**, Secure Boot off) — verify, don't
re-flash: `nvidia-smi -q | grep -A3 BAR1`, `mokutil --sb-state`.

## 2. Install order that worked (all online, no USB)

1. **CUDA 13.1 toolkit** — `cuda-keyring` deb → `apt install cuda-toolkit-13-1` (toolkit-only,
   driver untouched), wire `/etc/profile.d/cuda.sh` + `/etc/ld.so.conf.d/cuda.conf`.
2. **FFmpeg n4.4.5 from source** (§3) → `~/nvidia/ffmpeg/build`.
3. **eSDK 4.07.02** — `install_eSdk.sh -i Mellanox -m <doca-host_3.4.0 deb>` (§4 for the
   apt fights). License → `/var/lib/EVT/rivermax.lic` **and** `/opt/mellanox/rivermax/`.
4. **red** (before orange even — no Emergent dep): gtest+gmock → `/usr/local`, `implot3d`
   submodule, `-DCMAKE_CUDA_ARCHITECTURES="120"`, build, run headless suites, `./install.sh`.
5. **orange** — same cmake flags, arch `120` only.
6. Reboot (new OFED modules), then camera network (§5), headless validation (§7), GPU-Direct (§6).

## 3. FFmpeg without the USB prebuilt — build it, it's fine

The "custom CUDA FFmpeg" is only custom in that orange/red link its **n4.4.5 sonames**
(`libavcodec.so.58`, `libavutil.so.56`, `libswresample.so.3`) — NVENC/NVDEC go through the
Video Codec SDK / `libnvcuvid`, **not** FFmpeg, and red vendors its own `nvcuvid.h` in
`lib/nvcodec`. So a plain shared build is a drop-in replacement:

```bash
git clone --depth 1 --branch n4.4.5 https://github.com/FFmpeg/FFmpeg.git ~/nvidia/ffmpeg-src
cd ~/nvidia/ffmpeg-src
./configure --prefix="$HOME/nvidia/ffmpeg/build" --enable-shared --disable-static \
            --disable-doc --enable-pic
make -j$(nproc) && make install
```

n4.4.5 compiles clean with gcc-13. Bonus over the prebuilt: the `.pc` files carry **this**
machine's `$HOME`, so the flyrig "sed-fix the baked pkg-config prefix" step disappears.
(Keep `bin/ffmpeg` — the verification steps use it; it needs
`LD_LIBRARY_PATH=$HOME/nvidia/ffmpeg/build/lib`, same as the prebuilt.)

## 4. eSDK 4.07.02 installer — new behavior + two apt fights

- **4.07.02's `install_eSdk.sh` self-downloads DOCA 3.4.0** if you omit `-m` (new vs
  4.07.01). We pre-downloaded `doca-host_3.4.0-085000-26.04-ubuntu2404_amd64.deb` and passed
  `-m`. The `-y` flag still hits the unhandled-getopts `exit` — **don't pass `-y`**.
- The zip's `emergent_camera.deb` is a **symlink** to the real deb — extract with `unzip`
  (preserves it); if your extractor flattens it, re-link before installing.
- **Fight 1 — `mft` version shadowing.** `doca-ofed` needs `mft ≥ 4.36.0-147` (in the
  doca-host local repo, priority 500) but the **CUDA apt repo pins at priority 600** and
  its newest mft is 4.35 → apt resolves the wrong one and `doca-all` fails. Fix:
  `apt-get install mft=4.36.0-147 doca-all`.
- **Fight 2 — Rivermax before OFED.** The installer `dpkg -i`'s the bundled Rivermax
  (1.90.18) even when the DOCA step failed; it then depends on `ibverbs-providers ≥ 60`
  (MOFED's) vs stock Ubuntu's 50 and wedges **all** further apt operations. Fix:
  `dpkg --remove rivermax` → install doca-all properly → re-run
  `dpkg -i /opt/EVT/eSDK/third-party/nvidia/rmax/rivermax_ubuntu2404_1.90.18_amd64.deb`.
- **Kernel 7.0.0-28 is fine**: DOCA 3.4 / OFED 26.04 DKMS and `kernel-mft-dkms` all built
  first try (the zip's `6_14_0` name is just Emergent's build kernel; `check_system()` only
  matches the distro string).
- **License**: the eSDK's canonical Linux path is **`/var/lib/EVT/rivermax.lic`**
  (`eSDK/doc/readme.txt`; the `evt_mellanox_init` service auto-refreshes it from Emergent's
  site — it's the universal license). We placed ours there + `/opt/mellanox/rivermax/`.

## 5. ConnectX-5 + 25GBase-LR camera: "cable unplugged" is an autoneg problem, not firmware

Camera link stayed **NO-CARRIER** ("cable unplugged" in the Network panel) with the module
clearly detected (`ethtool -m` shows 25GBase-LR, LC fiber). **25G LR optics don't
autonegotiate** — force the speed (RS-FEC is also required; see the persistence quirk
below) and the link comes up instantly:

```bash
ethtool -s enp2s0f0np0 autoneg off speed 25000 duplex full   # link up in ~5 s
# persist it (plus IP + MTU) via NetworkManager:
nmcli con add type ethernet ifname enp2s0f0np0 con-name camera0 \
  ipv4.method manual ipv4.addresses 192.168.2.20/24 ipv4.never-default yes \
  802-3-ethernet.mtu 9000 802-3-ethernet.auto-negotiate no \
  802-3-ethernet.speed 25000 802-3-ethernet.duplex full
```

**RS-FEC does not persist — the link is dead after a reboot (found 2026-07-24).** The
nmcli profile persists autoneg/speed/duplex but **NetworkManager has no FEC property**, so
after a host reboot the port sits in forced mode with `Active FEC encoding: None` and the
25G-LR link never trains (`ethtool` says "No partner detected during force mode"). Worse,
the chicken-and-egg: with no carrier the `camera0` profile never activates, so nothing
re-applies anything. Fix: a boot-time systemd oneshot that forces speed **and** RS-FEC —
[`install/network/camera-nic-fec.service`](install/network/camera-nic-fec.service)
(`cp` to `/etc/systemd/system/`, `systemctl enable --now camera-nic-fec`; edit the
interface name per box). With FEC forced back to `rs` the link came up instantly.

No NIC firmware update was needed (fw 16.35.3502 works). Other quirks:

- **Discovery needed an IPv4 on the port**: `evttools -d -o b` found **0** cameras with
  only a link-local address; adding any IPv4 (even a wrong-subnet one) made the camera
  answer with its persistent IP (`192.168.2.66`), after which read-then-match applies
  (host = `.20/24`). Slight delta vs the flyrig note that broadcast discovery works pre-IP.
- **The camera can hang while booting.** It was discovered once mid-boot (ping RTT ~10 ms),
  then went **totally silent** — link up, zero ARP/traffic (tcpdump-verified). Only a
  **power-cycle** recovers it. If discovery worked and then everything stops answering,
  don't debug the host — power-cycle the camera.
- Jumbo ICMP (`ping -M do -s 8972`) does **not** echo from this camera even though 9000-MTU
  GVSP streaming is flawless — don't use it as a health check.
- PTP: `ptp_start.sh` edited to this box's single `-i enp2s0f0np0` (committed; per the
  launcher README this file is machine-specific — edit per box). `linuxptp` from apt;
  grandmaster + phc2sys verified. Single camera still needs it (PtpOffset reads).

## 6. GPU-Direct on a single-GPU Intel box

Same three-legged stool as the ADA notes (§6 there), two Intel/single-GPU deltas:

1. **peermem stub → DKMS rebuild** — identical failure (`modprobe nvidia_peermem` EINVAL,
   `nm -u` shows none of the peer-memory symbols). `fix_nvidia_peermem_dkms.sh` **partially
   failed here**: it removed the precompiled `linux-modules-nvidia-595-open-*` package but
   the stub `.ko` files **stayed behind** in `/lib/modules/$(uname -r)/kernel/nvidia-595-open/`,
   which made every plain `dkms install` abort ("already installed… override by --force"),
   left `nvidia-dkms-595-open` half-configured (`iF`) and dkms at "built"-not-"installed".
   Manual recovery:
   ```bash
   sudo rm -rf /lib/modules/$(uname -r)/kernel/nvidia-595-open   # orphaned stub files
   sudo dpkg --configure -a    # nvidia-dkms postinst now installs cleanly → updates/dkms/
   ```
   Then verify the module is real (`nm -u` shows `ib_register_peer_memory_client` +
   `nvidia_p2p_get_pages`) **before** rebooting.
2. **IOMMU: this is an Intel CPU** — the repo's `disable_iommu.sh` and the notes' sed only
   handle `amd_iommu`. Here: add **`intel_iommu=off`** to `GRUB_CMDLINE_LINUX_DEFAULT`,
   `update-grub`, reboot; verify `ls /sys/kernel/iommu_groups | wc -l` → 0.
3. **`libcudart.so.12` shim** — `install_cuda12_cudart.sh` worked as-is (installed
   `cuda-cudart-12-x`, symlinked; EVT GPUDirect libs resolve).

After reboot: `lsmod` shows `nvidia_peermem` **bound into `ib_uverbs`** (registered with
DOCA), and `multistream -g 0` streams with 0 drops — **GPU-Direct into the display GPU
(sm_120) works fine**; no dedicated compute card needed at this scale.

## 7. Headless validation + a scripting gotcha

Same flow as flyrig (§9 there): `evttools -d -o b` → `multistream -n ^ -c 1` (host-staged)
→ `multistream -n ^ -c 1 -g 0` (GPU-Direct). Both ran 0-drop here.

⚠ When driving `multistream` from a script/timeout: its stdout is **fully buffered** when
not a tty — `timeout 40 ./multistream … | tail` can kill it before anything flushes and you
see *nothing*. Use `timeout -s INT 40 stdbuf -oL -eL ./multistream …` (SIGINT + line
buffering) to get real output.

## 8. orange with a mono camera (HB-65000GM)

- **`rob_minimal` already supports mono end-to-end**: `color:false` skips debayer and runs
  `duplicate_channel_gpu_4_ctx` (mono→RGBA) into NVENC, and `set_camera_params()` has a
  built-in HB-65000GM fallback profile. No code changes needed; no need for the (heavily
  diverged) `grayscale`/`jeremy_test` branches.
- **The config JSON must contain every unconditional key.** `load_camera_json_config_files()`
  reads `name,width,height,frame_rate,gain,exposure,pixel_format,color_temp,gpu_id,
  gpu_direct,color,focus,iris` unconditionally — omit any (even color-only ones like
  `color_temp` on a mono camera) and orange dies at load with nlohmann
  `type_error.302`. Optional: `gop,offsetx,offsety,lens_control`.
- Working config (`~/orange_data/config/local/default/2002743.json`): **8192**×7000
  (NVENC HEVC max width is 8192; sensor is 9344 wide), `offsetx: 576` to center the crop,
  `Mono8`, `color:false`, 30 fps, gain 2000, exposure 2500 µs, `gpu_id: 0`,
  `gpu_direct: true`, `lens_control: false`, `focus/iris: 0`.
- Display GPU == compute GPU here; orange's `cudaGLGetDevices()` auto-detection handles it.

## 9. red on this box

Exactly per `RED_2404_NOTES.md` §3 (gtest+gmock to `/usr/local`, `implot3d` submodule,
arch `120`): builds clean, `test_annotation` 673/673 + `test_gui` 178/178, RPATH/ldd clean,
`./install.sh` launcher + `install/desktop/install_launchers.sh --pin` desktop icons done.
GUI playback verified 2026-07-24: the orange GPU-Direct recording (8192×7000 HEVC)
opens and scrubs cleanly in red (NVDEC on the Blackwell) — the full
camera → orange → red loop works on this box.

## 10. Gotchas, one line each

- CUDA apt repo (prio 600) shadows the doca-host local repo (500) → pin `mft=4.36.0-147`.
- Wedged half-installed `rivermax` blocks all apt → `dpkg --remove rivermax`, fix DOCA, reinstall.
- eSDK 4.07.02 installer downloads DOCA 3.4.0 itself; still don't pass `-y`.
- Kernel 7.0.0-28: DOCA 3.4 + nvidia-595 DKMS both build — kernel-too-new fear didn't materialize (again).
- 25G-LR optics: force `autoneg off speed 25000` **+ RS-FEC** or the link never comes up; **not** a firmware problem.
- nmcli persists speed/duplex but **not FEC** → link dead after reboot; install `install/network/camera-nic-fec.service` (boot-time ethtool oneshot).
- `evttools` broadcast discovery wants an IPv4 on the port first.
- Camera discovered-then-silent (no ARP, link up) = hung camera → power-cycle it.
- `fix_nvidia_peermem_dkms.sh` can leave orphaned stub `.ko`s shadowing DKMS → `rm -rf` the `kernel/nvidia-<NNN>-open` dir, `dpkg --configure -a`.
- Intel box → `intel_iommu=off`, not `amd_iommu=off`.
- Mono camera config still needs `color_temp`/`focus`/`iris` keys or orange crashes at JSON load.
- HEVC NVENC width cap 8192 < the 65 MP sensor's 9344 → crop via `width` + centered `offsetx`.
- `multistream` under `timeout`/pipes: `stdbuf -oL` + `timeout -s INT` or you get no output.
- FFmpeg n4.4.5 rebuilt from source is a full substitute for the USB prebuilt (mux/demux only).
- A NOPASSWD sudoers drop-in (`/etc/sudoers.d/99-moments-setup`) was added for the unattended install — removed 2026-07-24 when setup finished. If you use this trick, remember to remove it.
