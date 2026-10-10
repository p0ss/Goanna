"""Nut pine leaf: true needle clusters, mcl_core_leaves_spruce.py's own
two layer proportions (a fine dense layer plus a sparser, longer one
underneath giving the sprig its body)."""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_nut_pine_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="needle", seed=4101, normal_strength=5.0,
            fine_n=2200, fine_length=(4.0, 7.0), fine_width=(1.0, 1.8),
            coarse_n=700, coarse_length=(7.0, 12.0), coarse_width=(1.6, 2.6))
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
