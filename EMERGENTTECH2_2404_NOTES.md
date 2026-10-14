# Field notes — `EmergentTech2`: TR PRO 9975WX + 2× A16 + RTX 4000 Ada + dual-port 100G ConnectX-6 Dx, 8 cameras GPU-Direct (Oct 2026)

Upgrade and GPU-Direct debug of the `orange` + `red` stack on **`EmergentTech2`**, a PCSpecialist
"Amd Wrx90 4U" (ASUS **Pro WS WRX90E-SAGE SE**, BIOS **1203**) with a **Threadripper PRO 9975WX
(Zen 5)**, **2× A16** (8 dies), an **RTX 4000 Ada** display GPU, **one dual-port 100 GbE
ConnectX-6 Dx** and **8 cameras** (4× HB-20000SBM + 4× HB-16000SBM, ~70 Gb/s total). The
production layout is **one camera per A16 die, GPU-Direct**, recorded by `orange rob_minimal`.

> Driven by Claude (Claude Code) with Rob at the keyboard for reboots, NIC resets and the
> card move. The box already ran the stack (eSDK 4.06 / driver 535 `.run` / kernel 6.8) but
> **8-camera GPU-Direct stalled** while a near-identical older rig (`emergenttech462`,
> 7975WX Zen 4, BIOS 0901) streamed the same cameras clean. Closest prior recipes:
> [`ADA_2404_NOTES.md`](ADA_2404_NOTES.md) (2× A16 + Ada display, kernel pin) and
> [`PUGET_2404_NOTES.md`](PUGET_2404_NOTES.md) (eSDK 4.08.05, DOCA 3.4 pre-install).
> The cross-machine investigation lives in its own repo:
> `github.com:neurogears/emergenttech_gpudirect_debug` (§7).

**Status (2026-10-14):** 8-camera 60 fps GPU-Direct **recording in orange with 0 dropped frames**
(10,569 frames/camera per 180 s, no NIC discards/pause/PCIe stalls), repeatable (§3.7 is the
checklist of what must be true); host-staged
path also 0 drops; red `xp` builds, passes 718+178 tests and plays back the recordings. **Two
things are required, both verified by reverting them:** (1) NIC **`PCI_WR_ORDERING=force_relax`**
(without it the 3.4 s stall returns every run, even in the new slots) and (2) **the A16s and the
display GPU in the reference rig's slot pattern** (without it ~0.01 % residual drops remain).
A third change tried along the way, the NIC rx buffer 156 KB → 1 MB, helped only in the old slot
layout and is **not needed** now (rx buffer back at default). **Pending:** BIOS CBS page comparison
with the 462 to explain why this box needs relaxed ordering at all; merge orange branch
`rob_minimal_line_time` (`b6e4e3b`, the `line_time` key) into `rob_minimal`.

---

## 1. What the machine is

| | `EmergentTech2` | `emergenttech462` (working reference for GPU-Direct) |
|---|---|---|
| CPU / RAM | TR PRO **9975WX** (32c, Zen 5), 503 GB (8× 64 GB 6400), **1 NUMA node** | TR PRO 7975WX (Zen 4), same RAM |
| Board / BIOS | ASUS Pro WS WRX90E-SAGE SE / **1203** (2025-07) | same board / 0901 (2025-03, pre-Zen-5 — cannot be flashed here) |
| OS / kernel | 24.04.4 / **6.17.0-40-generic** (HWE metas **held**) | 22.04 / 6.8 |
| Cmdline | `pcie_aspm=off amd_iommu=off` | `pci=realloc=off pcie_aspm=off amd_iommu=on iommu=pt` |
| Display GPU | **RTX 4000 Ada** (sm_89), nvidia-smi index **4** under `CUDA_DEVICE_ORDER=PCI_BUS_ID` | RTX 6000 Ada, index 4 |
| Compute GPUs | **2× A16** = 8 dies (sm_86), BAR1 16 GB/die; dies 0–3 and 5–8 | same |
| Driver | **595.99.02** `nvidia-driver-595-open` (apt, DKMS) — replaced the 535 `.run` | 535.183.06 `.run` |
| CUDA | **13.3** (`cuda-toolkit-13-3`, toolkit-only; 12.9 config remnants are harmless) | 12.2 |
| Camera NIC | **1× ConnectX-6 Dx dual-port 100G** (MCX623106AN-CDA, fw **22.35.1012**), bus f1 under root port `f0:01.1`, `enp241s0f0np0` / `enp241s0f1np1` | same model/fw |
| Uplink | Intel X710 `enp209s0f0np0` (i40e, not mlx5) | same |
| DOCA / OFED / Rivermax / mft | **3.4.0-085000** / 26.04-0.8.6 / **1.90.18** / 4.36.0-147 | 3.1.0 / 25.07 / 1.71.30 |
| eSDK / eCapture | **4.08.05** (`eSDK_4_08_05_eCap_2_14_02_Ubuntu_24_04_6_17_0_x64.zip`) | 2.62.02 libs |
| Cameras | 4× **HB-20000SBM** (4512×4512) + 4× **HB-16000SBM** (5328×3040), Mono8, 60 fps, one L2 switch that is the **PTP grandmaster** | same cameras |
| orange / red | `rob_minimal` @ `34d0021` + branch `rob_minimal_line_time` `b6e4e3b` (`line_time`, §5) / `xp` @ `9654b3e`, both `-DCMAKE_CUDA_ARCHITECTURES=86;89`, built in `~/new_src/{orange,red}/release` | `ng-dev` |

Slot layout **after the 2026-10-14 move** (this matters — §3.4): A16 #1 → bus 05–08 under root
port `00:01.1` (DMI `PCIEx16(G5)_3`), A16 #2 → bus c5–c8 under `c0:01.1`, RTX 4000 Ada → bus 21
under `20:01.1`, NIC unchanged. The BIOS-1203 DMI slot table (`dmidecode -t 9`) lists only
two or three of the seven slots, so confirm placement with `lspci -tv`, not DMI.

## 2. The 2026-10-13 stack upgrade (eSDK 4.06 → 4.08.05, driver 535 → 595, kernel 6.8 → 6.17)

Done in this order, one reboot at the end. Logs in `~/.moments-setup/logs/0[1-6]_*.log`.

1. **Kernel:** `sudo apt install linux-generic-hwe-24.04 linux-headers-generic-hwe-24.04`
   → 6.17.0-40, then **hold** the six HWE metas (`apt-mark hold linux-{generic,image-generic,headers-generic}-hwe-24.04{,-edge}`)
   so the 7.0 kernel that breaks OFED DKMS (ADA notes) never arrives. 6.8.0-134 is still in
   `/boot` as a fallback.
2. **eSDK 4.06.01 → 4.08.05:** `uninstall_eSdk.sh` (also removes Rivermax + old DOCA 3.3),
   then **DOCA 3.4 pre-installed** exactly as in PUGET §4
   (`dpkg -i doca-host_3.4.0-085000-26.04-ubuntu2404_amd64.deb; apt install mft=4.36.0-147 doca-all`),
   then `./install_eSdk.sh -i Mellanox -m <that deb>` → Rivermax 1.90.18 + eSDK 4.08.05,
   `evt_mellanox_init.service` enabled (it fetches/refreshes the universal `rivermax.lic`).
   `libEmergentGPUDirect.so` links `libcudart.so.13` — **no CUDA-12 shim**.
3. **Driver:** `nvidia-installer --uninstall` (the 535 `.run`), then
   `apt install nvidia-driver-595-open` → `nvidia-dkms-595-open` builds `nvidia-peermem.ko`
   **against the now-present MOFED**, so peermem is real on first build (no PUGET §5 rebuild
   needed). `evt_nvidia_peermem.service` (from the eSDK) loads it at boot; after reboot
   `lsmod` shows `nvidia_peermem` used by `ib_uverbs`.
4. **IOMMU:** `amd_iommu=on iommu=pt` → `amd_iommu=off` in `/etc/default/grub`, `update-grub`
   (0 IOMMU groups after reboot). Tested both ways on this box: neither fixed GPU-Direct
   (§3), but off is what every other rig runs.
5. **orange rebuild** against eSDK 4.08.05 (`cmake --build release -j32`), red rebuild + tests.

## 3. GPU-Direct: the 8-camera stall and what actually fixed it

### 3.1 Symptom

`multistream` alone (no orange), 8 cameras one per die, `-g 0,1,2,3` on port 0 and `-g 5,6,7,8`
on port 1: at a random moment 1–50 s in, **all eight cameras stall for ~3.4 s** (~215 frames
each), some never resume. NIC counters per event: `tx_pause_ctrl_phy` +25 k,
`rx_discards_phy` +0.5–1 M, **`outbound_pci_stalled_wr_events` +3–5**, `rx_out_of_buffer` 0,
dmesg/AER clean. Host-staged capture of the same 8 cameras: **never** stalls. ≤ 4 cameras into
one A16, or 2+2 across both ports: clean. 3+3 or more across both cards: stall. GPU-Direct
into the Ada alone also stalls.

Ruled out on this box before the fix (Oct 8–9 investigation in `~/Dev/gpu_direct`, and 13 Oct):
kernel 6.8 vs 6.17, driver 535 vs 595, NIC fw 22.43 vs 22.35, IOMMU off vs passthrough, the
462's entire user-space stack (eSDK 2.62 / Rivermax 1.71 / rdma-core 25.07 / cudart 12.2),
C-states, GPU clock locks / link power states, Ethernet pause, camera `LineTime`, PTP, per-die
bandwidth (`ib_write_bw` loopback = 101 Gb/s into any die set, 0 stall events).

### 3.2 Fix 1 — NIC PCIe write ordering (the stall)

The `outbound_pci_stalled_wr_events` counter is the tell: the NIC's posted writes into the two
A16 switch hierarchies back up under **strict ordering**. One NVRAM change on the NIC:

```bash
sudo systemctl stop evt_eCaptureProServer      # nothing may hold the NIC
sudo mlxconfig -d f1:00.0 set ADVANCED_PCI_SETTINGS=1 PCI_WR_ORDERING=1   # 1 = force_relax
sudo mlxfwreset -d f1:00.0 -y reset            # applies without reboot; links drop ~10 s
sudo mlxconfig -d f1:00.0 q | grep -E 'PCI_WR_ORDERING|ADVANCED'   # force_relax(1) / True(1)
```
Persistent across reboots. Result: **0 stall events in every run since**; drops fell from
~215/camera/event to 0–18 per 180 s. **Verified required independently of the slot layout:**
with the cards in the reference pattern (§3.4) and the NIC put back to `per_mkey`, the stall
came straight back in 3 of 3 runs. The reference rig (Zen 4, BIOS 0901) runs the default
`per_mkey` and is clean; why this platform differs is not explained (BIOS CBS pages are the
only lead). Revert: `PCI_WR_ORDERING=0 ADVANCED_PCI_SETTINGS=0` + another `mlxfwreset`.

### 3.3 Tried and dropped — NIC receive buffer

Residual ~0.01 % single-frame drops (2–3 cameras lose the same frame id) remained after 3.2,
only when **both A16 cards** receive at once. In the *old* slot layout, enlarging the port rx
buffer for priority 0 from the default 156 KB to ~1 MB (`mlnx_qos -i <port>
--buffer_size=0,1000000,0,0,0,0,0,0`, not persistent, hence
[`install/network/camera-nic-rxbuf.service`](install/network/camera-nic-rxbuf.service)) halved them
(18/5 → 8/0 per 180 s). After the card move (3.4) the production layout is 0-drop with the
**default** buffer (2 × 180 s), so the unit was removed again; it stays in the repo as a
reference for the knob only. The reference rig runs the default buffer too.

### 3.4 Fix 2 — card placement (the residual drops)

With the shared repo's profiler run on both machines, every NIC / PCIe-link / root-port
capability / OFED / Rivermax setting was **identical** (`diff_profiles.sh`, `lspci -vvv`
diffs of root ports, A16 bridges and NIC). What differed, besides Zen 5 + BIOS 1203, was
**where the cards sat**: on the 462 the NIC has a host-bridge quadrant to itself and the A16s
hang off root ports `00:01.1` / `80:03.1`; here the NIC (`f0`) and A16 #2 (`e0`) sat on
adjacent host bridges. Rob moved the A16s to the slots the 462 uses (DMI slots 3 and 5) and the
display GPU to slot 7-ish (§1). Result, all 180 s / 60 fps / 8-camera GPU-Direct, NIC at
`force_relax`:

| Test | Before the move (1 MB buffer) | After, 1 MB buffer | After, **default 156 KB buffer** (final state) |
|---|---|---|---|
| production layout, 1 cam/die, both A16s (×2) | 8 / 18+5 drops | **0 / 0** | **0 / 0** |
| 2 dies per card, both A16s | 4 / 12 drops | **0** | **0** (86,414 frames) |
| orange `rob_minimal_8cam_60fps_gpuDirect` recording | 11–12 drops | **0** (10,559 frames/cam) | **0** (10,569 frames/cam) |

"No counter moved" in every "after" run: `rx_discards_phy`, `tx_pause_ctrl_phy`,
`outbound_pci_stalled_wr_events` all +0 on both ports.

And the control, same slots, **NIC at factory** (`per_mkey`, advanced PCI settings off, 156 KB):
production ×2 and two-dies-per-card all stalled again (978 / 1236 / 973 drops per 180 s,
`outbound_pci_stalled_wr_events` +4 per port, pause +24–30 k). So **both** the slot pattern and
`force_relax` are required; neither alone is enough. Why this platform needs relaxed ordering
when the Zen 4 / BIOS 0901 reference does not is the one open question (BIOS CBS pages).

### 3.5 Things that made it worse (don't)

- **Mixing camera models on one NIC port** (2+2 or 3+1 splits by re-IP): ~50–90 drops/camera
  per 180 s plus multi-second stalls in orange. Keep all HB-20000s on port 0 and all
  HB-16000s on port 1.
- **Camera `LineTime` at its reset value 782** (a camera reboot resets it): 189 drops/180 s.
  Max at 60 fps is **1402** (HB-20000) / **2032** (HB-16000); `multistream -j u,LineTime,max`
  or orange's `line_time` key (§5) restores it. Verified on the 462 too: LineTime min drops
  most frames, 1402 and max are clean.
- `pci=pcie_bus_safe`, `MAX_ACC_OUT_READ`: not differentiators (both rigs already run NIC
  MaxPayload 512 / dies 256). ASPM already off.

### 3.6 Headless test recipe (what "working" means)

```bash
cd /opt/EVT/eSDK/tools; export LD_LIBRARY_PATH=/opt/EVT/eSDK/lib CUDA_DEVICE_ORDER=PCI_BUS_ID
sudo -E ./evttools -d                          # 8 cameras, .3.x on 192.168.3.83, .2.x on 192.168.2.83
# production layout, one multistream per port, 180 s, LineTime max; from the debug repo:
sudo -E tools/multistream_layout.sh prod8 180 \
  "192.168.3@11-11,192.168.3@12-12,192.168.3@13-13,192.168.3@14-14|1,1,1,1|60|0,1,2,3" \
  "192.168.2@21-21,192.168.2@22-22,192.168.2@23-23,192.168.2@24-24|1,1,1,1|60|5,6,7,8"
# pass = frames=86416 drops=0 and "nic: no counter changed" (rx_discards_phy, tx_pause_ctrl_phy,
# outbound_pci_stalled_wr_events on both ports). Confirm buffers land on dies 0-3 / 5-8:
nvidia-smi dmon -s t -c 3    # ~1.25 GB/s rx per card-1 die, ~1.0 GB/s per card-2 die, display 0
```

### 3.7 Final configuration — what must be true on this box

1. **Slots:** A16 #1 under root port `00:01.1` (bus 05–08), A16 #2 under `c0:01.1` (bus c5–c8),
   display GPU under `20:01.1`, NIC under `f0:01.1` — check with `lspci -tv`; nvidia-smi
   indices 0–3 / 4 / 5–8 under `PCI_BUS_ID`.
2. **NIC NVRAM:** `sudo mlxconfig -d f1:00.0 q | grep -E 'PCI_WR_ORDERING|ADVANCED'` →
   `force_relax(1)` / `True(1)`. Everything else on the NIC at factory, incl. the rx buffer
   (`mlnx_qos -i enp241s0f0np0` → `0,156096,0,…`); **no** `camera-nic-rxbuf.service` installed.
3. **Boot:** kernel 6.17.0-40 (HWE metas held), `amd_iommu=off pcie_aspm=off`,
   `nvidia_peermem` loaded and used by `ib_uverbs`, `evt_mellanox_init` + `evt_nvidia_peermem` enabled.
4. **Cameras:** `LineTime` 1402 / 2032 (orange presets set it; after any camera power-cycle
   `multistream -j u,LineTime,max` or just open them in orange), HB-20000s on port 0 only,
   HB-16000s on port 1 only, switch as PTP grandmaster, no host `ptp4l`.
5. **Pass criterion:** §3.6 recipe → `frames=86416 drops=0`, `nic: no counter changed`; orange
   `rob_minimal_8cam_60fps_gpuDirect` 180 s → `Dropped Frames: 0` on all eight.

## 4. Camera network and PTP

- One **dual-port 100G** NIC, one subnet per port, host `.83`: `cam0` = `enp241s0f0np0`
  192.168.3.83/24 (HB-20000s 192.168.3.11–14), `cam1` = `enp241s0f1np1` 192.168.2.83/24
  (HB-16000s 192.168.2.21–24); MTU 9000; NetworkManager profiles (`nmcli con show cam0 cam1`,
  netplan `90-NM-*.yaml`). Camera IPs are persistent in the cameras.

| Port | Camera IP | Serial | Model | gpu_id (`PCI_BUS_ID`) |
|---|---|---|---|---|
| f0np0 (192.168.3.83) | .3.11 / .3.12 / .3.13 / .3.14 | 2010119 / 2010120 / 2010122 / 2010121 | HB-20000SBM 4512×4512 | 0 / 1 / 3 / 2 |
| f1np1 (192.168.2.83) | .2.21 / .2.22 / .2.23 / .2.24 | 2010126 / 2010125 / 2010124 / 2010123 | HB-16000SBM 5328×3040 | 8 / 7 / 6 / 5 |

- Per camera at 60 fps Mono8: 9.77 Gb/s avg / 25.75 Gb/s burst (HB-20000), 7.77 / 20.98 (HB-16000);
  `GevSCPSPacketSize` 7716. Port rates ~62 and ~49 Gb/s.
- **PTP: the switch is the grandmaster** (649d99.fffe.6112f5). **Do not run host `ptp4l`**
  (`/bin/ptp_start.sh` is not used here; `ptp4l@`/`phc2sys@` disabled). Cameras come up
  `Slave` by themselves; orange's gated start put all 8 first frames within 20 ns.
- Re-IP a camera (only if you must): `EVT_ForceIPEx` did not work on these; use `EVT_IPConfig`
  (`tools/reip.cpp` in the debug repo) then `evttools -r <serial>` to reboot it — and restore
  `LineTime` afterwards (§3.5).

## 5. orange (`rob_minimal`)

- `CUDA_DEVICE_ORDER=PCI_BUS_ID` is set in `main()`, so `gpu_id` = nvidia-smi index: dies 0–3
  (card 1), display GPU **4**, dies 5–8 (card 2). The other presets in `config/local/` from the
  `ng-dev` fork use `gpu_id 1–8` → one camera lands on the Ada; use only the `rob_minimal_*` presets.
- Presets: `~/orange_data/config/local/rob_minimal_8cam_60fps_gpuDirect/<serial>.json`
  (`gpu_direct: true`) and `rob_minimal_8cam_60fps_host/` (`false`), both 60 fps Mono8,
  `gop 1`, HEVC preset `p1` global, and **`"line_time": 1402`** (HB-20000) / **`2032`** (HB-16000).
- **New config key `line_time`** (orange branch `rob_minimal_line_time`, commit `b6e4e3b`, pushed;
  `src/camera.{h,cpp}`, `src/video_capture.cpp`): applied at camera open, clamped to the camera's min/max, logged as
  `LineTime: <cur> (range min-max)`; `0`/absent = leave the camera's value. Same commit:
  preset folders sorted and the preset radio row wraps to the window width (`src/orange.cpp`).
- Recording folder: `~/.config/orange/config.json` → `/mnt/data` (`/mnt/data/exp/unsorted/<ts>/`).
- Launch: `cd ~/new_src/orange && sudo -E ./release/orange` (needs root for the NIC). Note
  `~/.nix-profile/bin/orange` on PATH is the **other** fork's build — don't mix them up.
- GUI drop check: after Stop, the log prints per camera `Frame count … Dropped Frames: N`.
  `tools/orange_gd_test.sh` in the debug repo drives preset → Select all → Open → record →
  stop with `xdotool` (coordinates assume this box's `imgui.ini`).

## 6. red (`xp`)

`~/new_src/red` `xp` @ `9654b3e`, arch `86;89`, 718/718 + 178/178 headless tests after the
595 driver (the old 535 `.run` failed `cuCtxCreate` on CUDA 13.3). Launch with the display GPU:
`CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=4 ./release/red <proj>.redproj`.
Playback project for the recordings: `~/red_data/et2_playback/et2_playback.redproj`
(`media_folder` = a `/mnt/data/exp/unsorted/<ts>` folder). Its copied `aruco_calibration/` uses
`CamNNN.yaml` names → harmless "Failed to load camera params" popup.

## 7. The cross-machine debug repo

`~/new_src/emergenttech_gpudirect_debug` (`github.com:neurogears/emergenttech_gpudirect_debug`),
shared with the 462's operator. Read `README.md` → `PLAN.md` → `results/EmergentTech2/`
(`findings.md`, `symptom.md`, `log.md`, `diff-triage.md`). Tools worth reusing on any rig:
`profile_system.sh --cameras` + `diff_profiles.sh A B` (settings diff), `check_gpudirect.sh`
(prerequisite PASS/FAIL), `snapshot.sh` (full `mlxconfig`, per-bridge PCIe caps),
`multistream_layout.sh` (concurrent per-port `multistream` with NIC counter deltas),
`nic_counters.sh`, `monitor_capture.sh`, `reip.cpp`. Raw logs of every run are under
`results/EmergentTech2/` and `logs/EmergentTech2/`.

## 8. Gotchas, one line each

- HWE metas present → `apt-mark hold` all six (`…-hwe-24.04` and `-edge`) or 7.0 breaks OFED DKMS.
- Pre-install DOCA 3.4 + `mft=4.36.0-147` before `install_eSdk.sh -m` (PUGET §4) — no apt fights.
- Install the apt driver **after** DOCA → DKMS builds a real `nvidia-peermem` first time.
- `outbound_pci_stalled_wr_events` climbing with pause storms = PCIe write ordering → `PCI_WR_ORDERING=force_relax` + `mlxfwreset`.
- Residual drops only with both A16s as targets → card placement; copy the 462's slot pattern.
- Never mix camera models on one NIC port; a camera reboot resets `LineTime` to 782 → restore to max.
- The switch is the PTP grandmaster → no host `ptp4l`; `multistream` disables PTP on the cameras anyway.
- `gpu_id` is nvidia-smi index only under `PCI_BUS_ID`; the display GPU is index 4 (mid-stack).
- `evt_eCaptureProServer.service` holds the NIC → stop it before `mlxfwreset`/`mlxconfig`.
- `mlnx_qos --buffer_size` is not persistent (and not needed after the slot move); the unit in `install/network/` is reference only.
- `check_gpudirect.sh` FAILs for `esdk_mellanox_mode` and "preset on display GPU 0" are false positives on 4.08.05 / `PCI_BUS_ID`.
- `ffprobe` on a recording while orange is still writing → "moov atom not found"; wait for Stop.
- ASMedia/USB NIC `enx…` "Connection failed" GNOME toasts are unrelated to the camera ports.
