"""Alder bark: fissured plates. The column signal is present but not
strong (spread 0.041, 4 of 32 columns at a 0.25 margin), so, the way
kythen_bark_family.py's own plate species found for coolabah and river
box, the plate joints are a structural decision that gives real alder
bark its plating rather than a row by row read: fissured_plates mode runs
the furrow read for the vertical ridges, then band_groove's horizontal
joints break them into plates."""

import sys

import kythen_mitteleuropa_bark_family as fam

STEM = "kythen_mitteleuropa_alder_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="fissured_plates", seed=2801, normal_strength=19.6,
            margin_frac=0.25, furrow_target=0.08, ridge_range=(0.35, 0.55),
            edge_dist=3, crown_amp=0.08, grain_amp=0.15, grain_radius=8,
            crack_amp=0.05, pore_amp=0.04, n_bands=6, plate_depth=0.16,
            plate_edge_dist=3, crack_count=5, crack_len=(6, 14), crack_depth=0.75)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
