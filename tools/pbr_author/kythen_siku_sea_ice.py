"""One line: build kythen_siku_sea_ice from the ice family's shared build."""

import sys

import kythen_siku_ice_family as fam

STEM = "kythen_siku_sea_ice"

if __name__ == "__main__":
    lines = fam.run(STEM, sys.argv[1])
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
