"""Beech bark: smooth with faint fluting. A loose margin (0.15) already
finds 5 to 6 of 32 columns, more than oak's own margin needs, which is the
faint vertical striping the art actually draws rather than a real groove.
flute mode takes that same column read but blurs it with a wide
wave_edge_dist so the step becomes a continuous, shallow wave with no flat
plateau and no wall, plus a few hard cracks so the jointed check still has
something to occlude at even though beech is otherwise the smoothest bark
in the family bar hazel."""

import sys

import kythen_mitteleuropa_bark_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_beech_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="flute", seed=2401, normal_strength=22.6,
            margin_frac=0.15, furrow_target=0.40, ridge_range=(0.50, 0.62),
            wave_edge_dist=10, grain_amp=0.16, grain_radius=8, pore_amp=0.03,
            crack_count=3, crack_len=(6, 14), crack_depth=0.7)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
