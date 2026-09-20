"""Ash leaf: pinnate, many small narrow leaflets rather than one broad
blade, aspect 2.2 and small, with a higher count so the canopy is built
from many little stamps instead of a few big ones."""

import sys

import kythen_mitteleuropa_leaf_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_ash_leaf"
ASPECT = 2.2

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="broadleaf", seed=4301, normal_strength=8.0,
            fine_len=(3.0, 5.0), fine_wid=(3.0 / ASPECT, 5.0 / ASPECT), fine_n=1400,
            coarse_len=(6.0, 8.0), coarse_wid=(6.0 / ASPECT, 8.0 / ASPECT), coarse_n=500)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
