# moments_setup

Documentation and code for installing dependencies for the moments software stack
(`orange` capture + `red` labeling) on a fresh Ubuntu 22.04/24.04 Threadripper Pro machine —
so we can stop cloning Linux images with Clonezilla.

## Contents

- [`install/`](install/) — numbered, idempotent, reboot-resumable install scripts.
  - [`install/README.md`](install/README.md) — how to run them (Phase 1 = orange, Phase 2 = red).
  - [`install/BIOS_NIC_CHECKLIST.md`](install/BIOS_NIC_CHECKLIST.md) — the at-the-keyboard
    hardware steps a script can't do (Resizable BAR, Above-4G, Secure Boot, NIC/Rivermax).
  - [`install/config.env`](install/config.env) — pinned versions + artifact paths (single source of truth).

## Machine-specific field notes — **read these first for a real build**

The pinned `install/` scripts + `config.env` target the 22.04 / driver-535 / CUDA-12.2 **reference
machine** (`CLAUDE.md`). For a modern **Ubuntu 24.04** box, start with the notes that match your GPU —
they capture the exact working stack and every gotcha we hit:

- [`ADA_2404_NOTES.md`](ADA_2404_NOTES.md) — **24.04 + a modern pre-installed driver** (RTX 4000 Ada /
  driver 595 / CUDA 13.1). The easiest, mostly-headless path. Start here for most new machines.
- [`BLACKWELL_2404_NOTES.md`](BLACKWELL_2404_NOTES.md) — 24.04 + Blackwell GPU (driver 590 / CUDA 13.1).
- [`RED_2404_NOTES.md`](RED_2404_NOTES.md) — building `red` on 24.04 / CUDA 13.
- [`RED_A6000_2204_TENSORRT_NOTES.md`](RED_A6000_2204_TENSORRT_NOTES.md) — **`red` + JARVIS
  TensorRT on the A6000 / 22.04 / CUDA-12.2 reference box** (driver 595): annotation projects +
  the full JARVIS `.pth`→ONNX→TensorRT-8.6 engine runbook and Predict-tool wiring. Uses
  `moments-behavior/red` `xp`.

**Top lessons (24.04):** the precompiled `nvidia-peermem` is a no-op stub → rebuild via DKMS *after*
DOCA (`install/gpu-direct/fix_nvidia_peermem_dkms.sh`); driver 590 is gone from apt (transitional →
595, don't downgrade); validate the whole capture stack **headless** with `evttools` + `multistream -g`
before touching the GUI; cameras can keep their IPs (read-then-match the host ports). Details in the
notes above and `install/{gpu-direct,network}/README.md`.

The scripts consume an offline artifact payload (NVIDIA driver/CUDA, DOCA-OFED, Rivermax + license,
Emergent eSDK, prebuilt CUDA FFmpeg, TensorRT/cuDNN, app source) that travels on a USB drive — kept
**outside** this repo because it is ~13 GB of binaries and a node-locked license. See the payload's
own `README.md` for its manifest and version watch-items.

> Status: experimental. The scripts are statically checked and the app builds are verified on the
> reference machine, but the destructive driver/NIC steps are first executed on the new box.
