"""Beefwood leaf: coarse. Fewer, bigger blades than the other gum leaves,
a bold midrib, read from Grevillea striata's own coarse linear foliage."""

import sys

import kythen_leaf_family as fam

STEM = "kythen_firecountry_beefwood_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="blade", seed=3101, normal_strength=7.0,
            fine_n=350, fine_length=(11, 16), fine_width=(3.0, 4.5),
            coarse_n=140, coarse_length=(16, 22), coarse_width=(4.0, 5.5),
            midrib_amp=0.20)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
