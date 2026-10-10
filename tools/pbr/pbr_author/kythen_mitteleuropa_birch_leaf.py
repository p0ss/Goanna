"""Birch leaf: small triangular-ovate leaves, aspect 1.3 and noticeably
smaller than oak's, with a higher count to keep the canopy covered at
that smaller size."""

import sys

import kythen_mitteleuropa_leaf_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_birch_leaf"
ASPECT = 1.3

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="broadleaf", seed=4501, normal_strength=6.8,
            fine_len=(4.0, 6.0), fine_wid=(4.0 / ASPECT, 6.0 / ASPECT), fine_n=1100,
            coarse_len=(7.0, 10.0), coarse_wid=(7.0 / ASPECT, 10.0 / ASPECT), coarse_n=380)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
