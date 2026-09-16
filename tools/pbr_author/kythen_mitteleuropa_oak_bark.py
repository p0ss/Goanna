"""Oak bark: deeply ridged. margin_frac 0.25 finds 5 of 32 columns as
furrow (col spread 0.071, a clean column signal), cut deep and dark
(furrow_target 0.05) against a mid grey ridge range typical of European
oak. class_of reads this stem as stone, which does not match plainly bark
art, so it is overridden to wood, the same read every other bark in this
family gets."""

import sys

import kythen_mitteleuropa_bark_family as fam

STEM = "kythen_mitteleuropa_oak_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="furrow", seed=2101, normal_strength=24.0,
            margin_frac=0.25, furrow_target=0.05, ridge_range=(0.35, 0.65),
            edge_dist=3, crown_amp=0.12, grain_amp=0.18, grain_radius=9,
            crack_amp=0.06, pore_amp=0.03, crack_count=6, crack_len=(8, 18),
            crack_depth=0.9, cls_override="wood")
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
