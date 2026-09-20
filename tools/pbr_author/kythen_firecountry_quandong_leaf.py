"""Quandong leaf: fine, small and numerous blades with a thin midrib, for
Santalum acuminatum's own slender foliage."""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_quandong_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="blade", seed=3801, normal_strength=6.5,
            fine_n=700, fine_length=(6, 10), fine_width=(1.5, 2.2),
            coarse_n=280, coarse_length=(10, 14), coarse_width=(1.9, 2.7),
            midrib_amp=0.12)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
