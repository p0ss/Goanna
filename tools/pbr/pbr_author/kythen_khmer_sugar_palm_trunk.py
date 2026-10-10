"""Hand authored height and smoothness for kythen_khmer_sugar_palm_trunk, a
log side.

Column mean lum has a clear shape: columns 0 to 2 bright (about 0.22 to
0.25), columns 3 to 13 dead flat and dark (0.185, std 0.000 across all
eleven, a genuine wide furrow, not grain), a bright ridge at columns 15 to
18 (up to 0.248), then a slow fall back through the high twenties to meet
column 0 at the wrap (0.245 both sides, continuous). That is a trunk with
one broad smooth gap and one raised fibrous rib, read the same way as
kythen_khmer_dipterocarp_bark.py's furrow and ridge columns. Row mean and
row std are both nearly flat (0.20 to 0.22 everywhere), so the art itself
draws no horizontal ring banding; the brief calls for rings running around
the trunk regardless (frond base scars on a real sugar palm), so this adds
them as a built horizontal profile rather than reading them off the art,
narrow dips periodic down y with a sharp fibre tear on their lower edge and
a soft fade above.

The wide furrow drags the mean tilt down hard: it is 28 percent of the
tile's width, mostly flat floor far from either wall, so a slope that only
lives at the wall averages away over that much dead flat area. Rather than
force the depth up to compensate (normal_strength 60 was needed for that,
which read as an implausibly deep gouge), this adds fine vertical fibre
texture across the whole trunk, furrow floor included: bark fibre runs
everywhere on a real palm, not only on the ridges, and it lifts the area
averaged tilt without an extreme depth. That, plus the same no-pre-blur
unsharp mask used on the bark script for the furrow wall's own occlusion,
reaches target at normal_strength 30, the same value as the log script it
is built alongside.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_sugar_palm_trunk"
CLS_READ = lib.class_of(STEM, GAME)
CLS = "wood"
SIZE = lib.SIZE


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
          f"row std range {row_std.min():.3f} to {row_std.max():.3f} (no ring banding drawn)")
    print(f"class read back from the bake: {CLS_READ}; used here: {CLS} "
          "(fibrous palm trunk, not mineral stone)")

    furrow_thresh = 0.005
    is_furrow = col_std < furrow_thresh
    furrow_cols = np.where(is_furrow)[0]
    print("furrow columns (std < %.3f):" % furrow_thresh, furrow_cols.tolist(),
          f"({len(furrow_cols)} of {w}, {100.0 * len(furrow_cols) / w:.0f}% of the tile's width)")

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
            ridge_target[c] = -0.3
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

    step = target[labels_hi]
    wide = lib.blur(step, 2)
    layout = step + 1.5 * (step - wide)

    # Rings: frond base scars encircling the trunk, so they run along x (the
    # around-the-trunk axis on a side texture) and are periodic down y. Not
    # in the art's own row structure (see the docstring), so built as a
    # sharp edged dip with a soft fade above, the shape a real scar leaves.
    ring_count, ring_sharp, ring_amp = 6, 0.15, 0.25
    y = np.arange(SIZE)[:, None] / SIZE
    phase = (y * ring_count) % 1.0
    ring_profile = np.where(phase < ring_sharp, np.cos(np.pi * phase / ring_sharp), 1.0) * 0.5 + 0.5
    rings = np.broadcast_to((1.0 - ring_profile) * ring_amp, (SIZE, SIZE))

    # Fine vertical fibre across the whole trunk, furrow floor included;
    # see the docstring for why this replaces raw depth as the way to reach
    # the wood tilt target without an implausibly deep furrow.
    fibre = blur_axis(lib.fbm(SIZE, base_cells=48, octaves=3, seed=1006, gain=0.55), 3, 0) * 0.30
    grain = blur_axis(lib.fbm(SIZE, base_cells=18, octaves=3, seed=1002, gain=0.55), 12, 0) * 0.20
    crack = blur_axis(lib.blur(lib.white_noise(SIZE, seed=1003), 1), 3, 1) * 0.05 * t
    pores = blur_axis(lib.blur(lib.white_noise(SIZE, seed=1004), 1), 6, 0) * 0.03

    height = lib.normalise01(layout - rings + grain + fibre + crack + pores, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=14, octaves=3, seed=1005, gain=0.55), radius=6, axis=0)
    smooth = 0.55 * t + 0.35 * directional_rough + 0.15 * (1.0 - ring_profile)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 30.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength} ring_count={ring_count}")
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
