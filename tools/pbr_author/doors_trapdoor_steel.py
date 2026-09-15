"""Hand authored height and smoothness for doors_trapdoor_steel.

A riveted steel trapdoor: a dark frame, a mid tone plate, rivets found as
local brightness peaks over the whole face, and a dozen small holes
punched through it. Built by doors_trapdoor_steel_family, shared with
doors_trapdoor_steel_side.
"""

import sys

import doors_trapdoor_steel_family as family

STEM = "doors_trapdoor_steel"
SEED = 5500
NORMAL_STRENGTH = 20.0
RIVET_AMP = 0.24


def main(out_dir):
    m = family.build(STEM, out_dir, SEED, NORMAL_STRENGTH, has_holes=True, rivet_amp=RIVET_AMP)
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
