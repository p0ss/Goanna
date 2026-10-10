"""Lime leaf: broad heart shaped, the family's roundest leaf, aspect
1.05."""

import sys

import kythen_mitteleuropa_leaf_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_lime_leaf"
ASPECT = 1.05

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="broadleaf", seed=4901, normal_strength=8.5,
            fine_len=(7.0, 10.0), fine_wid=(7.0 / ASPECT, 10.0 / ASPECT), fine_n=600,
            coarse_len=(11.0, 16.0), coarse_wid=(11.0 / ASPECT, 16.0 / ASPECT), coarse_n=220)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
