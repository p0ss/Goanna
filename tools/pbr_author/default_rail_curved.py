"""Hand authored height and smoothness for default_rail_curved.

A quarter turn of track, the same two materials as default_rail: steel
rail and wood sleeper, told apart by warmth. Built by default_rail_family
with the same seed and strength as the other three pieces.

The curve's own drawn track covers only a third of the tile (the rest is
a real gap, the ground showing through), far less than the straight,
crossing or t junction pieces, so the mean tilt taken over the whole map
comes out under the wood/metal 15 to 30 degree band even though the drawn
rail and sleeper carry the same relief depth as their straight
counterparts; see the reported numbers.
"""

import sys

import default_rail_family as family

STEM = "default_rail_curved"
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
