"""Norse pine bark: plated and scaly.

32 px art, dark overall (lum 0.089 to 0.306) with a busy, scattered
texture: no column is both dark and flat the way default_tree.py's oak
furrow needs (every column's own std sits between 0.017 and 0.095, and the
flattest columns, 29 and 30 at std 0.017, are among the brightest, not the
darkest, the same "flattest is brightest, not a furrow" read
kythen_habesha_fig_bark.py gives its own calm trunk). The dark texels
instead speckle the whole tile without a clean furrow or a clean column
read, which is kythen_bark_family's scaly mode: pine bark plates and
scales rather than grooves, the same read kythen_firecountry_nut_pine_bark.py
gives its own conifer.
"""

import sys

import kythen_bark_family as fam

GAME = "kythen"
STEM = "kythen_norse_pine_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="scaly", seed=8201, normal_strength=30.0,
            scale_count=130, scale_length=(3.0, 6.0), scale_width=(1.5, 2.6),
            grain_amp=0.08, crack_count=6, crack_len=(6, 16), crack_depth=0.9)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
