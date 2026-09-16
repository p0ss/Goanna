"""Birch bark: papery with lenticels. Three shades only (0.708, 0.786,
0.907), the great majority (650 of 1024 texels) the brightest paper tone,
with 0.786 and the rare 0.708 fleck sitting well below it: dark_thresh
0.85 catches both as marks, about 37 percent of the tile, matching the
mcl_core_log_birch.py read of scattered scars rather than a furrow.
mask_brighter is False and sign is negative: the marks are darker, sunk
pores, not a lighter proud ribbon."""

import sys

import kythen_mitteleuropa_bark_family as fam

STEM = "kythen_mitteleuropa_birch_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="lenticel", seed=2701, normal_strength=15.0,
            dark_thresh=0.85, mask_brighter=False, sign=-1.0, warp_amp=3.0,
            edge_dist=6, base=0.70, mark_amp=0.40, grain_amp=0.10, grain_radius=6,
            pore_amp=0.02, crack_count=3, crack_len=(6, 14), crack_depth=0.6)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
