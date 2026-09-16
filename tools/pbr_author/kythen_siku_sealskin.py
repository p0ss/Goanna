"""One line: build kythen_siku_sealskin from the skin family's shared build."""

import sys

import kythen_siku_skin_family as fam

STEM = "kythen_siku_sealskin"

if __name__ == "__main__":
    lines = fam.run(STEM, sys.argv[1])
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
