"""Hand authored LabPBR height and smoothness for mcl_farming_hayblock_side.

Column means alternate cleanly, odd columns brighter than both neighbours
at every position (0.480, 0.450, 0.417, 0.532, 0.474, 0.462, 0.404, 0.510
against 0.396, 0.349, 0.343, 0.363, 0.391, 0.350, 0.362, 0.343 on the even
columns beside them): sixteen texel wide stalks of bundled straw, each its
own strip running the full height of the tile, the bright column its lit
face and the dark column beside it the shadowed gap to its neighbour. That
is a profile across the columns, the same idea as sandstone's beds across
its rows, not a set of regions, so it is built from the column means
directly rather than from lib.segments.

Two rows break that pattern: row 4 (mean lum 0.248) and row 11 (0.215) are
far darker than any neighbouring row (0.40 to 0.49 elsewhere) and, unlike
the stalk columns, dark at every column, not just the even ones. That is
the baling twine, wrapped around the bundle at roughly the third points of
its height, recessed a band across every stalk rather than belonging to
any one of them.
"""
import sys

import numpy as np

import lib

STEM = "mcl_farming_hayblock_side"
CLS = "leaves"
SIZE = lib.SIZE
BAND_ROWS = [4, 11]


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_means = lum.mean(axis=0)
    print("col means:", np.round(col_means, 3).tolist())
    row_means = lum.mean(axis=1)
    print("row means:", np.round(row_means, 3).tolist())

    # Sixteen individual stalk strips, one texel wide, each its own target
    # height from its own column brightness: a warp gives the strip edges
    # the irregular, slightly bulging silhouette of real bundled straw
    # rather than the ruled columns of the source grid.
    col_id = np.broadcast_to(np.arange(16)[None, :], (16, 16)).copy()
    col_hi = lib.warp_labels(col_id, amp=2.0, seed=91, cells=16)
    lo, hi = col_means.min(), col_means.max()
    col_target = 0.30 + 0.55 * (col_means - lo) / max(hi - lo, 1e-6)

    # A step per stalk, turned into a shared ramp by an unsharp mask rather
    # than tapering each stalk from its own centre: the same reasoning as
    # mcl_core_planks_big_oak, a matched slope either side of every stalk
    # boundary including the one that lands on the wrap, column 255 to 0.
    step = col_target[col_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 3)
    layout = narrow + 1.1 * (narrow - wide)

    # The twine bands: a recess across every stalk, found by row rather
    # than by the warped column labels, since a wrapped band does not
    # follow a single stalk's own bulge.
    band_row = np.zeros((16, 16), dtype=bool)
    band_row[BAND_ROWS, :] = True
    band_hi = lib.upscale(band_row.astype(np.float32), smooth=False)
    band_t = lib.blur(band_hi, 3)
    layout = layout * (1 - band_t) + 0.18 * band_t

    # Straw fibre: fine noise stretched along the stalks (vertical, axis 0,
    # the direction the columns already run) for the fly ends and stray
    # texture a bundle has, plus sparse unstretched pores for chaff.
    fibre = blur_axis(lib.fbm(SIZE, base_cells=28, octaves=3, seed=92, gain=0.55), radius=10, axis=0) * 0.08
    chaff = lib.blur(lib.white_noise(SIZE, seed=93), 1) * 0.03
    layout = layout + fibre * (1 - band_t) + chaff

    height = lib.normalise01(layout, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: straw is dull and fibrous everywhere, a touch duller and
    # more even under the twine where it is compressed and worn.
    rough_noise = blur_axis(lib.fbm(SIZE, base_cells=20, octaves=3, seed=94, gain=0.55), radius=8, axis=0)
    smooth = 0.5 * (1 - band_t) + 0.5 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 14.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
