"""Hand authored height and smoothness for mcl_doors_door_wood_side_lower.

The door's edge, seen side on: the stile's end grain in a narrow strip at
the left, a flat plank edge the rest of the way across. Shares its shade
mapping and noise seeds with the other three wood door textures via
mcl_doors_wood_family.
"""

import sys

import mcl_doors_wood_family as family

STEM = "mcl_doors_door_wood_side_lower"
SEED = 4100
NORMAL_STRENGTH = 20.0


def main(out_dir):
    m = family.build_side(STEM, out_dir, SEED, NORMAL_STRENGTH)
    print("normal_strength", NORMAL_STRENGTH)
    lines = family.report(STEM, m)
    lib_preview(out_dir)
    return lines


def lib_preview(out_dir):
    import lib
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
