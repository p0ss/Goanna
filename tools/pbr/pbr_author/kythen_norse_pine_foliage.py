"""Norse pine foliage: needle clusters.

32 px art, 11.9 percent alpha holes, very low contrast (lum 0.202 to
0.242, sd 0.018, the flattest of the three Norse foliages): a conifer
sprig seen edge on from every direction, the same kind of drawing
mcl_core_leaves_spruce.py and kythen_firecountry_nut_pine_leaf.py read for
their own pines. Built the same way, kythen_leaf_family's needle shape, no
midrib (a needle is too thin to carry one), at nut pine's own two layer
proportions: a fine dense layer of individual needles plus a sparser,
longer layer underneath giving the sprig its body.
"""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_norse_pine_foliage"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="needle", seed=8501, normal_strength=5.6,
            fine_n=2200, fine_length=(4.0, 7.0), fine_width=(1.0, 1.8),
            coarse_n=700, coarse_length=(7.0, 12.0), coarse_width=(1.6, 2.6))
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
