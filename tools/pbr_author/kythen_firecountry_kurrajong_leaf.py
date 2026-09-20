"""Kurrajong leaf: broader and shorter than the gum leaves, a lower aspect
ratio blade for Brachychiton's own broad, sometimes lobed leaf, a gentle
midrib rather than a bold one to match the bark's own smooth character."""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_kurrajong_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="blade", seed=3401, normal_strength=6.5,
            fine_n=500, fine_length=(7, 11), fine_width=(3.0, 4.5),
            coarse_n=200, coarse_length=(11, 15), coarse_width=(3.8, 5.2),
            midrib_amp=0.14)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
