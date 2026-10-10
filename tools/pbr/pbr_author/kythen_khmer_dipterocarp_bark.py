"""Hand authored height and smoothness for kythen_khmer_dipterocarp_bark, a
log side.

The 32 px art carries no row to row structure at all (row mean lum sits
within 0.287 to 0.299 everywhere, row std almost constant near 0.03): the
art does nothing along y. Column mean lum is close across the board too
(0.25 to 0.31, no wide dark furrow the way default_tree.py's oak has), but
column standard deviation splits cleanly: nine columns sit under 0.02
(several exactly 0.000, dead flat top to bottom) against the rest at 0.03
to 0.05 (real vertical grain). A flat column amid streaky ones is a furrow
cut smooth, the same test default_tree.py uses, just without default_tree's
extra darkening; these furrows are drawn as smooth, not shaded. Built the
same way as default_tree.py, sharp columns of furrow and ridge with grain
running along y, but with two changes measured against it directly:

  1. default_tree.py's own unsharp mask (blur radius 1, then radius 2)
     measures ao_min 0.50 on its own log side, short of the jointed target.
     Skipping the first blur (no pre-smoothing at all, an unsharp mask off
     the raw step) drops this script's ao_min to 0.22: the horizon based
     occlusion needs a wall that rises within a texel or two, and any
     pre-blur, however small, was enough to round that corner away.
  2. With the sharper wall, hitting the wood tilt target (18 to 28 deg)
     needs normal_strength 30, matching default_tree.py's own value.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_dipterocarp_bark"
CLS_READ = lib.class_of(STEM, GAME)
CLS = "wood"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a feature along the
    other axis, the same helper default_tree.py defines locally."""
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
    w = lum.shape[1]
    col_mean = lum.mean(axis=0)
    col_std = lum.std(axis=0)
    row_mean = lum.mean(axis=1)
    row_std = lum.std(axis=1)
    print("column mean lum:", np.round(col_mean, 3).tolist())
    print("column std lum:", np.round(col_std, 3).tolist())
    print(f"row mean lum range {row_mean.min():.3f} to {row_mean.max():.3f}, "
          f"row std range {row_std.min():.3f} to {row_std.max():.3f} (no row to row structure)")
    print(f"class read back from the bake: {CLS_READ}; used here: {CLS} "
          "(fibrous bark, not mineral stone; 'bark' is not in class_of's name hints)")

    furrow_thresh = 0.02
    is_furrow = col_std < furrow_thresh
    furrow_cols = np.where(is_furrow)[0]
    print("furrow columns (std < %.2f):" % furrow_thresh, furrow_cols.tolist())

    col_id = np.zeros(w, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(w):
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
    print("ridge count:", n_ridges)

    labels16 = np.broadcast_to(col_id[None, :], (w, w)).copy()
    ridge_lum = {}
    for c in set(col_id.tolist()):
        cols = np.where(col_id == c)[0]
        ridge_lum[c] = col_mean[cols].mean()
    ridge_means = np.array([v for k, v in ridge_lum.items() if k >= 0])
    lo, hi = ridge_means.min(), ridge_means.max()
    ridge_target = {}
    for c, mv in ridge_lum.items():
        if c < 0:
            ridge_target[c] = -0.4
        else:
            ridge_target[c] = 0.6 + 0.6 * (mv - lo) / max(hi - lo, 1e-6)
    target = np.array([ridge_target[c] for c in range(-len(furrow_cols), n_ridges)])
    labels16_shifted = labels16 + len(furrow_cols)

    scale = SIZE // w
    labels_hi = np.kron(labels16_shifted, np.ones((scale, scale), dtype=int))
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    # No pre-blur before the unsharp mask: see the module docstring for the
    # ao_min measurement that drove this. wide is still blurred, so the
    # crown itself is gentle; only the furrow wall stays sharp.
    step = target[labels_hi]
    wide = lib.blur(step, 2)
    layout = step + 1.5 * (step - wide)

    crown = lib.fbm(SIZE, base_cells=4, octaves=2, seed=901) * 0.20
    layout = layout + crown * t

    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=902, gain=0.55)
    grain = blur_axis(grain_src, radius=14, axis=0) * 0.24

    crack_src = lib.blur(lib.white_noise(SIZE, seed=903), 1)
    crack = blur_axis(crack_src, radius=3, axis=1) * 0.05 * t

    pores_src = lib.blur(lib.white_noise(SIZE, seed=904), 1)
    pores = blur_axis(pores_src, radius=8, axis=0) * 0.03

    height = lib.normalise01(layout + grain + crack + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=905, gain=0.55), radius=8, axis=0)
    smooth = 0.55 * t + 0.45 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 30.0
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
