"""Hand authored LabPBR height and smoothness for kythen_norse_bog_pool,
dark still water sitting in the bog, nearly flat and smooth.

The 32 px art has real variation (sd 0.072) in a fragmented mottle, no
clean regions (179 of them at tolerance 0.06, the biggest only 139
texels): a rippled reflection on dark water rather than a drawn stone
layout. lib.class_of reads this as "soil" from the bake; there is no
water class in lib.py's table, and soil is the closest available match
for a mostly opaque surface, so the height stays close to level (the
mottle becomes shallow ripples) while the smoothness is pushed towards
the top of what the soil class allows.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_bog_pool"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS} (no water class in lib.py)")
    labels, n = lib.segments(rgb, tolerance=0.06)
    sizes = np.bincount(labels.ravel())
    print(f"segments at tolerance 0.06: n={n}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")

    # A soft guide from the art's own rippled reflection, smoothly
    # upscaled rather than kept as hard texel plateaus: water has no
    # texel scale structure of its own.
    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    # Sparse, flat floored hollows for real occlusion (kythen_norse_mire.py's
    # own device), standing in for the deeper eddies between ripples.
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=181), 2)
    hollow_cut = float(np.percentile(hollow_field, 26))
    hollow_mask = hollow_field < hollow_cut
    dist = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=2)
    t = np.clip(dist / 2, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    hollows = (t - 1.0) * 1.5

    ripple = lib.fbm(lib.SIZE, base_cells=14, octaves=3, seed=182, gain=0.55) * 0.08
    height = lib.normalise01(0.06 * guide + hollows + 0.5 * ripple, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: pushed high and even, water being far smoother than the
    # peat around it; pack() still caps a soil texel's spread at the class
    # level plus 0.25, so this sits near that ceiling rather than trying
    # to read as true still water.
    variation = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=183, gain=0.55)
    smooth = 0.62 + 0.45 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 6
    height = lib.band(height, 0.30)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
