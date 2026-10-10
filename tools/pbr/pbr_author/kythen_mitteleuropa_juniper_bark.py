"""Juniper bark: stringy. 10 to 13 of 32 columns clear even a strict
margin, which is not a clean furrow set, it is the whole tile carrying
weak, broken vertical structure with no dominant columns at all, the
kythen_firecountry_cypress_pine_bark.py read: fibrous mode, fine and
coarse fbm blurred along the log's axis plus flecks, no column dish."""

import sys

import kythen_mitteleuropa_bark_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_juniper_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="fibrous", seed=3101, normal_strength=15.0,
            fine_amp=0.22, fine_radius=14, coarse_amp=0.14, coarse_radius=8,
            fleck_amp=0.06, crack_count=6, crack_len=(6, 16), crack_depth=0.85)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
