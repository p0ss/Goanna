"""Norse birch foliage: small lobed leaves.

32 px art, 13.8 percent alpha holes, a dithered green canopy the same kind
of drawing as mcl_core_leaves_big_oak.py and this game's own leaf family:
no single leaf outline to segment, a mass of small texels standing for a
canopy of tiny leaves seen face on. Birch leaves are small, roughly oval
with a light midrib, so this uses kythen_leaf_family's blade shape at a
small size, closer to kythen_firecountry_quandong_leaf.py's fine, slender
reading than beefwood's coarse one.
"""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_norse_birch_foliage"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="blade", seed=8401, normal_strength=6.5,
            fine_n=900, fine_length=(4.5, 7.0), fine_width=(2.2, 3.2),
            coarse_n=320, coarse_length=(7.0, 9.5), coarse_width=(2.8, 3.8),
            midrib_amp=0.12)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
