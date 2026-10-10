"""Ironbark bark: deeply furrowed and dark. margin_frac 0.35 finds 7 of 32
columns as furrow (the widest column mean spread short of the two plate
species, 0.076), cut deep and dark (furrow_target 0.05, ridge held low at
0.30 to 0.55 too, since the whole tile reads dark in the art, lum 0.089 to
0.257) rather than the pale ridge crowns a lighter bark gets."""

import sys

import kythen_bark_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_ironbark_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=1201, normal_strength=22.0,
            margin_frac=0.35, furrow_target=0.05, ridge_range=(0.30, 0.55),
            edge_dist=4, crown_amp=0.08, grain_amp=0.16, grain_radius=9,
            crack_amp=0.07, pore_amp=0.04, crack_count=6, crack_len=(8, 18),
            crack_depth=0.9)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
