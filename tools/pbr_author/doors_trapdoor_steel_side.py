"""Hand authored height and smoothness for doors_trapdoor_steel_side.

The steel trapdoor's edge, seen side on: the same riveted plate shades as
the top face, no holes in it. Built by doors_trapdoor_steel_family,
shared with doors_trapdoor_steel.
"""

import sys

import doors_trapdoor_steel_family as family

STEM = "doors_trapdoor_steel_side"
SEED = 5500
NORMAL_STRENGTH = 18.0
RIVET_AMP = 0.22


def main(out_dir):
    m = family.build(STEM, out_dir, SEED, NORMAL_STRENGTH, has_holes=False, rivet_amp=RIVET_AMP)
    print("normal_strength", NORMAL_STRENGTH)
    lines = family.report(STEM, m)
    import lib
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
