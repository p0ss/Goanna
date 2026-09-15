"""Hand authored LabPBR height and smoothness for default_furnace_front_active.

The lit furnace face: the same grey cobble body and the same mouth as
default_furnace_front, cut from this art's own grey stone texels (rows 0 to
7 and 14 to 15 match default_furnace_front's shades exactly), but with the
firebox itself replaced by a spread of warm colour, from pale yellow at its
hottest (255, 192, 58) down through orange to a near black ember red at its
coolest (94, 16, 9). See default_furnace_front.py for the cobble body and
the mouth geometry, and its fire_emission for how the glow is read
straight from this art's own warmth rather than a separate mask.
"""
import sys

import default_furnace_front as front

STEM = "default_furnace_front_active"


def main():
    return front.build(STEM, active_emission_stem=STEM)


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
