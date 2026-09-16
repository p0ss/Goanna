"""Willow bark: deep and stringy, juniper's fibrous construction pulled
further along the same axis rather than a different material: stronger
fine and coarse amplitude, deeper and more frequent cracks, so it reads
as the same family of stringy bark taken deeper rather than a furrowed
one."""

import sys

import kythen_mitteleuropa_bark_family as fam

STEM = "kythen_mitteleuropa_willow_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="fibrous", seed=3301, normal_strength=40.1,
            fine_amp=0.28, fine_radius=18, coarse_amp=0.18, coarse_radius=10,
            fleck_amp=0.07, crack_count=9, crack_len=(8, 20), crack_depth=1.0)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
