"""Willow leaf: narrow lanceolate, the family's most elongated leaf,
aspect 3.2, with a higher count so the narrow blades still cover the
canopy."""

import sys

import kythen_mitteleuropa_leaf_family as fam

STEM = "kythen_mitteleuropa_willow_leaf"
ASPECT = 3.2

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="broadleaf", seed=5101, normal_strength=8.0,
            fine_len=(6.0, 9.0), fine_wid=(6.0 / ASPECT, 9.0 / ASPECT), fine_n=900,
            coarse_len=(10.0, 14.0), coarse_wid=(10.0 / ASPECT, 14.0 / ASPECT), coarse_n=320)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
