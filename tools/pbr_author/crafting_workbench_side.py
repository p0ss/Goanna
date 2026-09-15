"""Hand authored LabPBR height and smoothness for crafting_workbench_side.

crafting_workbench_side.png and crafting_workbench_front.png are the same
file byte for byte (md5 515f613f81e6cf2c548ee3051ee30c50 both): the game
draws the identical picture on both faces, so this calls the front script's
build with this stem rather than duplicating its analysis. See
crafting_workbench_front.py for the reasoning behind the layout.
"""
import sys

import crafting_workbench_front as front

STEM = "crafting_workbench_side"


def main():
    return front.build(STEM)


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
