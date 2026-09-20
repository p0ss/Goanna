"""One line: build kythen_siku_skin_lining from the skin family's shared build."""

import sys

import kythen_siku_skin_family as fam

GAME = "kythen"
STEM = "kythen_siku_skin_lining"

if __name__ == "__main__":
    lines = fam.run(STEM, sys.argv[1])
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
