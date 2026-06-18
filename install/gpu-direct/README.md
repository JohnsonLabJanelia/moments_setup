# GPU Direct (Rivermax RDMA → GPU memory)

GPU Direct lets the ConnectX NIC DMA camera frames **straight into GPU memory** (no host
bounce), so debayer + NVENC run on data the camera delivered directly. It's an
optimization — the host-staged path (`gpu_direct: false`) works fine at 20 fps / 0 drops —
but it cuts host memory-bandwidth/CPU, which matters at 8 high-res cameras.

**Validated June 2026** on the Blackwell/24.04 box: 8192×7000 HEVC, 0 dropped frames,
camera DMA-ing into an A16 die while the Blackwell drives the display.

## Requirements (all three, in addition to a working host-streaming setup)

GPU Direct fails at `EVT_CameraOpenStream()` (ENOENT / hard abort) unless **all** of these
are satisfied. Each was a separate gotcha on this box:

1. **`nvidia_peermem` loaded** — the NIC↔GPU memory bridge. Use EVT's own init script
   (already placed by the eSDK installer at `/etc/init.d/start-nvidia-peermem`):
   ```bash
   sudo update-rc.d start-nvidia-peermem defaults     # load on boot
   sudo /etc/init.d/start-nvidia-peermem start         # load now
   lsmod | grep -i peermem                             # expect: nvidia_peermem ... 0
   ```
   (Note: the module name has an underscore — `lsmod | grep nvidia-peermem` with a dash
   matches nothing.)

   ⚠ **If `modprobe nvidia_peermem` fails with `Invalid argument` (EINVAL) and no dmesg:**
   Ubuntu's **precompiled** `linux-modules-nvidia-NNN-open` ships `nvidia-peermem.ko` as a
   **no-op stub** (built with no MOFED/IB peer-memory headers — `nm` shows none of
   `nvidia_p2p_*` / `ib_register_peer_memory_client`), so its init just returns EINVAL. This is
   **not** a driver↔DOCA version mismatch. Fix: rebuild the driver via DKMS *after* DOCA is
   installed so peermem is compiled MOFED-aware:
   ```bash
   sudo ./fix_nvidia_peermem_dkms.sh    # installs nvidia-dkms-NNN-open, dkms install --force,
                                        # removes the precompiled flavour, verifies, then reboot
   ```
   Loaded-and-registered looks like `ib_uverbs ... N nvidia_peermem,...` in `lsmod`.
   Do **not** use the EVT-bundled `nvidia-peer-memory 1.1` (`nv_peer_mem`) — it's too old for
   modern drivers (its `nvidia_p2p_*` symbol CRCs disagree) and won't load.

2. **IOMMU disabled** — EVT readme: *"IOMMU must be disabled for GPU-Direct"* (it's
   optional for host streaming). With it on, the NIC↔GPU P2P DMA is blocked → ENOENT.
   ```bash
   ./disable_iommu.sh        # edits /etc/default/grub (amd-iommu=on iommu=pt -> amd_iommu=off), reboots
   # verify after reboot:  ls /sys/kernel/iommu_groups | wc -l   # expect 0
   ```
   ⚠ The sed targets *this box's* exact cmdline string. On a different machine, check
   `cat /proc/cmdline` and adjust (if no `amd-iommu=...` is present, *add* `amd_iommu=off`
   to `GRUB_CMDLINE_LINUX_DEFAULT` instead).

3. **`libcudart.so.12` present** — only needed if you run **CUDA 13** (Blackwell path).
   The eSDK 4.07 GPUDirect libs (`libEmergentGPUDirect.so`, `libEmergentP2PGPU.so`) have a
   hard `NEEDED: libcudart.so.12` (built against CUDA 12). CUDA 13 ships `libcudart.so.13`,
   so the CUDA-12 runtime is missing. Install it alongside CUDA 13 (they coexist — orange
   keeps using `.so.13`):
   ```bash
   ./install_cuda12_cudart.sh    # installs cuda-cudart-12-x, symlinks libcudart.so.12, ldconfig
   ```
   On the CUDA-12.2 reference machine this step is unnecessary (`libcudart.so.12` is already
   present). Confirm a lib's CUDA-version pin with:
   `readelf -d /opt/EVT/eSDK/lib/libEmergentGPUDirect.so | grep cudart`

## Enabling it in orange

Set `"gpu_direct": true` in the camera's config JSON (`gpu_id` = the A16 die to DMA into;
A16/Ampere is a supported GPUDirect GPU and needs a full BAR1 — ReBAR/Above-4G on).
orange sets `camera->gpuDirectDeviceId = gpu_id` before `EVT_CameraOpen`; the SDK does the
rest. Run with PTP as usual.

## Topology note

On this AMD WRX90, `nvidia-smi topo -m` shows every GPU↔NIC link as `NODE` (across the I/O
fabric, no shared PCIe switch). GPU Direct still works with IOMMU disabled, because the NIC
then DMAs to the GPU's physical BAR addresses directly. There's no "closest" GPU to pick.

## Debugging a GPU Direct failure

If `EVT_CameraOpenStream()` aborts with `Driver API error = 0002 (ENOENT)`, find the exact
missing file:
```bash
sudo -E strace -f -e trace=openat -e status=failed ./release/orange 2>/tmp/o.log
tail -30 /tmp/o.log     # the ENOENT openat right before the abort is the culprit
```
