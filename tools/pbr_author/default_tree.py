"""Hand authored height and smoothness for default_tree, an oak-like log side.

Sixteen columns of bark, no horizontal structure at all: every row mean sits
within 0.27 to 0.33, so whatever the art is doing it is doing along x, not y.
Column 3 is dead flat, 0.225 in every one of its sixteen texels (std 0.000):
that is not grain, it is a furrow cut straight down the log. Column 15 is
nearly as flat (std 0.018) and darker still, 0.178, with column 0 close
behind it (std 0.028, 0.244) and only a touch of texture. Everything else
carries real vertical streakiness, std 0.045 or higher, the ordinary
variation of bark colour along the grain, brightest around columns 5 to 8
(0.37 to 0.38). So this tile has two furrows: a wide, shallow one spanning
the wrap seam (columns 15 and 0 together) and a narrow, deep one at column
3, cutting the ring into three bark ridges of two, eight and two columns.

The top texture (default_tree_top.py) shares this script's seed so the cut
end's bark ring reads as the same bark as this side.
"""

import sys

import numpy as np

import lib

STEM = "default_tree"
CLS = lib.class_of(STEM)
SIZE = lib.SIZE
SEED = 101


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a feature along the
    other axis. lib.blur does both axes; grain and cracks need only one."""
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
    col_mean = lum.mean(axis=0)
    col_std = lum.std(axis=0)
    print("column mean lum:", np.round(col_mean, 3))
    print("column std lum:", np.round(col_std, 3))

    # A furrow is a column that is both dark and nearly constant top to
    # bottom, the way an artist paints a groove: one flat shade, not grain.
    # 0.075 above the darkest column catches 0, 3, 12(none here) and 15
    # and excludes every streaky ridge column (next candidate is column 6
    # at 0.268, mean+0.090, clearly on the ridge side).
    margin = 0.075
    is_furrow = col_mean < (col_mean.min() + margin)
    furrow_cols = np.where(is_furrow)[0]
    print("furrow columns:", furrow_cols.tolist())

    # Collapse into runs of columns, the same wrap-aware merge the planks
    # script uses for rows: each furrow column its own id, each run of ridge
    # columns between furrows one id, the run either side of the column 0
    # to 15 wrap stitched together if neither end is itself a furrow.
    col_id = np.zeros(16, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(16):
        if is_furrow[x]:
            col_id[x] = -(1 + list(furrow_cols).index(x))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            col_id[x] = cur_id
    if not is_furrow[0] and not is_furrow[-1] and col_id[0] != col_id[-1]:
        col_id[col_id == col_id[-1]] = col_id[0]
    n_ridges = len(set(col_id[col_id >= 0].tolist()))
    print("column ids:", col_id.tolist())

    labels16 = np.broadcast_to(col_id[None, :], (16, 16)).copy()
    ridge_lum = {}
    for c in set(col_id.tolist()):
        cols = np.where(col_id == c)[0]
        ridge_lum[c] = col_mean[cols].mean()
    ridge_means = np.array([v for k, v in ridge_lum.items() if k >= 0])
    lo, hi = ridge_means.min(), ridge_means.max()
    ridge_target = {}
    for c, m in ridge_lum.items():
        if c < 0:
            ridge_target[c] = 0.10
        else:
            ridge_target[c] = 0.55 + 0.30 * (m - lo) / max(hi - lo, 1e-6)
    target = np.array([ridge_target[c] for c in range(-len(furrow_cols), n_ridges)])
    labels16_shifted = labels16 + len(furrow_cols)

    # Straight column edges, not warped: a bark furrow runs the length of
    # the log as a straight channel, the same reasoning the planks script
    # gives for kron on a joint that is genuinely straight.
    labels_hi = np.kron(labels16_shifted, np.ones((16, 16), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 5
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # The plateau: a step per column group, unsharpened into a groove with a
    # matched slope on both sides of every crossing, including the one that
    # lands on the wrap (see mcl_core_planks_big_oak.py for why this avoids
    # a seam kink).
    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # A slow bulge crowns the widest ridge (the eight column run between the
    # two furrows), faded to nothing at the furrow edges so it never reopens
    # the groove's matched slope.
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=SEED + 1) * 0.20
    layout = layout + crown * t

    # Grain: bark fibre running the length of the log, which is the y axis
    # of a side texture. An isotropic field blurred along y only stretches
    # it into vertical streaks without touching the furrow spacing, which is
    # already set along x.
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.24

    # Fine cracking across the ridges: a short, faint texture running the
    # other way, only on the ridge tops (scaled by t) since the furrow floor
    # is already the lowest point and does not need its own cracks.
    crack_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    crack = blur_axis(crack_src, radius=3, axis=1) * 0.05 * t

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1)
    pores = blur_axis(pores_src, radius=8, axis=0) * 0.03

    height = lib.normalise01(layout + grain + crack + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows distance from the furrow (rough down in the groove,
    # worn smoother on the ridge tops) plus its own directional streakiness.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 5, gain=0.55), radius=8, axis=0)
    smooth = 0.55 * t + 0.45 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 30.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS, normal_strength=normal_strength)
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
