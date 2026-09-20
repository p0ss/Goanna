"""Cypress pine leaf: scale foliage. Callitris carries tiny appressed
scales rather than open needles, so this is the needle_stamp at a very
short, narrow size and a high count, closer set than nut pine's true
needles."""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_cypress_pine_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="needle", seed=4001, normal_strength=5.0,
            fine_n=2200, fine_length=(3.0, 5.0), fine_width=(0.8, 1.3),
            coarse_n=700, coarse_length=(5.0, 7.5), coarse_width=(1.2, 1.8))
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
