"""Beech leaf: ovate with a wavy margin, aspect 1.5."""

import sys

import kythen_mitteleuropa_leaf_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_beech_leaf"
ASPECT = 1.5

if __name__ == "__main__":
    if {"-h", "--help"} & set(sys.argv[1:]):
        print("usage: python3 %s <out dir>\n\n%s" % (sys.argv[0], __doc__))
        sys.exit(0)
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="broadleaf", seed=4401, normal_strength=9.0,
            fine_len=(5.0, 8.0), fine_wid=(5.0 / ASPECT, 8.0 / ASPECT), fine_n=750,
            coarse_len=(9.0, 13.0), coarse_wid=(9.0 / ASPECT, 13.0 / ASPECT), coarse_n=260)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
