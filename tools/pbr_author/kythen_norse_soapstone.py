"""Hand authored LabPBR height and smoothness for kythen_norse_soapstone,
a smooth, soft stone, nearly flat.

The 32 px art has five shades, sd 0.037, in a fine dither with no stone
sized regions (315 of them at tolerance 0.03, the biggest only 47
texels): a continuous mottled slab, the same shape as
kythen_norse_basalt_stone.py's own reading, not a cobble layout. Soapstone
is famously soft and soapy to the touch, worked smooth rather than left
rough, so the polished-face rule applies: the mottle goes mostly into the
smoothness field, the height stays close to level (README's "Polished
faces are flat"), with sparse flat floored hollows for real occlusion.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_soapstone"
CLS = "stone"


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    cls_read = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {cls_read}, using {CLS}")
    labels, n = lib.segments(rgb, tolerance=0.03)
    sizes = np.bincount(labels.ravel())
    print(f"segments at tolerance 0.03: n={n}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")

    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=201), 2)
    hollow_cut = float(np.percentile(hollow_field, 28))
    hollow_mask = hollow_field < hollow_cut
    dist = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=3)
    t = np.clip(dist / 3, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    hollows = (t - 1.0) * 0.55

    height = lib.normalise01(0.03 * guide + hollows, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness carries almost all of the art's own mottle, the way a
    # polished face's crystal texture is meant to (README's own rule):
    # soft and soapy, wide spread, worn high overall.
    art_mottle = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 1))
    variation = lib.fbm(lib.SIZE, base_cells=22, octaves=3, seed=202, gain=0.55)
    smooth = 0.55 + 0.35 * (art_mottle - 0.5) + 0.30 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 7
    height = lib.band(height, 0.40)
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
