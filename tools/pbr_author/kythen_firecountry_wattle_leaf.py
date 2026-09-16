"""Wattle leaf: fine feathery. Many small, slender leaflets rather than
one or two broad blades, the needle_stamp again at a smaller size and a
much higher count than either pine, for a bipinnate foliage's own fine
grain."""

import sys

import kythen_leaf_family as fam

STEM = "kythen_firecountry_wattle_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="needle", seed=4201, normal_strength=5.0,
            fine_n=2800, fine_length=(2.5, 4.5), fine_width=(0.8, 1.4),
            coarse_n=900, coarse_length=(4.5, 7.0), coarse_width=(1.2, 2.0))
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
