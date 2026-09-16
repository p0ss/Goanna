"""Coolabah bark: rough boxy plates. The column furrows (margin_frac 0.25,
5 of 32) carry the main relief; a second, shallower set of horizontal
joints (band_groove, not read from the art, whose own row mean is almost
flat at 0.038 against a column spread of 0.116) breaks the ridges into the
boxy plates real coolabah bark sheds in.

class_of reads this one back as stone: NAME_HINTS has no bark entry, so it
falls through to the bake's own packed smoothness level, and this stem's
happened to land nearer stone's level than wood's, a name matching gap
rather than a real material read. The art is plainly tree bark, so this
overrides to wood."""

import sys

import kythen_bark_family as fam

STEM = "kythen_firecountry_coolabah_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow_plates", seed=1601, normal_strength=20.0,
            margin_frac=0.25, furrow_target=0.10, ridge_range=(0.45, 0.80),
            edge_dist=3, crown_amp=0.10, grain_amp=0.16, grain_radius=9,
            crack_amp=0.06, pore_amp=0.04, n_bands=6, plate_depth=0.20,
            plate_edge_dist=4, crack_count=8, crack_len=(8, 18),
            crack_depth=0.95, cls_override="wood")
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
