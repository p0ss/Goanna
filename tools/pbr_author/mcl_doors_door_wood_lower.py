"""Hand authored height and smoothness for mcl_doors_door_wood_lower.

The bottom half of a wooden door: a plain recessed panel between the two
stiles, no window (that is the upper half's feature). Built by
mcl_doors_wood_family so it shares its shade mapping and noise seeds with
mcl_doors_door_wood_upper and reads as one door.
"""

import sys

import mcl_doors_wood_family as family

STEM = "mcl_doors_door_wood_lower"
SEED = 4100
NORMAL_STRENGTH = 9.0


def main(out_dir):
    m = family.build_front(STEM, out_dir, SEED, NORMAL_STRENGTH)
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
