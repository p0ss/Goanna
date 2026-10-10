"""Norse rowan foliage: pinnate leaflets.

32 px art, 19.9 percent alpha holes, the gappiest of the three Norse
foliages: a compound rowan leaf is a row of small oval leaflets down a
central stem, each one a small blade with its own midrib, more open
between leaflets than a solid canopy like birch's. Built with
kythen_leaf_family's blade shape, sized between birch's small lobes and
quandong's slender ones, with a clear midrib per leaflet.
"""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_norse_rowan_foliage"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="blade", seed=8601, normal_strength=7.0,
            fine_n=750, fine_length=(5.0, 8.0), fine_width=(1.8, 2.6),
            coarse_n=280, coarse_length=(8.0, 11.0), coarse_width=(2.3, 3.2),
            midrib_amp=0.16, alpha_blur=2)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
