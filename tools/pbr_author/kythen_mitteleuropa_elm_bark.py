"""Elm bark: deeply ridged, but a much weaker column signal than oak
(spread 0.043 against 0.071, only 2 to 3 columns clear even a loose
margin), and the art itself is busy and mottled rather than clean vertical
stripes. So the furrow read still runs (margin_frac 0.35, the loosest
margin used in this family, to find any furrow at all), but the depth
that oak gets from its stepped dish, elm gets more of from stronger grain
and cracking, matching the busier art."""

import sys

import kythen_mitteleuropa_bark_family as fam

STEM = "kythen_mitteleuropa_elm_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=2201, normal_strength=22.0,
            margin_frac=0.35, furrow_target=0.05, ridge_range=(0.35, 0.65),
            edge_dist=3, crown_amp=0.10, grain_amp=0.26, grain_radius=7,
            crack_amp=0.08, pore_amp=0.05, crack_count=7, crack_len=(6, 16),
            crack_depth=0.85)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
