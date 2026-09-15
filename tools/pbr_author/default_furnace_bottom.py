"""Hand authored LabPBR height and smoothness for default_furnace_bottom.

default_furnace_bottom.png and default_furnace_top.png are the same file
byte for byte, so this calls the top script's build with this stem. See
default_furnace_top.py for the reasoning behind the layout.
"""
import sys

import default_furnace_top as top

STEM = "default_furnace_bottom"


def main():
    global STEM
    out_dir = sys.argv[1]
    saved = top.STEM
    top.STEM = STEM
    try:
        return top.main()
    finally:
        top.STEM = saved


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
