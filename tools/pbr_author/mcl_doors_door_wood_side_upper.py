"""Hand authored height and smoothness for mcl_doors_door_wood_side_upper.

The door's edge, seen side on, for the upper half: the same drawing as
mcl_doors_door_wood_side_lower, just a shade darker. lib.class_of reads
this stem back as "metal" from a stale entry in the existing bake (an
older run's misclassification), but the art is the same plank edge strip
as the lower side texture, one flat shade instead of five, no metal sheen
drawn anywhere in it; class "wood" is used directly instead, matching its
sibling.
"""

import sys

import mcl_doors_wood_family as family

STEM = "mcl_doors_door_wood_side_upper"
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
