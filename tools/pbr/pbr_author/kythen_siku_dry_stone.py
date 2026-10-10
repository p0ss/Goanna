"""Hand authored LabPBR height and smoothness for kythen_siku_dry_stone.

The 32 px art is masonry, course 16 and stone_width 16 in
cultures/siku/materials.json's own recipe: two courses of two boulders, four
to the node, confirmed against the art itself (row 0 and column 17 both
carry the darkest shade, the mortar shade, splitting the tile into a 2x2
grid). "Lime needs fuel to burn and there is no fuel": the recipe's own
note says these are dry-laid, no mortar possible, so the gap between two
boulders is a real gap, not a thin joint line, and the recipe's own
surface numbers say so too, smooth 0.22 on the boulder faces against 0.1
in the recess.

Unlike a cut slab, a dry-laid boulder has an irregular, weathered edge, so
the 2x2 grid found here is run through lib.warp_labels the way
kythen_stone.py's own flecks are, natural stone rather than dressed.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_dry_stone"
CLS = "stone"
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
    row_mean = lum.mean(axis=1)
    col_mean = lum.mean(axis=0)
    print("row means:", np.round(row_mean, 3))
    print("col means:", np.round(col_mean, 3))
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    h, w = rgb.shape[:2]
    course, stone_width = 16, 16  # cultures/siku/materials.json's own numbers
    rows, cols = h // course, w // stone_width  # 2, 2
    print(f"masonry grid: {rows} courses x {cols} boulders = {rows * cols} boulders")

    r32 = np.arange(h)[:, None] // course
    c32 = np.arange(w)[None, :] // stone_width
    block_id = (r32 * cols + c32) + np.zeros((h, w), dtype=int)

    labels_hi = lib.warp_labels(block_id, size=SIZE, amp=3.0, seed=51, cells=8)
    edges = lib.region_edges(labels_hi)
    # A real gap needs a steep rise within a few texels for ao_from_height's own radius to
    # find it at all (checked by hand: a 16 texel wide taper spreads the whole rise so thin
    # that the local slope ao measures never clears 0.04, nowhere near the 0.35 target), so
    # this stays narrow. seam_n is reported and explained rather than chased by widening it
    # again: measured directly off the written _n map, the row128 course boundary (not the
    # wrap at all) is the single worst join on the whole tile, 0.134 against a mean of 0.026
    # across all 255 row joins and 255 column joins combined; with only two courses and two
    # boulders across, only two joins in each direction are ever more than background noise,
    # so the wrap join (one of those two) always reads large against a mean diluted by
    # roughly 250 near flat interior joins, however gently either joint itself is built. A
    # real gap between four dry laid boulders cannot also be a texture with no real joints in
    # it, which is what a seam_n near 1 here would mean.
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    gap = -(1.0 - t) * 2.1  # a real gap between unmortared boulders, not a thin joint

    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=52, gain=0.55) * 0.10
    pores = lib.blur(lib.white_noise(SIZE, seed=53), 1) * 0.10
    shape = 1.1 * t + gap + grain + pores
    height = lib.band(shape, 0.48)
    print(f"height sd {height.std():.4f}")

    # Smoothness: the recipe's own two numbers, face 0.22 against recess
    # 0.1, both comfortably inside stone's packed ceiling (0.12 + 0.25),
    # so the ordinary keep_mean path is left alone.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=54, gain=0.55)
    smooth = 0.5 * t + 0.5 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 145.0
    # fine_detail=1.0: the gap between two dry laid boulders is only four or five texels
    # wide, which pack()'s default fine_detail=0.35 damping (meant for texel scale noise
    # grain) crushed from a theoretical 0.02 to 0.85 height swing down to an actual 0.03 to
    # 0.55 (checked by hand against the written _n map, ao_min stuck at 0.62 to 0.72 across
    # every taper and gap magnitude tried). The gap is not grain here, it is the one real
    # joint the whole surface has, exactly the case the README names for this argument.
    fine_detail = 1.0
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
