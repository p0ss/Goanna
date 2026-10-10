"""River box leaf: an ordinary eucalypt lanceolate blade, coolabah's own
close relative gets the same family proportions."""

import sys

import kythen_leaf_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_river_box_leaf"

if __name__ == "__main__":
    if {"-h", "--help"} & set(sys.argv[1:]):
        print("usage: python3 %s <out dir>\n\n%s" % (sys.argv[0], __doc__))
        sys.exit(0)
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, shape="blade", seed=3901, normal_strength=6.5,
            fine_n=550, fine_length=(8, 13), fine_width=(2.0, 3.2),
            coarse_n=220, coarse_length=(13, 18), coarse_width=(2.6, 3.8),
            midrib_amp=0.18)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
