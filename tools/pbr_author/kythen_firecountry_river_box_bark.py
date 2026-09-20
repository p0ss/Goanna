"""River box bark: rough boxy plates, the same construction as coolabah
(its close relative). Its own column read is the weakest of any furrow
species (margin_frac 0.30 finds only 2 of 32, against the family's largest
raw column spread, 0.168, one dominant dark column rather than several), so
the boxy plate joints carry more of this stem's character than the
columns do."""

import sys

import kythen_bark_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_river_box_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow_plates", seed=1701, normal_strength=20.0,
            margin_frac=0.30, furrow_target=0.10, ridge_range=(0.45, 0.80),
            edge_dist=3, crown_amp=0.10, grain_amp=0.16, grain_radius=9,
            crack_amp=0.06, pore_amp=0.04, n_bands=5, plate_depth=0.22,
            plate_edge_dist=4, crack_count=8, crack_len=(8, 18),
            crack_depth=0.95)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
