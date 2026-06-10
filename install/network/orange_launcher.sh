#!/usr/bin/env bash
# orange — launch the orange capture app with PTP running in the background.
#
# Starts ptp4l (PTP grandmaster) + phc2sys (clock discipline) as background
# daemons, waits for ptp4l to come up, then runs orange in the FOREGROUND.
# When orange exits — cleanly, via Ctrl-C, or on a crash — the PTP daemons are
# stopped automatically (a trap on EXIT/INT/TERM). No extra terminals; the PTP
# daemons log to files and this terminal just prints a status line.
#
# Install (version-controlled here; symlinked onto PATH as `orange`):
#   sudo ln -sf "$(pwd)/orange_launcher.sh" /usr/local/bin/orange
# then just run:  orange            (any args pass through to the orange binary)
#
# Overrides (env):
#   ORANGE_BIN=/path/to/orange      (default: $HOME/src/orange/release/orange)
#   ORANGE_LOGDIR=/path/to/logs     (default: $HOME/.orange/logs)
#
# Needs root for PTP + NIC access (sudo is used per-step, prompted once and
# cached). orange runs under `sudo -E` so root keeps your X session
# ($DISPLAY/$XAUTHORITY) and can draw the preview — same as running it by hand.
#
# Caveat: a `trap` cannot fire if this launcher is `kill -9`'d or the machine
# loses power mid-run; in that case the PTP daemons linger (re-running `orange`
# detects and reuses them). For crash-proof, self-healing PTP use systemd units
# instead.
#
# MACHINE-SPECIFIC: this launcher inherits ptp_start.sh's hard-coded NIC port
# list (`-i enpXXs0fYnpZ ...`), which is unique to the box it was written on.
# On a different machine those interface names won't exist and ptp4l won't come
# up (the launcher then errors out pointing at ptp4l.log instead of launching
# orange unsynced). Per box: run list_camera_nics.sh and edit the `-i` list in
# ptp_start.sh to match. (sync_NICs.sh's `phc2sys -a` is portable as-is.)

set -euo pipefail

ORANGE_BIN="${ORANGE_BIN:-$HOME/src/orange/release/orange}"
LOGDIR="${ORANGE_LOGDIR:-$HOME/.orange/logs}"

# Locate the PTP helper scripts: prefer the deployed copies on PATH/in /bin,
# else the repo copies sitting next to this launcher.
SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
find_script() {
    local name="$1" cand
    for cand in "/bin/$name" "/usr/local/bin/$name" "$SELF_DIR/$name"; do
        [[ -x "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
    done
    return 1
}
PTP_START="$(find_script ptp_start.sh)" || { echo "[orange] ERROR: ptp_start.sh not found" >&2; exit 1; }
SYNC_NICS="$(find_script sync_NICs.sh)" || { echo "[orange] ERROR: sync_NICs.sh not found" >&2; exit 1; }
[[ -x "$ORANGE_BIN" ]] || { echo "[orange] ERROR: orange binary not found at $ORANGE_BIN (set ORANGE_BIN=...)" >&2; exit 1; }

mkdir -p "$LOGDIR"

# Only tear down PTP daemons that WE started (don't kill a pre-existing/systemd one).
MANAGE_PTP=1
cleanup() {
    [[ "$MANAGE_PTP" == 1 ]] || return 0
    echo "[orange] stopping PTP (ptp4l + phc2sys)..."
    sudo pkill -x phc2sys 2>/dev/null || true
    sudo pkill -x ptp4l   2>/dev/null || true
}
trap cleanup EXIT INT TERM

if pgrep -x ptp4l >/dev/null || pgrep -x phc2sys >/dev/null; then
    echo "[orange] NOTE: ptp4l/phc2sys already running; reusing them and leaving them up on exit." >&2
    MANAGE_PTP=0
fi

sudo -v   # prompt for the password once; cache it so backgrounded sudos don't re-prompt

if [[ "$MANAGE_PTP" == 1 ]]; then
    echo "[orange] starting PTP grandmaster (ptp4l)...   log: $LOGDIR/ptp4l.log"
    setsid "$PTP_START" >"$LOGDIR/ptp4l.log" 2>&1 &

    # Wait (up to ~10s) for ptp4l to actually come up before disciplining the clock.
    for _ in {1..20}; do pgrep -x ptp4l >/dev/null && break; sleep 0.5; done
    if ! pgrep -x ptp4l >/dev/null; then
        echo "[orange] ERROR: ptp4l failed to start — see $LOGDIR/ptp4l.log" >&2
        exit 1
    fi

    echo "[orange] starting clock sync (phc2sys)...      log: $LOGDIR/phc2sys.log"
    setsid "$SYNC_NICS" >"$LOGDIR/phc2sys.log" 2>&1 &

    echo "[orange] PTP is running in the background; it stops automatically when orange exits."
    echo "[orange] watch sync live with:  tail -f $LOGDIR/phc2sys.log"
fi

echo "[orange] launching orange (preview window opens; pick your camera preset)..."
set +e
sudo -E "$ORANGE_BIN" "$@"
rc=$?
set -e
exit "$rc"   # EXIT trap runs cleanup() regardless of how orange ended
