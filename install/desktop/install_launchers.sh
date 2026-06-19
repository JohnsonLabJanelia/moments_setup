#!/usr/bin/env bash
# install_launchers.sh — install GNOME/desktop launchers for `orange` and `red`.
#
# Creates ~/.local/share/applications/{orange,red}.desktop pointing at whatever
# `orange` / `red` resolve to on PATH (falling back to the in-repo launcher /
# the ~/.local/bin/red installed by red's own install.sh), installs the icons,
# and refreshes the desktop database. Optionally pins both to the GNOME dash.
#
# Run as the LOGGED-IN USER (no sudo) — these are per-user launchers.
#
# Usage:
#   ./install_launchers.sh            # install both launchers + icons
#   ./install_launchers.sh --pin      # also pin both to the GNOME dash (favorites)
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, NOT root/sudo (per-user launchers)." >&2; exit 1; }

PIN=0; [ "${1:-}" = "--pin" ] && PIN=1

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPDIR="$XDG_DATA_HOME/applications"
ICONDIR="$XDG_DATA_HOME/icons"
mkdir -p "$APPDIR" "$ICONDIR"

# --- icons ---
install -m 644 "$HERE/orange_icon.png" "$ICONDIR/orange_icon.png"
install -m 644 "$HERE/red_icon.png"    "$ICONDIR/red_icon.png"

# --- resolve the launcher commands ---
# orange: prefer `orange` on PATH (the /usr/local/bin/orange symlink), else the
# in-repo launcher. It starts PTP + runs orange under sudo, so Terminal=true.
ORANGE_EXEC="$(command -v orange || true)"
[ -n "$ORANGE_EXEC" ] || ORANGE_EXEC="$HERE/../network/orange_launcher.sh"
# red: prefer `red` on PATH; else the ~/.local/bin/red from red's install.sh.
RED_EXEC="$(command -v red || true)"
[ -n "$RED_EXEC" ] || RED_EXEC="$HOME/.local/bin/red"

echo "orange launcher: $ORANGE_EXEC"
echo "red launcher   : $RED_EXEC"
[ -e "${ORANGE_EXEC%% *}" ] || echo "  WARN: orange launcher not found yet (install network/orange_launcher.sh)"
[ -e "${RED_EXEC%% *}" ]    || echo "  WARN: red launcher not found yet (run red's install.sh)"

# --- orange.desktop (opens a terminal: shows PTP status, can prompt for sudo) ---
cat > "$APPDIR/orange.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.1
Name=Orange
GenericName=Multi-Camera Recorder
Comment=Start PTP and launch the orange multi-camera recorder
Exec=$ORANGE_EXEC
TryExec=${ORANGE_EXEC%% *}
Icon=$ICONDIR/orange_icon.png
Terminal=true
Categories=AudioVideo;Recorder;
Keywords=camera;record;capture;moments;
StartupNotify=true
StartupWMClass=orange
EOF

# --- red.desktop (offline labeling GUI; no PTP/sudo) ---
cat > "$APPDIR/red.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.1
Name=Red
GenericName=Keypoint Labeler
Comment=Open Red 3D keypoint-labeling projects
Exec=$RED_EXEC %f
TryExec=$RED_EXEC
Icon=$ICONDIR/red_icon.png
Terminal=false
Categories=Graphics;
Keywords=label;annotate;keypoint;jarvis;moments;
MimeType=application/x-red-project;
StartupNotify=true
StartupWMClass=red
EOF

command -v desktop-file-validate >/dev/null && {
  desktop-file-validate "$APPDIR/orange.desktop" && echo "orange.desktop valid"
  desktop-file-validate "$APPDIR/red.desktop"    && echo "red.desktop valid"
}
command -v update-desktop-database >/dev/null && update-desktop-database "$APPDIR" 2>/dev/null || true
echo "Installed launchers in $APPDIR"

# --- optional: pin to the GNOME dash (favorites) ---
if [ "$PIN" -eq 1 ]; then
  if command -v gsettings >/dev/null; then
    cur="$(gsettings get org.gnome.shell favorite-apps)"
    for app in orange.desktop red.desktop; do
      echo "$cur" | grep -q "'$app'" || cur="$(echo "$cur" | sed "s/]$/, '$app']/; s/^\[]/['$app']/")"
    done
    gsettings set org.gnome.shell favorite-apps "$cur" && echo "pinned to dash: $cur"
  else
    echo "gsettings not found — skip --pin (not a GNOME session?). Pin by hand from the app grid."
  fi
fi
