"""Quandong bark: fine. margin_frac 0.35 finds 6 of 32 columns, close set
and thin, with a finer grain scale (grain_radius 6 rather than the family's
usual 10 to 12) so the streaking is tighter grained than the broader gum
barks."""

import sys

import kythen_bark_family as fam

STEM = "kythen_firecountry_quandong_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=1501, normal_strength=20.0,
            margin_frac=0.35, furrow_target=0.20, ridge_range=(0.50, 0.72),
            edge_dist=2, crown_amp=0.08, grain_amp=0.14, grain_radius=6,
            crack_amp=0.05, pore_amp=0.03)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
