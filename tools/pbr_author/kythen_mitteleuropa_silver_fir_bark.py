"""Silver fir bark: scaly and resinous. The family's weakest column
signal bar juniper's (spread 0.049, at most 1 to 4 columns even at a
loose margin) and a fine, busy, almost uniform mottle otherwise, the
kythen_firecountry_nut_pine_bark.py read: overlapping scale domes guided
by the art's own darker texels. Resinous lifts the smoothness mean and
adds resin beads right at the scale edges, where sap collects and
hardens."""

import sys

import kythen_mitteleuropa_bark_family as fam

GAME = "kythen"
STEM = "kythen_mitteleuropa_silver_fir_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="scaly", seed=3201, normal_strength=31.3,
            scale_count=100, scale_length=(3.0, 6.0), scale_width=(1.4, 2.6),
            grain_amp=0.10, resin_amp=0.30, crack_count=4, crack_len=(6, 14),
            crack_depth=0.7)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
