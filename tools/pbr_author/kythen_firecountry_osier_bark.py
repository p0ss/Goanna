"""Osier bark: smooth and slender. margin_frac 0.20 finds 5 of 32 columns,
thin and shallow (furrow_target 0.30, ridge 0.45 to 0.60) for a slender
stem's faint striping rather than a furrowed trunk."""

import sys

import kythen_bark_family as fam

STEM = "kythen_firecountry_osier_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=1401, normal_strength=20.0,
            margin_frac=0.20, furrow_target=0.30, ridge_range=(0.45, 0.60),
            edge_dist=3, crown_amp=0.06, grain_amp=0.15, grain_radius=12,
            crack_amp=0.04, pore_amp=0.03)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
