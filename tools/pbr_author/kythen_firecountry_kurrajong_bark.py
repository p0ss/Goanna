"""Kurrajong bark: smooth. Only three shades in the art and the shallowest
column spread of any furrow species bar beefwood (0.044); margin_frac 0.15
finds just the two columns either side of the wrap seam as a furrow, kept
shallow (furrow_target 0.35 against a ridge range of 0.45 to 0.60) so the
bulk of the tile reads flat rather than furrowed."""

import sys

import kythen_bark_family as fam

STEM = "kythen_firecountry_kurrajong_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=1301, normal_strength=30.0,
            margin_frac=0.15, furrow_target=0.35, ridge_range=(0.45, 0.60),
            edge_dist=3, crown_amp=0.05, grain_amp=0.14, grain_radius=11,
            crack_amp=0.04, pore_amp=0.03, crack_count=8, crack_len=(6, 16),
            crack_depth=0.9)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
