"""Paperbark leaf: small and narrow, a melaleuca style leaf, smaller than
the broad gum blades with a subtle midrib."""

import sys

import kythen_leaf_family as fam

STEM = "kythen_firecountry_paperbark_leaf"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="blade", seed=3701, normal_strength=6.5,
            fine_n=650, fine_length=(6, 10), fine_width=(1.5, 2.5),
            coarse_n=250, coarse_length=(10, 14), coarse_width=(2.0, 3.0),
            midrib_amp=0.12)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
