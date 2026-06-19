#!/usr/bin/env python3
"""Generate the red `red` icon from the orange `orange` icon.

Keeps the rat and the cameras exactly as-is and recolors only the *warm*
background (the light "peach" upper area + the orange floor) into a two-tone
red. Works by a luminance-preserving hue shift applied to warm pixels only
(R >= G >= B with a clear warm cast), so:

  * the gray/white rat and the navy camera bodies/lenses are untouched
    (they're not warm), and
  * anti-aliased edges shift smoothly with the background -> no halos.

The cameras' orange accent rings are warm, so they become red too, which keeps
the icon coherent with the red theme.

Usage:
    python3 make_red_icon.py [SRC=orange_icon.png] [DST=red_icon.png]

Only needs Pillow (no numpy). Re-run this if you change the source icon.
"""
import sys
import colorsys
from PIL import Image

SRC = sys.argv[1] if len(sys.argv) > 1 else "orange_icon.png"
DST = sys.argv[2] if len(sys.argv) > 2 else "red_icon.png"

TARGET_H = 0.015   # hue ~5deg: a true red leaning slightly warm
SAT_MIN = 0.62     # force a clearly-red result, not washed-out pink
DEEPEN = 0.82      # scale lightness down so it reads "red", not "salmon"

im = Image.open(SRC).convert("RGBA")
W, H = im.size
px = im.load()
out = im.copy()
o = out.load()

for y in range(H):
    for x in range(W):
        r, g, b, a = px[x, y]
        if a == 0:
            continue
        # warm family: peach, orange, and their dark edge blends
        if r >= g >= b and (r - b) > 25:
            h, l, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
            nl = l * DEEPEN
            ns = min(1.0, max(s, SAT_MIN))
            nr, ng, nb = colorsys.hls_to_rgb(TARGET_H, nl, ns)
            o[x, y] = (int(nr * 255 + 0.5), int(ng * 255 + 0.5), int(nb * 255 + 0.5), a)

out.save(DST)
print(f"wrote {DST}  (upper bg {o[120, 120][:3]}, floor {o[256, 470][:3]})")
