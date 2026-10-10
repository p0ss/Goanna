"""Beefwood bark: coarse. Many shallow furrow columns (margin_frac 0.20
finds 18 of 32, more than half the ring) rather than a few deep ones, the
busy, close-set texture the art's own low contrast columns (spread only
0.035) already draw."""

import sys

import kythen_bark_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_beefwood_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=1101, normal_strength=18.0,
            margin_frac=0.20, furrow_target=0.10, ridge_range=(0.55, 0.85),
            edge_dist=3, crown_amp=0.12, grain_amp=0.16, grain_radius=10,
            crack_amp=0.05, pore_amp=0.03)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
