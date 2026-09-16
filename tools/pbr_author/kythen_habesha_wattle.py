"""Hand authored LabPBR height and smoothness for kythen_habesha_wattle, a
woven wattle panel: withies woven over and under, a basket weave.

lib.class_of reads "leaves" for this stem (printed below, on the record).
That reading does not fit what the 32 px art actually shows. Every one of
its six colours is a warm brown (r > g > b throughout, luminance 0.123 to
0.370), nothing green or leaf coloured at any point, and the row and
column means both show the same sharp period 4 pattern: texels at row % 4
== 0 sit at 0.183 to 0.194, then climb through three brighter steps to a
local peak just before the next such row, and columns do exactly the same
thing at col % 4 == 0. That is a crisp, regular grid of dark lines running
both ways across the tile, eight cells by eight cells, not a scattered or
organic pattern the way foliage art in this game reads elsewhere (compare
kythen_habesha_fig_leaf or kythen_habesha_coffee_leaf, both irregular
blotches, no grid). A geometric brown lattice is a woven panel, not
leaves, so "wood" (tilt target 18 to 28) is used for pack and check below
instead of class_of's reading, on the strength of the colour and the grid
alone; wood's own smoothness level fits an oiled or weathered withy far
better than the leaf class's would.

The grid's cells (the 3 by 3 texel squares between the dark lines) carry
no consistent brightness split between "over" and "under": grouping the
32 cells into a checkerboard by (row band + column band) parity and
comparing means gives 0.333 against 0.333, no difference at all. So the
art draws the weave's grid, the withies' own edges, but not which strand
passes over which at each crossing; that is invented here, the way the
brief expects, using the standard basket weave rule (the strand direction
alternates by cell parity) so the alternation is at least the real over
under rule a basket follows, not an arbitrary choice. The grid lines
themselves are straight, not warped: a regular, dressed period 4 lattice
is a woven, manufactured surface, the same reasoning timber_laced.py gives
for not warping its own lattice.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_wattle"


def smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


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
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    uniq = sorted(set(np.round(lum.ravel(), 3).tolist()))
    print("unique shades:", uniq)
    class_of_reads = lib.class_of(STEM, GAME)
    print(f"lib.class_of reads: {class_of_reads} (overridden to 'wood' below, see module docstring)")

    for tol in (0.03, 0.06, 0.1):
        seg_labels, n = lib.segments(rgb, tolerance=tol)
        sizes = sorted([int((seg_labels == i).sum()) for i in range(n)], reverse=True)
        print(f"lib.segments tolerance {tol}: {n} regions, sizes {sizes[:10]}"
              f"{' ...' if len(sizes) > 10 else ''}")

    h, w = lum.shape
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("col means:", np.round(lum.mean(axis=0), 3))

    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    print(f"colour check: r>g everywhere {bool((r >= g).all())}, "
          f"g>=b everywhere {bool((g >= b).all())} (a uniformly warm, brown palette)")

    groove_row = (np.arange(h) % 4 == 0)
    groove_col = (np.arange(w) % 4 == 0)
    groove_mask = np.zeros((h, w), dtype=bool)
    groove_mask[groove_row, :] = True
    groove_mask[:, groove_col] = True
    print(f"groove texels (row or col % 4 == 0): {int(groove_mask.sum())} of {groove_mask.size}, "
          f"mean lum {lum[groove_mask].mean():.3f} versus {lum[~groove_mask].mean():.3f} elsewhere")

    n_cells = h // 4
    cell_lum = np.zeros((n_cells, n_cells))
    for rb in range(n_cells):
        for cb in range(n_cells):
            rows = [rb * 4 + 1, rb * 4 + 2, rb * 4 + 3]
            cols = [cb * 4 + 1, cb * 4 + 2, cb * 4 + 3]
            cell_lum[rb, cb] = lum[np.ix_(rows, cols)].mean()
    even = cell_lum[(np.add.outer(np.arange(n_cells), np.arange(n_cells)) % 2) == 0]
    odd = cell_lum[(np.add.outer(np.arange(n_cells), np.arange(n_cells)) % 2) == 1]
    print(f"checkerboard cell means: even parity {even.mean():.3f}, odd parity {odd.mean():.3f} "
          "(no real difference: the over/under alternation is invented below, not read off the art)")

    SIZE = lib.SIZE
    scale = SIZE // h
    groove_hi = np.repeat(np.repeat(groove_mask, scale, axis=0), scale, axis=1)

    # Cell parity decides which strand shows on top at that crossing, the
    # standard basket weave rule: (row band + column band) even means the
    # horizontal strand is uppermost there, odd means the vertical one is.
    row_band = np.arange(SIZE) // (4 * scale)
    col_band = np.arange(SIZE) // (4 * scale)
    parity = (row_band[:, None] + col_band[None, :]) % 2
    horizontal_on_top = parity == 0

    over_level = 0.80
    under_level = 0.60
    strand_level = np.where(horizontal_on_top, over_level, under_level)

    # Straight, unwarped edges: a regular, dressed lattice, not natural
    # stone, the same reasoning timber_laced.py gives for its own grid.
    # A wide ramp with a little coherent wobble, the same trick
    # timber_laced.py and default_stone_brick.py both use on their own
    # joints, so the transition's steepest point does not land on the same
    # row or column for every crossing: without it the wrap, where a row
    # groove and a column groove both fall on row 0 and column 0 at once,
    # reads as a much sharper step than an ordinary interior crossing.
    edge = lib.region_edges(groove_hi.astype(int))
    max_dist = 6
    dist0 = lib.distance_to_edge(edge, max_dist=max_dist)
    wobble = lib.fbm(SIZE, base_cells=48, octaves=2, seed=81) * 2.5
    dist = np.where(groove_hi, 0.0, np.clip(dist0 + wobble, 0.0, max_dist))
    t = smoothstep(dist / max_dist)
    groove_level = 0.10
    ramped = groove_level + (strand_level - groove_level) * t
    layout = np.where(groove_hi, groove_level, ramped)

    # A very slight rounded cross section along each strand's own width,
    # a withy is a rounded rod, not a flat ribbon, kept low: this is a
    # dressed weave, not a cobble.
    crown = lib.fbm(SIZE, base_cells=8, octaves=2, seed=82) * 0.03
    layout = layout + crown * t

    # Directional grain along each strand's own run: horizontal cells get
    # grain blurred along x, vertical cells get grain blurred along y, the
    # same blur_axis default_tree.py uses for bark, applied per cell.
    grain_x_src = lib.fbm(SIZE, base_cells=24, octaves=3, seed=83, gain=0.55)
    grain_y_src = lib.fbm(SIZE, base_cells=24, octaves=3, seed=84, gain=0.55)
    grain_x = blur_axis(grain_x_src, 8, axis=1) * 0.04
    grain_y = blur_axis(grain_y_src, 8, axis=0) * 0.04
    grain = np.where(horizontal_on_top, grain_x, grain_y)

    pores = lib.blur(lib.white_noise(SIZE, seed=85), 1) * 0.02

    height = lib.normalise01(layout + grain + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: the groove gathers dust and stays rough,
    # the strand tops are what hands and weather smooth, with the wood's
    # own patchy variation riding on top.
    rough_noise = lib.fbm(SIZE, base_cells=20, octaves=3, seed=86)
    smooth = 0.55 * height + 0.45 * rough_noise
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 14
    cls = "wood"
    # The default fine_detail (0.35) damps the groove along with any texel
    # scale grit, since the groove is only one art texel wide; that is
    # real joint structure here, not rubble grain, so it keeps its depth
    # with fine_detail 0.7 instead of the default, the way mcl_core_iron_ore
    # keeps its own texel scale nodule detail at 1.0 for the same reason.
    fine_detail = 0.7
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0],
            fine_detail=fine_detail)
    print(f"normal_strength={normal_strength}, fine_detail={fine_detail}, "
          f"class used for pack/check: {cls}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
