"""Hand authored height and smoothness for mcl_doors_door_iron_lower.

The bottom half of the iron door: a riveted steel plate, no grille (that
is the upper half's feature). Built by mcl_doors_iron_family so it shares
its rivet finding, seam rows and noise seeds with the other three iron
door textures and reads as one door.
"""

import sys

import mcl_doors_iron_family as family

STEM = "mcl_doors_door_iron_lower"
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
