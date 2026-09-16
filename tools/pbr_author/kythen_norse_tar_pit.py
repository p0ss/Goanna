"""Hand authored LabPBR height and smoothness for kythen_norse_tar_pit,
black, nearly flat and very smooth.

The 32 px art has eight shades with real spread (sd 0.065): a fifth of
the tile is the darkest shade (0.089), read as the pit's own black depths
showing through, and a lighter shade (0.306, 11.7%) reads as an oily
sheen catching the light, over a mid toned matrix. lib.class_of reads
this as "soil"; there is no tar or bitumen class in lib.py's table, so
the surface stays close to level (a viscous black pool has almost no
relief) with smoothness pushed harder toward the top of what the soil
class allows than kythen_norse_bog_pool.py's own water.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_tar_pit"
CLS = "soil"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS} (no tar class in lib.py)")
    labels, n = lib.segments(rgb, tolerance=0.06)
    sizes = np.bincount(labels.ravel())
    print(f"segments at tolerance 0.06: n={n}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")

    # Sparse, flat floored hollows for real occlusion, standing in for the
    # rare bubble or dimple in the tar's surface.
    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=191), 2)
    hollow_cut = float(np.percentile(hollow_field, 28))
    hollow_mask = hollow_field < hollow_cut
    dist = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=3)
    t = np.clip(dist / 3, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    hollows = (t - 1.0) * 2.9

    ripple = lib.fbm(lib.SIZE, base_cells=12, octaves=3, seed=192, gain=0.55) * 0.05
    height = lib.normalise01(hollows + 0.05 * ripple, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: very high and tightly held, a viscous black surface
    # with almost no matte patches anywhere.
    variation = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=193, gain=0.55)
    smooth = 0.70 + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 5
    height = lib.band(height, 0.26)
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
