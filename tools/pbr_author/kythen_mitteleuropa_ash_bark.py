"""Ash bark: diamond furrowed. The art's own column signal is the
family's strongest (spread 0.170) but is not one furrow set top to
bottom: checked by hand a row band at a time, the darkest columns shift
from band to band (1, 20, 27 in rows 0 to 7; 0, 11, 20 in rows 8 to 15;
0, 31 in rows 16 to 23), which is what a net of crossing fissures reads
as one row band at a time rather than what a single straight furrow does.
diamond mode builds that lattice directly: two furrow families crossing
at 45 degrees, spacing 32 texels (a divisor of the map size, so the
lattice tiles exactly) with a gentle warp so the lines wander the way
real ash fissures do rather than sitting mechanically straight."""

import sys

import kythen_mitteleuropa_bark_family as fam

STEM = "kythen_mitteleuropa_ash_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    # The diamond lattice read as chain link on the ramp at any spacing;
    # ash is built like elm, interlacing furrows along the trunk, with its
    # own seed and a touch more depth for the diamond fissure character.
    lines = fam.run(STEM, out_dir, mode="furrow", seed=2601, normal_strength=22.0,
            margin_frac=0.35, furrow_target=0.05, ridge_range=(0.35, 0.65),
            edge_dist=3, crown_amp=0.10, grain_amp=0.26, grain_radius=7,
            crack_amp=0.08, pore_amp=0.05, crack_count=7, crack_len=(6, 16),
            crack_depth=0.85)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
