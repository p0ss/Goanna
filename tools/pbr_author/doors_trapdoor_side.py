"""Hand authored height and smoothness for doors_trapdoor_side.

The trapdoor's edge, seen side on: the same frame border and groove
drawing top and bottom, a flat plank face between them. Built by
doors_trapdoor_wood_family, shared with doors_trapdoor.
"""

import sys

import doors_trapdoor_wood_family as family

STEM = "doors_trapdoor_side"
SEED = 3300
NORMAL_STRENGTH = 18.0


def main(out_dir):
    m = family.build_side(STEM, out_dir, SEED, NORMAL_STRENGTH)
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
