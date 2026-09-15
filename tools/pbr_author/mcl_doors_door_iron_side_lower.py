"""Hand authored height and smoothness for mcl_doors_door_iron_side_lower.

The source art for this stem is a byte identical copy of
mcl_doors_door_iron_lower (same file, checked by hash): the mod draws the
iron door's edge with the same riveted plate as its front. Built by
mcl_doors_iron_family with the same seed, so it comes out the same relief
as its front counterpart, which is honest to art that draws nothing
different for the side.
"""

import sys

import mcl_doors_iron_family as family

STEM = "mcl_doors_door_iron_side_lower"
SEED = 7200
NORMAL_STRENGTH = 18.0


def main(out_dir):
    m = family.build(STEM, out_dir, SEED, NORMAL_STRENGTH)
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
