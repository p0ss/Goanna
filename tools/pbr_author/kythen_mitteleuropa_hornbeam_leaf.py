"""Hornbeam leaf: ovate with strong parallel side veins, aspect 1.6 like
elm's, with midrib_amp raised so the pronounced ribbing shows."""

import sys

import kythen_mitteleuropa_leaf_family as fam

STEM = "kythen_mitteleuropa_hornbeam_leaf"
ASPECT = 1.6

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="broadleaf", seed=4801, normal_strength=9.0,
            fine_len=(5.0, 8.0), fine_wid=(5.0 / ASPECT, 8.0 / ASPECT), fine_n=750,
            coarse_len=(9.0, 13.0), coarse_wid=(9.0 / ASPECT, 13.0 / ASPECT), coarse_n=260,
            midrib_amp=0.28)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
