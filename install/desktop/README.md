# Desktop launchers (orange + red)

Per-user GNOME/freedesktop `.desktop` launchers so `orange` and `red` show up in
the app grid and can be pinned to the dash — instead of always launching from a
terminal.

Run **after** the apps are installed (orange built + `orange_launcher.sh`
symlinked on PATH as `orange`; red installed via its own `install.sh`, which puts
`red` on `~/.local/bin`). Run as your **normal user — not sudo** (these are
per-user launchers under `~/.local/share`).

```bash
./install_launchers.sh          # install both launchers + icons
./install_launchers.sh --pin    # also pin both to the GNOME dash (favorites)
```

What it does:

- copies `orange_icon.png` / `red_icon.png` into `~/.local/share/icons/`,
- writes `~/.local/share/applications/{orange,red}.desktop`, pointing `Exec=` at
  whatever `orange` / `red` resolve to on PATH (falling back to the in-repo
  `../network/orange_launcher.sh` and `~/.local/bin/red`),
- refreshes the desktop database, and (with `--pin`) appends both to
  `org.gnome.shell favorite-apps`.

### Launch behavior (intentional)

| App | `Terminal=` | Why |
|---|---|---|
| **orange** | `true` | the launcher starts PTP (ptp4l/phc2sys) and runs orange under `sudo -E`; a terminal shows PTP status and can prompt for the sudo password if passwordless sudo isn't configured |
| **red** | `false` | offline labeling — no PTP, no cameras, no sudo |

> `StartupWMClass` is set to `orange` / `red` so a running window groups under the
> pinned dash icon. If a *second* icon appears while the app runs, the real WM
> class differs — find it with `xprop WM_CLASS` (click the window) and fix the
> `StartupWMClass=` line.

## The icons

`orange_icon.png` is the lab's orange artwork (rat under three cameras).
`red_icon.png` is generated from it by `make_red_icon.py`: it recolors **only the
warm background** (light "peach" upper + orange floor) into a two-tone red, via a
luminance-preserving hue shift on warm pixels. The gray/white rat and the navy
camera bodies/lenses are left untouched (the cameras' orange accent rings shift to
red, matching the theme); anti-aliased edges shift with the background so there
are no halos. Needs only Pillow:

```bash
python3 make_red_icon.py orange_icon.png red_icon.png   # regenerate red from orange
```

The generated PNG is committed, so installs don't need Pillow — only re-run the
script if you change the source artwork.
