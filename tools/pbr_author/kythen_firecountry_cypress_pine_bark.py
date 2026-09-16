"""Cypress pine bark: fibrous and stringy. The family's weakest column
signal relative to its own contrast (row spread 0.016 against a column
spread of 0.072, but scattered rather than a clean stepped read) and no
flat, low variance columns at all, a busy fine mix of shades with no
dominant structure. Built from two scales of y stretched fibre and fine
flecking rather than a furrow, with a few unblurred splits along the fibre
for lib.pack's ao_from_height to find."""

import sys

import kythen_bark_family as fam

STEM = "kythen_firecountry_cypress_pine_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="fibrous", seed=2101, normal_strength=16.0,
            fine_amp=0.22, fine_radius=18, coarse_amp=0.14, coarse_radius=9,
            fleck_amp=0.10, crack_count=7, crack_len=(8, 20), crack_depth=0.95)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
