"""Oak leaf: a canopy of rounded, lightly lobed leaves, aspect 1.3, the
same broad proportions mcl_core_leaves_big_oak.py's own lobe scatter was
built for."""

import sys

import kythen_mitteleuropa_leaf_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_oak_leaf"
ASPECT = 1.3

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="broadleaf", seed=4101, normal_strength=8.5,
            fine_len=(6.0, 9.0), fine_wid=(6.0 / ASPECT, 9.0 / ASPECT), fine_n=700,
            coarse_len=(10.0, 15.0), coarse_wid=(10.0 / ASPECT, 15.0 / ASPECT), coarse_n=260)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
