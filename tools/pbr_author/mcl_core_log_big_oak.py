"""Hand authored height and smoothness for mcl_core_log_big_oak, dark oak bark.

Same column analysis as default_tree.py, transposed to this art. Column 3
is the darkest and flattest (mean 0.141, std 0.018), column 15 almost as
flat and nearly as dark (0.148, std 0.023): two clean furrows, this time on
their own rather than sharing a wrap-wide band. Everything else on this
texture carries much more streak than default_tree's did, std 0.05 to 0.08
throughout instead of settling into a couple of wide calm ridges, which is
the art drawing oak's own reputation: not a couple of grooves in an
otherwise even bark but furrowed all over. A margin of 0.06 above the
darkest column also catches columns 7, 10 and 11 (0.193, 0.191, 0.184),
columns 10 and 11 adjacent so they merge into one two wide furrow: four
furrow bands in total, cutting the ring into four ridges of three, three,
two and three columns.

The top texture (mcl_core_log_big_oak_top.py) shares this script's seed.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_log_big_oak"
CLS = lib.class_of(STEM)
SIZE = lib.SIZE
SEED = 201


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

    margin = 0.06
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
            ridge_target[c] = 0.08
        else:
            ridge_target[c] = 0.55 + 0.30 * (m - lo) / max(hi - lo, 1e-6)
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

    # Narrower ridges here than on default_tree, so a gentler crown: oak's
    # own furrows already carry most of the relief.
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=SEED + 1) * 0.16
    layout = layout + crown * t

    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.20

    # Fine cracking across the ridges, a touch stronger than default_tree's:
    # deep bark checks the way old oak splits.
    crack_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    crack = blur_axis(crack_src, radius=3, axis=1) * 0.06 * t

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1)
    pores = blur_axis(pores_src, radius=8, axis=0) * 0.03

    height = lib.normalise01(layout + grain + crack + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

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
