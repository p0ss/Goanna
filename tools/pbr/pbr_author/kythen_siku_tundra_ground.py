"""Hand authored LabPBR height and smoothness for kythen_siku_tundra_ground.

The 32 px art (cultures/siku/materials.json: "mottle", base tundra_brown,
accent moss_green, cells 15) is "peat, moss and stone, a hand deep over the
frost" per its own title, a per texel dither with no drawn stone or plant
outline. lib.segments at tolerance 0.02 finds real structure in that
dither even so, 38 regions, one dominant 568 texel patch (the matrix) and
a spread down to 17 lone texels: low plants and lichen sitting proud or a
stone showing through the moss, the same reading kythen_dirt.py gives its
own dithered art, applied here rather than a fresh technique.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_tundra_ground"
CLS = "soil"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    tolerance = 0.02
    labels, n = lib.segments(rgb, tolerance=tolerance)
    sizes = np.bincount(labels.ravel())
    region_lum = np.array([lum[labels == i].mean() for i in range(n)])
    print(f"segments: n={n} tolerance={tolerance}")
    print("region sizes:", sorted(sizes.tolist(), reverse=True)[:15])
    print(f"{int((sizes == 1).sum())} of {n} regions are a single texel")

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, size=SIZE, seed=81)
    edges = lib.region_edges(labels_hi)
    max_dist = 4
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    lumps = lib.fbm(SIZE, base_cells=11, octaves=3, seed=82, gain=0.55) * 0.28
    grit = lib.blur(lib.white_noise(SIZE, seed=83), 1) * 0.05
    pits = lib.blur(lib.white_noise(SIZE, seed=84), 2) * 0.04

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=85, gain=0.55)
    smooth = 0.40 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 15.0
    height = lib.band(height, 0.55)
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
