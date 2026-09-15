"""Hand authored height and smoothness for doors_trapdoor.

A wooden trapdoor: a plank frame with a cross of bracing proud over it
and four square gaps cut through the panel between the bracing. Built by
doors_trapdoor_wood_family, shared with doors_trapdoor_side.
"""

import sys

import doors_trapdoor_wood_family as family

STEM = "doors_trapdoor"
SEED = 3300
NORMAL_STRENGTH = 28.0


def main(out_dir):
    m = family.build_main(STEM, out_dir, SEED, NORMAL_STRENGTH)
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
