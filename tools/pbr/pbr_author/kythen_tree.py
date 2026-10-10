"""Hand authored height and smoothness for kythen_tree, a log side.

Sixteen columns of bark, almost no horizontal structure: every row mean
sits close together, so whatever the art is doing runs along x, the log's
length, not around it. Column mean luminance ranges 0.227 to 0.300; three
columns sit within 0.03 of the darkest, 1, 6 and 8 to 9 (8 and 9 both
low, a two column furrow), a clear step down from every ridge column
(next candidate is column 12 at 0.266, 0.039 above the darkest, on the
ridge side). That gives three furrows: a narrow one at column 1, a narrow
one at column 6, and a two column wide one at 8 to 9, cutting the ring
into three ridges of four, one and seven columns (the seven column ridge
wraps past column 15 back to column 0).
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_tree"
SIZE = lib.SIZE
SEED = 501


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a feature along the
    other axis. lib.blur does both axes; grain and furrows need only one."""
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
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    col_mean = lum.mean(axis=0)
    print("column mean lum:", np.round(col_mean, 3))

    margin = 0.03
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
            ridge_target[c] = 0.10
        else:
            ridge_target[c] = 0.55 + 0.30 * (m - lo) / max(hi - lo, 1e-6)
    target = np.array([ridge_target[c] for c in range(-len(furrow_cols), n_ridges)])
    labels16_shifted = labels16 + len(furrow_cols)

    # Straight column edges: a bark furrow runs the length of the log as a
    # straight channel, not a wandering natural boundary.
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

    # A slow bulge crowns the widest ridge (the seven column run wrapping
    # past the seam), faded out at the furrow edges so it never reopens
    # the groove's matched slope.
    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=SEED + 1) * 0.20
    layout = layout + crown * t

    # Grain: bark fibre running the length of the log, the y axis of a side
    # texture, an isotropic field blurred along y only.
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.24

    crack_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    crack = blur_axis(crack_src, radius=3, axis=1) * 0.05 * t

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1)
    pores = blur_axis(pores_src, radius=8, axis=0) * 0.03

    height = lib.normalise01(layout + grain + crack + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 5, gain=0.55), radius=8, axis=0)
    smooth = 0.55 * t + 0.45 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 30.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
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
