"""Norse driftwood: weathered wood with deep open grain.

32 px art, six shades, and a clean column signature: columns 0, 4, 8, 12,
16, 20, 24 and 28 sit at 0.339 to 0.352, well below every other column
(0.540 to 0.575), evenly spaced every four columns. That is
default_tree.py's own furrow read (a handful of dark, nearly flat columns
cutting the ring into ridges) except this art has eight of them, tight and
regular, not one or two: repeated deep splits running the length of a log
that has dried and wetted many times over, the checking cracks real
driftwood shows rather than a single bark furrow. kythen_bark_family's
furrow mode is exactly that machinery (generalised off default_tree.py, see
its own module docstring), so this reuses it rather than copying the
column finding code again, with a low furrow target and extra crack depth
for the open, weathered read, and a class override since class_of falls
back to "leaves" here (no wood entry matched this stem's name in the
bake's own table, the same name-matching gap several Firecountry barks
hit).
"""

import sys

import kythen_bark_family as fam

GAME = "kythen"
STEM = "kythen_norse_driftwood"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=8701, normal_strength=18.0,
            margin_frac=0.20, furrow_target=0.04, ridge_range=(0.45, 0.85),
            edge_dist=3, crown_amp=0.10, grain_amp=0.18, grain_radius=10,
            crack_amp=0.06, pore_amp=0.03,
            crack_count=10, crack_len=(8, 20), crack_depth=1.1,
            cls_override="wood")
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
