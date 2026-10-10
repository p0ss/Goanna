"""Hand authored LabPBR height and smoothness for kythen_norse_tundra_ground,
low plants and lichen over gravel, held close to flat.

The 32 px art has three shades within 0.025 of each other, almost entirely
two of them (0.453 and 0.477) in a fine, fragmented dither: even at
tolerance 0.02 lib.segments finds no clean regions, only a couple of large
fragments and a great many small ones. That reads as a mottled ground
cover, patches of lichen and low plant growth over the gravel beneath,
not individual stones to build domes from. The relief stays gentle, with
sparse flat floored hollows for real occlusion, the device
kythen_norse_mire.py and kythen_norse_dung_channel.py use.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_tundra_ground"
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
    print(f"lib.class_of reads: {cls_read}, using {CLS}")
    labels, n = lib.segments(rgb, tolerance=0.02)
    sizes = np.bincount(labels.ravel())
    print(f"segments at tolerance 0.02: n={n}, sizes {sorted(sizes.tolist(), reverse=True)[:10]}")

    # A soft guide from the art's own dither: patches of lichen (the
    # brighter shade) sitting a touch higher than the gravel between.
    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    hollow_field = lib.blur(lib.white_noise(lib.SIZE, seed=141), 2)
    hollow_cut = float(np.percentile(hollow_field, 26))
    hollow_mask = hollow_field < hollow_cut
    max_dist = 3
    dist = lib.distance_to_edge(hollow_mask.astype(np.float32), max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    hollows = (t - 1.0) * 0.55

    grit = lib.fbm(lib.SIZE, base_cells=30, octaves=3, seed=142, gain=0.55) * 0.06
    height = lib.normalise01(0.12 * guide + hollows + grit, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: matte low plants and lichen over rougher gravel showing
    # through the hollows.
    variation = lib.fbm(lib.SIZE, base_cells=20, octaves=3, seed=143, gain=0.55)
    smooth = 0.5 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 5
    height = lib.band(height, 0.38)
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
