# Camera network + PTP setup

Post-install configuration for the Emergent cameras: per-port static IPs with jumbo
frames, and a PTP grandmaster so the cameras share a clock. Run these **after** the
EVT stack (step 30) is installed and the ConnectX NIC(s) are seated.

> ⚠ **Interface names are machine-specific.** `enpXXs0fYnpZ` names come from PCI bus
> position and change whenever you add/remove a PCIe card (NIC *or* GPU). Always run
> `list_camera_nics.sh` first and edit the scripts to match. (On the June-2026 build,
> the two ConnectX-7s enumerated as `enp33s0f0..3` and `enp241s0f0..3`; an Intel i40e
> at `enp209` is **not** a camera NIC.)

## Topology

One camera per ConnectX port, each port on its own `/24`: **host = `.20`, camera = `.21`**,
**MTU 9000** (required by Emergent streaming), no default route. Distinct subnets per
port are mandatory — overlapping subnets break routing and GigE Vision discovery.

| Port (example) | Host IP | Camera IP |
|---|---|---|
| `enp33s0f0np0` | `192.168.30.20/24` | `192.168.30.21` |
| `enp33s0f1np1` | `192.168.31.20/24` | `192.168.31.21` |
| … | `192.168.3X.20/24` | `192.168.3X.21` |
| `enp241s0f0np0` | `192.168.40.20/24` | `192.168.40.21` |
| … | `192.168.4X.20/24` | `192.168.4X.21` |

## Steps

```bash
# 1. Discover this machine's ConnectX camera ports + PHCs
./list_camera_nics.sh

# 2. Configure IPs/MTU on all camera ports (edit the MAP inside to match step 1).
#    Idempotent; leaves already-active ports untouched; uncabled ports activate
#    when a camera is plugged in. (For a single port you can use ethernet_setup.sh.)
sudo ./configure_camera_ports.sh

# 3. In eCapture (or orange), set each camera's PERSISTENT IP to .21 on its subnet.

# 4. PTP — install once, then run before every capture/record session:
sudo apt install -y linuxptp
sudo cp ptp4l.conf /etc/ptp4l.conf
sudo install -m 755 ptp_start.sh sync_NICs.sh /bin/
#    Terminal A (grandmaster; edit the -i port list to match step 1):
sudo /bin/ptp_start.sh
#    Terminal B (discipline the system clock to the NIC PHC):
sudo /bin/sync_NICs.sh
```

> 💡 **You usually don't need to run PTP by hand** — use the `orange` launcher below,
> which starts both daemons in the background and stops them when orange exits.

Success looks like: `ptp4l` reaches **MASTER** ("assuming the grand master role"),
`phc2sys` offset converges to a small stable value, and each camera's **PtpStatus →
Slave** with **PtpOffset ≈ 0**.

## Read-then-match — `match_camera_ports.sh` (headless, one command)

Instead of forcing new IPs onto the cameras, **keep the cameras' existing persistent IPs and
set each host port to match**. One script does the whole discover → derive → configure loop —
no GUI, no per-camera write, no hand-editing a MAP:

```bash
sudo ./match_camera_ports.sh           # DRY RUN: print the discovered camera -> port -> subnet plan
sudo ./match_camera_ports.sh --apply   # configure the ports (persistent nmcli profiles) + verify
```

It runs `evttools -d -o b` (broadcast discovery works **before** the host IPs match, and the
camera replies on the wire it's cabled to), reads each camera's IP + serial + the port it's on
(the `on:` host IP), and sets that port onto the camera's `/24` (host `.20` by default, MTU 9000,
no default route). Env overrides: `HOST_OCTET`, `MTU`. Output looks like:

```
IFACE            HOST_IP            CAMERA_IP        SERIAL
enp225s0f0np0    192.168.110.20/24  192.168.110.23   2012861
enp9s0f0np0      192.168.150.20/24  192.168.150.23   2012853
...
```

<details><summary>Doing it by hand instead (what the script automates)</summary>

```bash
# 1. Discover: camera IP + serial + which host port it's on:
sudo LD_LIBRARY_PATH=/opt/EVT/eSDK/lib /opt/EVT/eSDK/tools/evttools -d -o b
#    -> "Camera 00: 192.168.110.23 (sn 2012861 ...) on: 192.168.40.20"  (host IP = that port)
# 2. Map that host IP to its interface (`ip -br addr`), set the interface to the camera's /24
#    (host .20) via configure_camera_ports.sh's MAP (or nmcli directly), then `nmcli connection up`.
# 3. Confirm: ping each camera's .23, and re-run evttools — each cam now "on:" its own subnet.
```
</details>

## Validate streaming headless (no GUI, no monitor)

Prove the whole NIC → DOCA → Rivermax → eSDK → camera path — and GPU-Direct — before opening orange:

```bash
cd /opt/EVT/eSDK/tools; export LD_LIBRARY_PATH=/opt/EVT/eSDK/lib
sudo -E ./multistream -n ^ -c <N>          # stream N cams host-staged.  watch: f:21/21 d:0 m:0
sudo -E ./multistream -n ^ -c <N> -g 0     # same but GPU-Direct into GPU0 (hard-aborts if peermem/IOMMU wrong)
```
`-n ^` groups all cameras regardless of IP (quick test). `f:21/21 d:0 m:0` = received/expected, 0 dropped, 0 missed.

## ⚠ orange requires PTP running to RECORD

orange reads `PtpOffset` from the camera every frame (it feeds the per-frame metadata
CSV) and sets `PtpMode=TwoStep` on record. With **no grandmaster running**, that read
throws inside the EVT SDK and **hangs orange on stop** — even with a single camera.
So always start `ptp_start.sh` + `sync_NICs.sh` before recording. (Preview-only works
without PTP.) See the known-issues list in `../../BLACKWELL_2404_NOTES.md`.

## Convenience: the `orange` launcher

`orange_launcher.sh` wraps the whole "start PTP, then run orange" dance into one
command so day-to-day users don't have to manage PTP terminals:

```bash
# install once (symlink onto PATH as `orange`):
sudo ln -sf "$PWD/orange_launcher.sh" /usr/local/bin/orange
# then, every session, just:
orange                 # extra args pass through to the orange binary
```

What it does: starts `ptp4l` + `phc2sys` as **background** daemons (logging to
`~/.orange/logs/{ptp4l,phc2sys}.log`), waits for `ptp4l` to come up, prints a one-line
status, then runs orange in the foreground under `sudo -E`. When orange exits — cleanly,
on Ctrl-C, or on a crash — a `trap` stops the daemons. No extra terminals; watch sync
live with `tail -f ~/.orange/logs/phc2sys.log`.

It is **per-daemon aware**: `ptp4l` and `phc2sys` are checked/started independently, so
if only one is already running it starts just the missing one. On exit it stops **only
the daemons it started** — anything you started by hand (or via systemd) is reused and
left running untouched.

Overrides: `ORANGE_BIN=…` (default `~/src/orange/release/orange`), `ORANGE_LOGDIR=…`.
Caveat: a `trap` can't fire on `kill -9` / power loss — for crash-proof, self-healing PTP
use systemd units instead.

⚠ **Machine-specific.** The launcher inherits `ptp_start.sh`'s hard-coded `-i` NIC port
list (see the interface-names warning at the top of this README), so on a *different* box
`ptp4l` won't start until you edit that list to match `list_camera_nics.sh`. The launcher
fails loudly in that case (prints a `ptp4l failed to start` error pointing at the log)
rather than running orange without sync. `sync_NICs.sh` (`phc2sys -a`) is portable as-is.

## Files

| File | What it does |
|---|---|
| `list_camera_nics.sh` | List NIC ports + driver + PHC; flags the ConnectX camera NICs |
| `ethernet_setup.sh` | Configure **one** port (args: iface, CIDR, conn-name, MTU) |
| `configure_camera_ports.sh` | Configure **all** camera ports in one pass (edit MAP by hand) |
| `match_camera_ports.sh` | **Auto** read-then-match: discover cameras (`evttools`) → set each port to its camera's subnet (no MAP editing) |
| `ptp4l.conf` | `ptp4l` config (boundary clock across NIC ports) → `/etc/ptp4l.conf` |
| `ptp_start.sh` | Run host as PTP grandmaster on the camera ports → `/bin/` |
| `sync_NICs.sh` | `phc2sys -a -rr -m` (system clock ↔ NIC PHC) → `/bin/` |
| `orange_launcher.sh` | One-command launcher: bg PTP + foreground orange, auto-teardown → symlink `/usr/local/bin/orange` |
