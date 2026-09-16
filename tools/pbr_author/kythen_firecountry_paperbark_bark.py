"""Paperbark bark: papery layers. Three shades, the darker two sitting
together in one loose, irregular patch over roughly 42 percent of the
tile rather than in columns or a scatter of small marks, which is what a
hanging sheet of shed paper bark reads as. Built as a soft raised plateau
(the sheet standing proud of the trunk) with fine horizontal creases (the
paper's own layering) and a few unblurred splits where a sheet has
actually torn free."""

import sys

import kythen_bark_family as fam

STEM = "kythen_firecountry_paperbark_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="papery", seed=2001, normal_strength=20.0,
            dark_thresh=0.74, warp_amp=5.0, sheet_amp=0.45, sheet_blur=4,
            crease_amp=0.06, crease_radius=5, grain_amp=0.06, pore_amp=0.02,
            crack_count=6, crack_len=(8, 20), crack_depth=0.95)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
