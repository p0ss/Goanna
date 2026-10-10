"""Hand authored LabPBR height and smoothness for kythen_siku_sod_roof.

The 32 px art (cultures/siku/materials.json: "mottle", base moss_green,
accent peat_dark, cells 9, grain 6) is a qarmaq roof seen from outside,
"moss over cut peat, laid cut side up until it takes", the recipe's own
note adding it is "the same recipe as the tundra it came off and darker".
Read the same way kythen_siku_tundra_ground.py reads its own sibling
mottle, lib.segments (tolerance 0.02) finding real clumps in the dither
rather than a smooth blur, because this is turf, not a flat plastered
roof: moss tufts and peat clods, porous (the recipe's own 0.65) and
matte (0.15).
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_sod_roof"
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

    lo, hi = region_lum.min(), region_lum.max()
    target = 0.15 + 0.65 * (region_lum - lo) / max(hi - lo, 1e-6)

    labels_hi = lib.warp_labels(labels, size=SIZE, seed=91)
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 1.1 * (narrow - wide)

    # Moss tufts a little coarser and taller than tundra_ground's own low
    # plants, the recipe's own higher porosity.
    lumps = lib.fbm(SIZE, base_cells=9, octaves=3, seed=92, gain=0.55) * 0.32
    grit = lib.blur(lib.white_noise(SIZE, seed=93), 1) * 0.06
    pits = lib.blur(lib.white_noise(SIZE, seed=94), 2) * 0.06

    height = lib.normalise01(layout + lumps + grit + pits, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=16, octaves=3, seed=95, gain=0.55)
    smooth = 0.35 * t + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 11.0
    height = lib.band(height, 0.55)
    fine_detail = 1.0  # kythen_siku_dry_stone.py's own finding: a moss tuft or peat clod
    # pit only three or four texels wide is exactly the scale pack()'s default 0.35 damping
    # exists to flatten, and it is the deliberate joint structure here, not noise grain.
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, fine_detail=fine_detail, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, fine_detail={fine_detail}")
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
