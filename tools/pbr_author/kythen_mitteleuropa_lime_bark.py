"""Lime bark: shallow. The family's clearest column signal (spread 0.118,
4 columns clear a 0.25 margin), but the ridge_range is held to a narrow
band (0.45 to 0.60) and furrow_target close to the ridge floor (0.30)
rather than oak's wide gap, so the stepped dish itself stays gentle. The
wood class still asks for the same 18 to 28 degree tilt as every other
bark, made up here by grain and pores rather than by a deep groove."""

import sys

import kythen_mitteleuropa_bark_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_lime_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=2301, normal_strength=19.4,
            margin_frac=0.25, furrow_target=0.30, ridge_range=(0.45, 0.60),
            edge_dist=4, crown_amp=0.06, grain_amp=0.20, grain_radius=10,
            crack_amp=0.05, pore_amp=0.04, crack_count=4, crack_len=(5, 12),
            crack_depth=0.6)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
