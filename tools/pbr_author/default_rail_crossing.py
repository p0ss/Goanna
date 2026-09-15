"""Hand authored height and smoothness for default_rail_crossing.

Two straight lengths of track crossing at right angles, the same two
materials as default_rail. Built by default_rail_family with the same
seed and strength as the other three pieces.
"""

import sys

import default_rail_family as family

STEM = "default_rail_crossing"
SEED = 8800
NORMAL_STRENGTH = 32.0


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
