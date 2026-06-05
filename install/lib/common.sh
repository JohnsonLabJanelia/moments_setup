# =============================================================================
# common.sh — shared helpers for the moments install scripts. Source it AFTER
# config.env. Provides: logging, confirmation, idempotency state markers,
# artifact checks, and an across-reboot resume convention.
# =============================================================================

# Exit code a step uses to tell the orchestrator "I need a reboot, resume after".
REBOOT_RC=10

# ---- pretty logging ---------------------------------------------------------
_c_reset=$'\e[0m'; _c_blue=$'\e[1;34m'; _c_grn=$'\e[1;32m'; _c_yel=$'\e[1;33m'; _c_red=$'\e[1;31m'
log()  { printf '%s[*]%s %s\n' "$_c_blue" "$_c_reset" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$_c_grn"  "$_c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$_c_yel"  "$_c_reset" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$_c_red"  "$_c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────"; }

# ---- confirmation (skipped when MOMENTS_ASSUME_YES=1) -----------------------
confirm() {
  local prompt="${1:-Proceed?}"
  [ "${MOMENTS_ASSUME_YES:-0}" = "1" ] && return 0
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- requirements -----------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_not_root() {
  # These scripts call sudo internally; running the whole thing as root would
  # install user files (~/nvidia, ~/.local) into /root by mistake.
  [ "$(id -u)" -ne 0 ] || die "do not run as root / with sudo — run as your normal user (it will sudo where needed)"
}

require_artifact() {
  local p="$1"
  [ -e "$p" ] || die "missing artifact: $p
  → check ARTIFACTS_DIR (currently: $ARTIFACTS_DIR) and that the USB is mounted."
}

# ---- idempotency state markers ---------------------------------------------
# A step calls `is_done <name> && return 0` at the top, and `mark_done <name>`
# at the end. Markers persist in MOMENTS_STATE_DIR so re-running the
# orchestrator (e.g. after a reboot) skips finished steps.
_state_init() { mkdir -p "$MOMENTS_STATE_DIR" "$MOMENTS_LOG_DIR"; }
is_done()   { _state_init; [ -f "$MOMENTS_STATE_DIR/$1.done" ]; }
mark_done() { _state_init; date -u +%FT%TZ > "$MOMENTS_STATE_DIR/$1.done"; ok "step complete: $1"; }
unmark()    { rm -f "$MOMENTS_STATE_DIR/$1.done"; }

# ---- reboot handshake -------------------------------------------------------
request_reboot() {
  warn "$*"
  warn "REBOOT REQUIRED. After the machine comes back, re-run the same orchestrator"
  warn "(./install_phase1.sh) — completed steps are skipped automatically."
  exit "$REBOOT_RC"
}

# ---- step preamble ----------------------------------------------------------
# Usage at top of each NN_*.sh:  step_begin "30_emergent" "Emergent eSDK + DOCA + Rivermax"
step_begin() {
  STEP_NAME="$1"; STEP_DESC="${2:-$1}"
  hr; log "STEP $STEP_NAME — $STEP_DESC"; hr
  require_not_root
}

# ---- helpers ----------------------------------------------------------------
extract_zst() { # <tarball.zst> <dest-dir>
  need_cmd zstd; mkdir -p "$2"
  zstd -d -c "$1" | tar -xf - -C "$2"
}
