"""Hand authored LabPBR height and smoothness for kythen_siku_snow_block.

The 32 px art is masonry, course 8 and stone_width 16 in
cultures/siku/materials.json's own recipe: four courses of two blocks, eight
to the node, "cut with a knife to a size, bevelled, and laid in courses
that lean inward". The recipe's own note is explicit that the joint here
is not mortar: "the block above settling onto the block below and
freezing there, so the mortar colour is LIGHTER than the base rather than
darker, a rime line, not a shadow." That is why this script never builds
a trench the way kythen_siku_dry_stone.py's real gap does: the join is a
seam a knife blade made, then sealed by refreeze, not an open gap, so it
gets a hairline rime ridge in the height and a rougher, granular band in
the smoothness, and stays inside snow's own 6 to 14 degree tilt band
rather than reaching for a stone joint's depth.

Straight grid, no lib.warp_labels: a knife cut block has a straight edge.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_snow_block"
CLS = "snow"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    h, w = rgb.shape[:2]
    course, stone_width = 8, 16  # cultures/siku/materials.json's own numbers
    rows, cols = h // course, w // stone_width  # 4, 2
    print(f"masonry grid: {rows} courses x {cols} blocks = {rows * cols} blocks")

    r32 = np.arange(h)[:, None] // course
    c32 = np.arange(w)[None, :] // stone_width
    block_id = (r32 * cols + c32) + np.zeros((h, w), dtype=int)
    labels_hi = np.kron(block_id, np.ones((SIZE // h, SIZE // w), dtype=int))

    edges = lib.region_edges(labels_hi)
    max_dist = 20  # a soft, wide rime line, not a knife wide crevice
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    rime = (1.0 - t) * 0.5  # a slight RISE at the seam, per the recipe's own note

    sparkle_grains = lib.white_noise(SIZE, seed=61)
    threshold = np.percentile(sparkle_grains, 95.0)
    sparkle = np.clip((sparkle_grains - threshold) / (sparkle_grains.max() - threshold), 0.0, 1.0)
    sparkle = lib.blur(sparkle, 1)

    drift = lib.blur(lib.fbm(SIZE, base_cells=8, octaves=2, seed=62, gain=0.5) * 0.5 + 0.5, 2)
    shape = 0.35 * (drift - 0.5) + rime + 0.18 * sparkle
    height = lib.band(shape, 0.14)
    print(f"height sd {height.std():.4f}")

    # Smoothness: the recipe's own two numbers, face 0.3 against the seam's
    # own 0.18, the seam rougher (granular refreeze) rather than smoother.
    variation = lib.fbm(SIZE, base_cells=20, octaves=2, seed=63, gain=0.5)
    smooth = -0.30 * (1.0 - t) + 0.20 * zscore(variation) + 0.20 * sparkle
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 19.0
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
