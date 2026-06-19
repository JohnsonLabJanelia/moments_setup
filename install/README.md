# moments install scripts

Numbered, **idempotent**, **reboot-resumable** bash installers that bring up
`orange` (Phase 1) and `red` (Phase 2) on a fresh Ubuntu 22.04/24.04 Threadripper
Pro box, consuming the offline payload in `../moments_artifacts/`.

## Quick start

```bash
# 1. Plug in the USB and point the scripts at the payload (skip if it sits next to this repo)
export ARTIFACTS_DIR=/media/$USER/moments_artifacts

# 2. (recommended) dry read-only check first
./00_preflight.sh

# 3. Phase 1 — orange.  Re-run this same command after each requested reboot.
./install_phase1.sh

# 4. Phase 2 — red (after orange works)
./install_phase2.sh
```

> Run as your **normal user**, not root — the scripts `sudo` where needed and
> install user files into `~/nvidia`, `~/src`, `~/.local`.

> **Before the OS install**, do the at-the-keyboard hardware steps in
> [`BIOS_NIC_CHECKLIST.md`](BIOS_NIC_CHECKLIST.md) (Resizable BAR + Above-4G Decoding,
> Secure Boot off, NIC seating/firmware, jumbo frames, Rivermax node-lock). Scripts
> can't set those.

## Steps

| # | Script | Does | Reboot? |
|---|--------|------|---------|
| 00 | `00_preflight.sh` | read-only checks: OS, GPUs, payload, optional checksums | — |
| 05 | `05_kernel_check.sh` | gate: running kernel ≤ 6.8 so driver 535 can build (override `MOMENTS_ALLOW_KERNEL=1`) | — |
| 10 | `10_nvidia_driver.sh` | install headers, blacklist nouveau → **reboot** → install driver 535.183.06 → **reboot** | ×2 |
| 20 | `20_cuda.sh` | CUDA 12.2.2 toolkit (`--toolkit`, no bundled driver) | — |
| 30 | `30_emergent.sh` | eSDK 4.07 + DOCA-OFED (local deb via `-m`) + Rivermax + license + `nvidia_peermem` | rec. |
| 40 | `40_ffmpeg.sh` | prebuilt CUDA FFmpeg → `~/nvidia/ffmpeg` | — |
| 50 | `50_orange.sh` | GUI apt deps, extract+build orange, stage `~/orange_data` | — |
| 60 | `60_tensorrt_cudnn.sh` | TensorRT 8.6.1.6 → `~/nvidia`, cuDNN 8.9 → `/usr/local/cuda` | — |
| 70 | `70_red.sh` | apt deps (Eigen/Ceres/turbojpeg/…), extract+build `red` | — |

## Optional: desktop launchers

Once both apps run, install GNOME/desktop launchers (app-grid entries + icons, with
a `--pin` option for the dash) so users don't have to launch from a terminal:

```bash
cd desktop && ./install_launchers.sh --pin    # as your normal user, not sudo
```

See [`desktop/README.md`](desktop/README.md). orange opens in a terminal (it starts
PTP + runs under sudo); red launches its GUI directly.

## How resume works

Each step writes a marker to `~/.moments-setup/state/<step>.done` when it finishes
and skips itself if the marker exists. Steps that need a reboot exit with code 10;
the orchestrator prints what to do and stops. After `sudo reboot`, just run
`./install_phase1.sh` again — it fast-forwards past completed steps. Logs land in
`~/.moments-setup/logs/`.

To force a step to re-run: `rm ~/.moments-setup/state/<step>.done`.

## Config / overrides

All paths and pinned versions live in `config.env`; override anything via the
environment (e.g. `ARTIFACTS_DIR=…`, `SRC_PREFIX=…`, `MOMENTS_ASSUME_YES=1` to skip
prompts). See `../moments_artifacts/README.md` for the version watch-items
(eSDK 4.07 is verified build-compatible; DOCA deb is ubuntu2204-only; the Rivermax
license is node-locked to the NICs).

## Notes / known sharp edges

- **OS = 22.04 is the safe match.** On 24.04 you must supply the `ubuntu2404` DOCA
  deb and set `A_DOCA_DEB` (the staged one is 2204).
- **Internet:** small distro packages come from `apt`. The heavy NVIDIA/Emergent/
  Rivermax bits are all offline from USB. For a fully air-gapped box, pre-stage the
  apt `.deb`s — not yet automated.
- Steps 10/30 touch the driver and the NIC/IB stack — expect transient network/X
  disruption; that's why they're isolated and reboot-gated.
- These were authored and statically checked on the reference machine but **not
  executed** there (they're destructive) — first real run is the new box.
