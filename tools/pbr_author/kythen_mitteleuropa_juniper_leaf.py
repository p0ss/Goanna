"""Juniper leaf: tiny overlapping scale foliage rather than fir's flat
needles, so the family's two conifers do not read as the same material:
short, wide, densely scattered stamps angled every which way rather than
climbing one axis."""

import sys

import kythen_mitteleuropa_leaf_family as fam

STEM = "kythen_mitteleuropa_juniper_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="scale", seed=5301, normal_strength=7.0,
            fine_len=(2.0, 4.0), fine_wid=(1.2, 2.0), fine_n=2600,
            coarse_len=(4.0, 6.0), coarse_wid=(1.8, 2.8), coarse_n=900)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
