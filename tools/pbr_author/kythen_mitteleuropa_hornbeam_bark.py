"""Hornbeam bark: smooth with faint fluting, the same read as beech
(flute mode) but from a weaker column signal (spread 0.084, 3 to 4
columns against beech's 5 to 6), and the art itself carries a few bare
patches beech's does not, so the grain and pore terms run a touch
stronger here to fill in where the column read has less to say."""

import sys

import kythen_mitteleuropa_bark_family as fam

STEM = "kythen_mitteleuropa_hornbeam_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="flute", seed=2501, normal_strength=21.3,
            margin_frac=0.25, furrow_target=0.38, ridge_range=(0.48, 0.64),
            wave_edge_dist=9, grain_amp=0.19, grain_radius=7, pore_amp=0.04,
            crack_count=4, crack_len=(6, 14), crack_depth=0.75)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
