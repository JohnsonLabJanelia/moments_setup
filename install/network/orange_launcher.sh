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

# Per-daemon aware: ptp4l and phc2sys are checked/started independently, and on
# exit we tear down ONLY the ones THIS launcher started — a daemon that was
# already running (by hand or via systemd) is reused and left up untouched.
STARTED_PTP4L=0
STARTED_PHC2SYS=0
cleanup() {
    if [[ "$STARTED_PHC2SYS" == 1 || "$STARTED_PTP4L" == 1 ]]; then
        echo "[orange] stopping PTP daemon(s) this launcher started..."
    fi
    # pkill by name is safe here: we only set STARTED_*=1 when that daemon was
    # NOT already running, so the only instance alive is the one we launched.
    [[ "$STARTED_PHC2SYS" == 1 ]] && { sudo pkill -x phc2sys 2>/dev/null || true; }
    [[ "$STARTED_PTP4L"  == 1 ]] && { sudo pkill -x ptp4l   2>/dev/null || true; }
    return 0
}
trap cleanup EXIT INT TERM HUP

sudo -v   # prompt for the password once; cache it so backgrounded sudos don't re-prompt

# --- ptp4l (PTP grandmaster) ---
if pgrep -x ptp4l >/dev/null; then
    echo "[orange] ptp4l already running — reusing it (left up on exit)."
else
    echo "[orange] starting PTP grandmaster (ptp4l)...   log: $LOGDIR/ptp4l.log"
    # NOTE: do NOT setsid here. ptp_start.sh calls `sudo ptp4l` internally, and
    # sudo's cached credential (from the `sudo -v` above) is tied to this
    # terminal — setsid would detach the controlling TTY and sudo would fail
    # with "a terminal is required to read the password". Backgrounding with &
    # keeps the TTY; the daemon still isn't torn down by a stray Ctrl-C because
    # teardown is driven by the trap (and reused/external daemons live in
    # another session).
    "$PTP_START" >"$LOGDIR/ptp4l.log" 2>&1 &
    STARTED_PTP4L=1
    # Wait (up to ~10s) for ptp4l to actually come up before disciplining the clock.
    for _ in {1..20}; do pgrep -x ptp4l >/dev/null && break; sleep 0.5; done
    if ! pgrep -x ptp4l >/dev/null; then
        echo "[orange] ERROR: ptp4l failed to start — see $LOGDIR/ptp4l.log" >&2
        exit 1   # EXIT trap will clean up anything we started
    fi
fi

# --- phc2sys (discipline system clock to the NIC PHC) ---
# Reached only once ptp4l is confirmed up (pre-existing or just started).
if pgrep -x phc2sys >/dev/null; then
    echo "[orange] phc2sys already running — reusing it (left up on exit)."
else
    echo "[orange] starting clock sync (phc2sys)...      log: $LOGDIR/phc2sys.log"
    "$SYNC_NICS" >"$LOGDIR/phc2sys.log" 2>&1 &   # not setsid — see ptp4l note above
    STARTED_PHC2SYS=1
fi

if [[ "$STARTED_PTP4L" == 1 || "$STARTED_PHC2SYS" == 1 ]]; then
    echo "[orange] PTP daemon(s) started by this launcher will stop when orange exits."
fi
echo "[orange] watch sync live with:  tail -f $LOGDIR/phc2sys.log"

# orange loads its fonts via paths relative to the CWD (e.g.
# "fonts/forkawesome-webfont.ttf"), so it must run from the directory that
# contains fonts/ — otherwise the ForkAwesome icons (play/stop/record dots)
# render as question marks. Find that dir relative to the binary.
ORANGE_RUN_DIR="$(dirname "$ORANGE_BIN")"
for d in "$ORANGE_RUN_DIR" "$ORANGE_RUN_DIR/.."; do
    if [[ -d "$d/fonts" ]]; then ORANGE_RUN_DIR="$(cd "$d" && pwd)"; break; fi
done
cd "$ORANGE_RUN_DIR"

echo "[orange] launching orange (cwd: $ORANGE_RUN_DIR; log: $LOGDIR/orange.log)"
echo "[orange] (preview window opens; pick your camera preset)"
set +e
# tee so you see output live AND it's captured for debugging. PIPESTATUS[0] is
# orange's real exit code (tee's would always be 0). The log is written by tee
# running as your user, so it's user-owned.
sudo -E "$ORANGE_BIN" "$@" 2>&1 | tee "$LOGDIR/orange.log"
rc=${PIPESTATUS[0]}
set -e

# When launched from the desktop icon (which sets ORANGE_HOLD=1), the terminal
# is a throwaway gnome-terminal that auto-closes when this script exits — taking
# orange's shutdown printouts with it. Hold it open until a keypress so they stay
# visible. Plain CLI `orange` (ORANGE_HOLD unset) returns to your shell as before;
# either way the full output is saved to $LOGDIR/orange.log.
if [[ "${ORANGE_HOLD:-0}" == 1 && -t 0 ]]; then
    cleanup                              # stop our PTP daemons now, before we wait
    STARTED_PTP4L=0; STARTED_PHC2SYS=0   # make the EXIT-trap cleanup a no-op
    echo
    echo "[orange] exited (code $rc). Full output saved to: $LOGDIR/orange.log"
    read -rsn1 -p "[orange] Press any key to close this terminal..."
    echo
fi
exit "$rc"   # EXIT trap runs cleanup() regardless of how orange ended
