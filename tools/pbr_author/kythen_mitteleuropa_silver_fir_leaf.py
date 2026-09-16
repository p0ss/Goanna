"""Silver fir leaf: flat needles, mcl_core_leaves_spruce.py's own needle
construction, slightly shorter than spruce's since fir needles are
flatter and a touch shorter."""

import sys

import kythen_mitteleuropa_leaf_family as fam

STEM = "kythen_mitteleuropa_silver_fir_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="needle", seed=5201, normal_strength=6.0,
            fine_len=(4.0, 6.5), fine_wid=(1.0, 1.7), fine_n=2000,
            coarse_len=(6.5, 10.0), coarse_wid=(1.5, 2.4), coarse_n=650)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
