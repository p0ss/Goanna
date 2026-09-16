"""Hand authored LabPBR height and smoothness for kythen_habesha_thatch.

The 32 px art is a fine dither in six close shades (0.350 to 0.610), no
large drawn blotches to segment. Column means are almost uniform (0.52 to
0.54) except columns 7 to 10 and 23 to 26, which sit noticeably higher
(0.559) and never reach the art's two darkest shades at all: two four
texel wide bands, spaced sixteen columns apart, that read as wooden
battens laid over the thatch to hold it down, distinct from the bundled
straw around them. Row means carry one clear dip, centred near row 20
(0.496 to 0.506 against a background around 0.54 to 0.56), a shadowed band
where one course of thatch overlaps the course below it.

Built as vertical grain (stalks run down the log the way default_tree.py's
bark grain runs down it, blur_axis stretched along y) for the loose straw,
a flat, slightly proud band for the two batten columns (no straw texture
there, matching the art's own flatter, never-fully-dark reading), and a
single wrapped cosine dip for the course overlap shadow, which reads as one
band in this tile and repeats correctly at the row wrap because a cosine
over one full period is exactly tileable.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_thatch"
CLS = lib.class_of(STEM, GAME)


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, the same helper default_tree.py
    uses to stretch grain along the length of a log."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def dist_to_edge_1d(mask, max_dist):
    """distance_to_edge restricted to one axis (columns), for a mask that
    is uniform down every column: the battens run the full height of the
    tile, so only the column direction carries a boundary to taper."""
    edge = (mask != np.roll(mask, 1, axis=1)).astype(np.float32)
    edge = np.maximum(edge, (mask != np.roll(mask, -1, axis=1)).astype(np.float32))
    d = np.full(mask.shape, float(max_dist), dtype=np.float32)
    d[edge > 0.5] = 0.0
    for _ in range(max_dist):
        nd = np.minimum(d, np.roll(d, 1, axis=1) + 1)
        nd = np.minimum(nd, np.roll(d, -1, axis=1) + 1)
        if np.array_equal(nd, d):
            break
        d = nd
    return d


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}, class_of reads {CLS}")

    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    print("column means:", np.round(col_mean, 3))
    print("row means:", np.round(row_mean, 3))

    SIZE = lib.SIZE
    scale = SIZE // src.shape[0]

    art_cols = np.arange(src.shape[0])
    batten_art = ((art_cols % 16) >= 7) & ((art_cols % 16) <= 10)
    print("batten columns (art space):", art_cols[batten_art].tolist())
    batten_hi = np.repeat(batten_art, scale)[None, :].repeat(SIZE, axis=0)

    dist = dist_to_edge_1d(batten_hi, 6)
    t_batten = np.clip(dist / 6, 0.0, 1.0)
    t_batten = t_batten * t_batten * (3 - 2 * t_batten)
    # Flat and slightly proud: a lashed pole sits on top of the straw, not
    # textured like the loose stalks either side of it.
    batten_height = np.where(batten_hi, 0.62 + 0.15 * t_batten, 0.0)

    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=901, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.30
    fine_src = lib.fbm(SIZE, base_cells=48, octaves=2, seed=902, gain=0.5)
    fine = blur_axis(fine_src, radius=4, axis=0) * 0.14

    # One wrapped cosine period puts the shadow at art row 20 and tiles
    # exactly, since a single cosine cycle across the tile height has no
    # discontinuity at the wrap.
    rows = np.arange(SIZE)[:, None]
    shadow = 0.5 * (1.0 + np.cos(2 * np.pi * (rows / SIZE * src.shape[0] - 20) / src.shape[0]))
    course_shadow = -0.22 * shadow

    stalks = 0.5 + grain + fine + course_shadow
    height_full = np.where(batten_hi, batten_height, stalks)
    height = lib.normalise01(height_full, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    rough_noise = lib.fbm(SIZE, base_cells=18, octaves=3, seed=903)
    smooth = 0.4 * height + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 22
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
