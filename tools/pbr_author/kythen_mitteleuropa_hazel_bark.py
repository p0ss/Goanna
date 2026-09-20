"""Hazel bark: smooth. A column threshold flags most of the tile (19 to
21 of 32 columns even at a loose margin), the opposite of a real furrow
read, because the art's contrast is a handful of bright vertical fibre
streaks on a mostly darker field rather than a few dark grooves on a
mostly bright ridge: thresholding it the way column_furrows does would
build the furrow and the ridge the wrong way round. smooth_grain mode
ignores that column read and builds an even, near isotropic undulation
instead, with only a couple of shallow cracks so the wood class's jointed
check still has something to occlude at."""

import sys

import kythen_mitteleuropa_bark_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_hazel_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="smooth_grain", seed=3001, normal_strength=9.8,
            fine_amp=0.30, coarse_amp=0.16, coarse_radius=10,
            crack_count=3, crack_len=(5, 10), crack_depth=0.6)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
