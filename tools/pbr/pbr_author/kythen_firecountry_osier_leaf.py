"""Osier leaf: smooth and slender, a high aspect ratio blade (long and
narrow, a willow style leaf) with a thin midrib."""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_osier_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="blade", seed=3601, normal_strength=6.5,
            fine_n=500, fine_length=(11, 17), fine_width=(1.2, 2.0),
            coarse_n=180, coarse_length=(17, 23), coarse_width=(1.6, 2.4),
            midrib_amp=0.15)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
