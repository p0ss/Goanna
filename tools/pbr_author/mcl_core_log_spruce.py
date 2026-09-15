"""Hand authored height and smoothness for mcl_core_log_spruce, scaly bark.

Same column analysis again. Spruce's columns are all close together in
brightness, 0.15 to 0.27, with no single column standing out as clearly as
default_tree's column 3 or big_oak's columns 3 and 15: the darkest, flattest
run is column 15 (0.149, std 0.012), but columns 0, 3 and 7 sit within 0.03
of it too (0.171, 0.175, 0.167, std 0.012 to 0.030) and columns 6, 12 and 14
are only a little further (0.196 to 0.201, std 0.047 to 0.059). A margin of
0.055 catches all seven. Column 15 and 0 are adjacent so they merge, and
column 6 and 7 are adjacent so they merge too: five furrow bands from seven
columns, most of them one column wide, cutting the ring into five narrow
ridges of two, two, four and one columns. That is a scaly read rather than a
couple of deep grooves: more numerous, narrower plates than the other three
species, each catching its own sliver of light, which is the difference
between a furrowed bark and an overlapping one.

The top texture (mcl_core_log_spruce_top.py) shares this script's seed.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_log_spruce"
CLS = lib.class_of(STEM)
SIZE = lib.SIZE
SEED = 301


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

    margin = 0.055
    is_furrow = col_mean < (col_mean.min() + margin)
    furrow_cols = np.where(is_furrow)[0]
    print("furrow columns:", furrow_cols.tolist())

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
            ridge_target[c] = 0.12
        else:
            ridge_target[c] = 0.55 + 0.25 * (m - lo) / max(hi - lo, 1e-6)
    target = np.array([ridge_target[c] for c in range(-len(furrow_cols), n_ridges)])
    labels16_shifted = labels16 + len(furrow_cols)

    labels_hi = np.kron(labels16_shifted, np.ones((16, 16), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 5
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)

    # Ridges here are narrow (two to four columns), too narrow for a wide
    # crown bulge to read as anything but noise, so it is small and tight.
    crown = lib.fbm(SIZE, base_cells=6, octaves=2, seed=SEED + 1) * 0.10
    layout = layout + crown * t

    # Grain still runs the length of the log, but shorter and tighter than
    # oak's: a plate of scaly bark does not carry a fibre the whole height
    # of the tile the way a deep furrow's ridge does.
    grain_src = lib.fbm(SIZE, base_cells=26, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=8, axis=0) * 0.16

    crack_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    crack = blur_axis(crack_src, radius=2, axis=1) * 0.05 * t

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1)
    pores = blur_axis(pores_src, radius=6, axis=0) * 0.025

    height = lib.normalise01(layout + grain + crack + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 5, gain=0.55), radius=8, axis=0)
    smooth = 0.55 * t + 0.45 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 26.0
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
