"""Poplar bark: fissured plates, the same construction as alder
(fissured_plates mode) but from a stronger column signal (spread 0.101
against alder's 0.041, at a 0.35 margin), so the ridges themselves carry
more contrast before the plate joints are cut into them."""

import sys

import kythen_mitteleuropa_bark_family as fam

STEM = "kythen_mitteleuropa_poplar_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="fissured_plates", seed=2901, normal_strength=24.0,
            margin_frac=0.35, furrow_target=0.10, ridge_range=(0.40, 0.65),
            edge_dist=3, crown_amp=0.10, grain_amp=0.16, grain_radius=8,
            crack_amp=0.05, pore_amp=0.04, n_bands=5, plate_depth=0.18,
            plate_edge_dist=3, crack_count=5, crack_len=(6, 16), crack_depth=0.8)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
