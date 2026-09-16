"""Norse stave wall: vertical staves with joints from the joint mask.

32 px art, six shades, and the same clean furrow signature
kythen_norse_driftwood.py reads on its own art: columns 0, 4, 8, 12, 16,
20, 24 and 28 sit at 0.212 to 0.215, well below every other column (0.291
to 0.308), evenly spaced every four columns, cutting the ring into eight
three column staves. Built with kythen_bark_family's furrow mode, the same
machinery driftwood uses, but read as sawn staves rather than weathered
driftwood: a tighter joint (a narrower edge_dist, a crisp sawn edge rather
than a wide weathered split) and calmer grain. The blurred joint step
alone under reports lib.pack's ao_from_height, the same limitation
kythen_bark_family's own module docstring records for a species with few
furrow groups, so a small number of hard_cracks recover a real occluding
wall for it: only three, shallow, far fewer and shallower than driftwood's
own checking splits, standing for the ordinary small seasoning cracks even
sound sawn staves get rather than driftwood's open weathering.
"""

import sys

import kythen_bark_family as fam

GAME = "kythen"
STEM = "kythen_norse_stave_wall"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=8801, normal_strength=16.0,
            margin_frac=0.20, furrow_target=0.08, ridge_range=(0.55, 0.85),
            edge_dist=2, crown_amp=0.08, grain_amp=0.14, grain_radius=10,
            crack_amp=0.03, pore_amp=0.02,
            crack_count=3, crack_len=(10, 20), crack_depth=0.6)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
