"""Nut pine bark: scaly. Its dark texels fall in short diagonal runs
rather than columns or a scatter, climbing the tile the way overlapping
bark scales climb a trunk, so it is built from small elongated domes
scattered and shaded like shingles (a shadow crescent where the scale
above overlaps the one below), guided by the art's own darker texels for
where a scale edge sits, plus a few unblurred splits between scale
clusters for the ambient occlusion pass to find.

class_of reads this one back as stone, the same name matching gap
coolabah_bark hits (no bark entry in NAME_HINTS, so it falls back to the
bake's own packed smoothness level). The art is plainly tree bark, so this
overrides to wood."""

import sys

import kythen_bark_family as fam

GAME = "kythen"
STEM = "kythen_firecountry_nut_pine_bark"

if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = fam.run(STEM, out_dir, mode="scaly", seed=2201, normal_strength=30.0,
            scale_count=110, scale_length=(3.5, 6.5), scale_width=(1.6, 2.8),
            grain_amp=0.08, crack_count=6, crack_len=(6, 16), crack_depth=0.9,
            cls_override="wood")
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
