"""Wattle bark: smooth and lenticelled. Four shades, marks the three
darker ones against the lightest field, 29.2 percent of the tile, real
lenticel pores rather than the sparse birch reading: mask_brighter is
False (the marks are the dark side of the threshold) and sign is negative,
a pit sunk into an otherwise smooth trunk."""

import sys

import kythen_bark_family as fam

STEM = "kythen_firecountry_wattle_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="lenticel", seed=1901, normal_strength=12.0,
            dark_thresh=0.29, mask_brighter=False, sign=-1.0, warp_amp=3.0,
            edge_dist=6, base=0.60, mark_amp=0.35, grain_amp=0.10,
            grain_radius=8, pore_amp=0.02)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
