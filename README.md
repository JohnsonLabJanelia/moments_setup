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

The scripts consume an offline artifact payload (NVIDIA driver/CUDA, DOCA-OFED, Rivermax + license,
Emergent eSDK, prebuilt CUDA FFmpeg, TensorRT/cuDNN, app source) that travels on a USB drive — kept
**outside** this repo because it is ~13 GB of binaries and a node-locked license. See the payload's
own `README.md` for its manifest and version watch-items.

> Status: experimental. The scripts are statically checked and the app builds are verified on the
> reference machine, but the destructive driver/NIC steps are first executed on the new box.
