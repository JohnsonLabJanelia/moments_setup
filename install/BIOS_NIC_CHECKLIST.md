# BIOS / NIC / hardware pre-flight checklist

The parts a script **can't** do — done at the keyboard, mostly *before* and *around* the
OS install. Target hardware: Threadripper PRO 9000-series (WRX90-class board), 2× NVIDIA
A16 + 1× A4000, 2× quad-port NVIDIA **ConnectX** 25 GbE NICs (Emergent). Plan: **Ubuntu 24.04**
(machine ships with it) on the **GA 6.8 kernel**; 22.04 is the lower-risk alternative.

Reference values below are what the known-good machine shows — match them.

---

## A. Physical (power off, case open)

- [ ] Both **A16** cards + the **A4000** seated; all PCIe power cables connected.
- [ ] Both **ConnectX** NICs seated in **CPU-direct x16/x8** slots (not chipset slots — camera
      streaming needs full bandwidth). On the reference box these enumerate as
      **ConnectX-6 (MT28908)** and **ConnectX-7 (MT2910)**.
- [ ] Camera transceivers/cables (25 G, fiber or DAC) in the NIC ports; check port LEDs after boot.
- [ ] Boot/OS drive is an SSD/NVMe; data-recording drive present (recording is bandwidth-heavy).

---

## B. BIOS settings  ← the core of this checklist

Enter BIOS (Del/F2 at power-on). Set, save, reboot.

### Mandatory for GPU-Direct / camera streaming
- [ ] **Above 4G Decoding** → **Enabled**  *(mandatory — Rivermax/GPU-Direct will not work without it)*
- [ ] **Re-Size BAR Support / Resizable BAR** → **Enabled**
      *(A16 supports it; without it BAR1 falls back to 256 MB and only ~1 camera can stream)*
- [ ] **SR-IOV** → **Enabled** if present *(ConnectX/DOCA expects it; harmless if your flow doesn't use VFs)*

### Driver / module signing
- [ ] **Secure Boot** → **Disabled**
      *(the NVIDIA `.run` driver and DOCA/DKMS kernel modules are unsigned — Secure Boot will
      block them, or force MOK enrollment. Disabling is the clean path.)*
- [ ] **Boot mode** → **UEFI**; **CSM / Legacy** → Disabled.

### Platform / performance (recommended, not blocking)
- [ ] **PCIe link speed** → Auto/Gen4+ for the NIC and GPU slots.
- [ ] **NUMA / NPS** → leave default (NPS1 is typical) unless EVT advises otherwise.
- [ ] **IOMMU / AMD-Vi** → default. *(The reference box runs with IOMMU **not** forced on and no
      hugepages set in the kernel cmdline — Rivermax here doesn't need them. Only revisit if EVT
      support says so.)*
- [ ] Power profile → Performance / disable deep C-states if you later chase latency.
- [ ] **Update BIOS to the latest** if Resizable BAR or Above-4G toggles are missing.

> Note: the reference machine boots with `pci=realloc=off` on the kernel cmdline (helps BAR
> allocation on multi-GPU boards). Keep that in mind if BAR1 doesn't come up at full size — see §G.

---

## C. First-boot verification (after Ubuntu install, after driver step 10)

- [ ] GPUs all visible:
      ```bash
      nvidia-smi --query-gpu=index,name,driver_version,compute_cap --format=csv
      ```
      Expect 2×A16 → **8** GPU dies (compute 8.6) + 1×A4000 (8.6), driver **535.183.06**.
- [ ] **Resizable BAR actually took effect** (the whole point of §B):
      ```bash
      nvidia-smi -q | grep -A3 -i "BAR1 Memory Usage"      # Total should be ~16 GB per A16, NOT 256 MB
      ```
      If BAR1 Total ≈ 256 MiB, ReBAR is **not** active → revisit BIOS (§B) and §G.

---

## D. NIC / fabric verification (after the Emergent step 30: DOCA-OFED + Rivermax)

- [ ] ConnectX cards present:
      ```bash
      lspci | grep -i mellanox          # expect ConnectX-6 (MT28908) and ConnectX-7 (MT2910)
      ```
- [ ] OFED/DOCA stack healthy:
      ```bash
      ofed_info -s                      # expect OFED-internal-25.04-… (DOCA 3.0.0)
      sudo mst start && mst status      # lists /dev/mst/mt* devices
      ibstat                            # ports present
      ```
- [ ] **NIC firmware** current (artifacts: `30_emergent/firmware/nic_port_fw_3.06/`):
      ```bash
      sudo mlxfwmanager                 # shows running vs available FW
      # if EVT firmware is newer, flash it, then:  sudo mlxfwreset -d <dev> -y r   (or reboot)
      ```
- [ ] **Interface names** — ⚠ gotcha. The reference box renames ports to `mlnx{1,2}_p{1..4}_25g`
      via **MAC-based udev rules**. Your new NICs have **different MACs**, so those rules won't
      match and the ports will appear under default names:
      ```bash
      ip -br link | grep -iE 'mlnx|en|eth'
      ```
      Decide one: (a) re-create the udev rules for the new MACs to keep the `mlnx*_25g` names, or
      (b) accept default names and update any camera/network config that referenced the old names.
- [ ] **Jumbo frames + IP** on each camera-facing port (high-rate GigE Vision needs MTU 9000):
      ```bash
      sudo ip link set <ifname> mtu 9000
      sudo ip addr add <host_ip>/<mask> dev <ifname>    # subnet must match the cameras' subnet
      ```
      (orange sets camera IPs via `EVT_ForceIPEx`; the host port must be on the same subnet.)
- [ ] **Rivermax** licensed and loadable:
      ```bash
      ls -l /opt/mellanox/rivermax/rivermax.lic         # present (step 30 copied it)
      dpkg -l | grep -i rivermax                         # 1.70.32
      ```
      ⚠ Rivermax licenses are **node-locked to the NIC**. Confirm with Emergent that this `.lic`
      covers **this** machine's ConnectX serials/MACs — otherwise streaming won't license.
- [ ] **GPU-Direct peer memory** loaded:
      ```bash
      lsmod | grep nvidia_peermem        # should be listed (step 30 loads it)
      ```

---

## E. Cameras

- [ ] Cameras powered and linked (port LEDs up).
- [ ] Discoverable from the host:
      ```bash
      /opt/EVT/eCapture/eCapture          # GUI: cameras should enumerate
      ```
- [ ] **Camera firmware** matches the SDK if eCapture flags a mismatch (artifacts:
      `30_emergent/firmware/camera_fw_3_85/`, `HB_IMX4xx_3_70.bin`). Flash via eCapture.
- [ ] Confirm each camera's serial matches a config preset in `~/orange_data/config/<preset>/<serial>.json`.

---

## F. PTP time sync (for multi-camera frame alignment)

- [ ] `ptp4l` / `phc2sys` present (installed with linuxptp; orange drives sync per-run).
- [ ] ConnectX hardware-PTP capable:
      ```bash
      ethtool -T <ifname> | grep -i 'PTP Hardware Clock'   # should report a PHC index
      ```
- [ ] If running a grandmaster/boundary clock, configure `ptp4l` on the camera-facing port and
      `phc2sys` to discipline the system clock. (Single-host multi-cam: orange aligns on PTP +
      host timestamps written to the per-camera `_meta.csv`.)

---

## G. Troubleshooting quick-reference

| Symptom | Likely cause / fix |
|---|---|
| `nvidia-smi` BAR1 Total ≈ 256 MB | ReBAR/Above-4G off in BIOS → enable (§B). If still small on a multi-GPU board, try kernel `pci=realloc=off` (reference uses it) or update BIOS/VBIOS. As a last resort use NVIDIA **DisplayModeSelector** to force 8 GB BAR1 (see `10_nvidia/readme_cuda_12.txt`). |
| Driver build/load fails after install | Secure Boot still on → disable (§B). Or nouveau still loaded → confirm `lsmod \| grep nouveau` is empty (step 10 blacklists it). |
| `ofed_info`/`ibstat` missing or NICs absent | DOCA-OFED didn't install (step 30) or NIC in a chipset slot → move to CPU-direct slot; re-run step 30. |
| Rivermax "license not found / invalid" | `.lic` missing at `/opt/mellanox/rivermax/` or **node-lock mismatch** for the new NIC MACs → get a license bound to this machine from Emergent. |
| Cameras don't enumerate in eCapture | Host port not on the camera subnet, MTU not 9000, link down, or interface renamed (§D). |
| Streaming drops frames / low throughput | Jumbo frames not set, ReBAR off, or NIC on insufficient PCIe lanes. |

---

### Order of operations (how this interleaves with the install scripts)

1. **§A physical → §B BIOS** (before OS).
2. Install/boot Ubuntu 24.04 (GA 6.8 kernel), copy the USB payload, run `./00_preflight.sh`.
3. `./install_phase1.sh` (driver → CUDA → Emergent/DOCA/Rivermax → FFmpeg → orange),
   re-running after each reboot it asks for.
4. **§C** after the driver step, **§D–§F** after the Emergent step (step 30).
5. Launch `sudo orange`, load a camera config preset, confirm a live stream.
