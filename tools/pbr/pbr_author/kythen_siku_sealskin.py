"""One line: build kythen_siku_sealskin from the skin family's shared build."""

import sys

import kythen_siku_skin_family as fam

GAME = "kythen"
STEM = "kythen_siku_sealskin"

if __name__ == "__main__":
    if {"-h", "--help"} & set(sys.argv[1:]):
        print("usage: python3 %s <out dir>\n\n%s" % (sys.argv[0], __doc__))
        sys.exit(0)
    lines = fam.run(STEM, sys.argv[1])
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
