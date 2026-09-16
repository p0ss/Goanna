"""Manna gum bark: smooth with shed ribbons. Three shades only, and the
marks are the lighter two (0.643, 0.654) against a darker field (0.531),
16.8 percent of the tile, mcl_core_log_birch.py's own read but inverted:
this bark is dark with light ribbons standing off it, not pale with dark
pores sunk into it, so mask_brighter picks the light texels and sign is
positive, a ribbon stood proud rather than a lenticel pit."""

import sys

import kythen_bark_family as fam

STEM = "kythen_firecountry_manna_gum_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="lenticel", seed=1801, normal_strength=26.0,
            dark_thresh=0.59, mask_brighter=True, sign=1.0, warp_amp=3.0,
            edge_dist=6, base=0.45, mark_amp=0.25, grain_amp=0.10,
            grain_radius=8, pore_amp=0.02)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
