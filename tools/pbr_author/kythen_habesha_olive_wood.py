"""Hand authored height and smoothness for kythen_habesha_olive_wood.

32 px art of worked timber, not bark: eight columns, 0, 4, 8, 12, 16, 20,
24 and 28, sit at exactly 0.217 luminance in every one of their thirty two
texels, standard deviation 0.0 to the printed precision. That is not a
furrow read off a noisy trunk, it is eight perfectly regular, perfectly
flat, perfectly dark seams every four columns: plank joints, drawn as
straight lines, the masonry read the brief asks for. The three columns
between each pair of joints carry the timber face, luminance 0.336 to
0.353, standard deviation 0.007 to 0.020, close to flat as a column mean
but with real texel to texel variation inside it: the figure. Row mean
spread is only 0.017 against a column spread of 0.136, confirming the
joints are the whole story at the column-mean level and the figure does
not show up there at all, it lives below a single row or column average,
which is exactly where wavy grain should live: a straight streak and a
wavy one have the same column mean, they differ in how the streak's
position drifts as you follow it down the log.

So this script does not use default_tree.py's straight vertical furrow
technique for the figure (only for the joints, which really are straight).
For the grain, an isotropic lib.fbm field is stretched into streaks the
usual way, blur_axis along y, but the streaks are bent first: before that
stretch, the sampling coordinate is warped sideways (the cross grain axis,
x) by a slow, low amplitude lib.fbm offset field, so a streak's x position
drifts gently as y increases instead of running dead straight down its
column. This is a coordinate warp on a noise field, not lib.warp_labels on
a segmented region map, so it does not touch the "never warp dressed art"
rule; the joints themselves get no warp at all, amplitude 0, built with
straight, unwarped column edges the way default_tree.py's furrow is.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_olive_wood"
SIZE = lib.SIZE
SEED = 501


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a feature along the
    other axis. lib.blur does both axes; grain needs only one."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def repeat_columns(col_values, size):
    """Upscale a per-column array (labels or a continuous profile) to size
    x size with straight column edges and no row variation: np.repeat
    along x then broadcast down y. Gives the same straight-column result
    np.kron would, without kron. Used only for the joints here: the grain
    is warped, but the joints, genuinely straight in the art, are not."""
    n = col_values.shape[0]
    scale = size // n
    hi = np.repeat(col_values, scale)
    return np.broadcast_to(hi[None, :], (size, size)).copy()


def column_groups(col_mean, margin_frac):
    """Wrap-aware joint/plank column ids from the art's own column means,
    default_tree.py's read generalised to any margin as a share of the
    column mean's own spread."""
    n = col_mean.shape[0]
    spread = float(col_mean.max() - col_mean.min())
    margin = margin_frac * max(spread, 1e-6)
    is_joint = col_mean < (col_mean.min() + margin)
    joint_cols = np.where(is_joint)[0]
    col_id = np.zeros(n, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(n):
        if is_joint[x]:
            col_id[x] = -(1 + list(joint_cols).index(x))
            cur_id = None
        else:
            if cur_id is None:
                cur_id = next_id
                next_id += 1
            col_id[x] = cur_id
    if not is_joint[0] and not is_joint[-1] and col_id[0] != col_id[-1]:
        col_id[col_id == col_id[-1]] = col_id[0]
    return col_id, joint_cols


def stepped_layout(col_id, col_mean, joint_target, plank_range, edge_dist, size):
    """default_tree.py's stepped plateau plus matched-slope groove, built
    with repeat_columns instead of kron: flat masonry style joints, no
    warp amplitude anywhere in this construction. Returns the layout and
    t, the plank closeness (1 mid-plank, 0 right at a joint), so the grain
    warp below can be kept off the joints."""
    ids = sorted(set(col_id.tolist()))
    joint_ids = [c for c in ids if c < 0]
    plank_ids = [c for c in ids if c >= 0]
    plank_lum = {c: float(col_mean[np.where(col_id == c)[0]].mean()) for c in ids}
    plank_vals = np.array([plank_lum[c] for c in plank_ids]) if plank_ids else np.array([0.0])
    lo, hi = float(plank_vals.min()), float(plank_vals.max())
    target = {}
    for c in joint_ids:
        target[c] = joint_target
    for c in plank_ids:
        m = plank_lum[c]
        target[c] = plank_range[0] + (plank_range[1] - plank_range[0]) * (m - lo) / max(hi - lo, 1e-6)
    remap = {c: i for i, c in enumerate(sorted(target.keys()))}
    col_id_shifted = np.vectorize(remap.get)(col_id)
    target_arr = np.array([target[c] for c in sorted(target.keys())])

    labels_hi = repeat_columns(col_id_shifted, size)
    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=edge_dist)
    t = np.clip(dist / edge_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    step = target_arr[labels_hi]
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.9 * (narrow - wide)
    return layout, t


def sample_wrapped_bilinear(field, ys, xs, size):
    """Bilinear lookup into a tileable field at floating point, wrapped
    coordinates. Used to sample the isotropic grain field at a sideways
    warped position, the coordinate warp that bends the grain streaks."""
    x0 = np.floor(xs).astype(int) % size
    x1 = (x0 + 1) % size
    y0 = np.floor(ys).astype(int) % size
    y1 = (y0 + 1) % size
    fx = xs - np.floor(xs)
    fy = ys - np.floor(ys)
    a = field[y0, x0]
    b = field[y0, x1]
    c = field[y1, x0]
    d = field[y1, x1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def wavy_grain(size, base_cells, grain_radius, warp_cells, warp_amp, seed):
    """An isotropic fbm field, stretched into streaks along y the usual
    way, but with the sampling coordinate warped sideways first by a slow
    (low warp_cells), low amplitude fbm offset, so each streak's x
    position drifts gently as y increases: wavy figured grain rather than
    a dead straight one. A coordinate warp on this noise field, not
    lib.warp_labels on a label map."""
    y_idx, x_idx = np.mgrid[0:size, 0:size].astype(np.float32)
    warp_off = lib.fbm(size, base_cells=warp_cells, octaves=2, seed=seed + 8, gain=0.5) * warp_amp
    xw = (x_idx + warp_off) % size
    grain_iso = lib.fbm(size, base_cells=base_cells, octaves=3, seed=seed + 2, gain=0.55)
    grain_pre = sample_wrapped_bilinear(grain_iso, y_idx, xw, size)
    return blur_axis(grain_pre, radius=grain_radius, axis=0)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    n = src.shape[0]
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("lum min %.3f max %.3f mean %.3f sd %.3f" % (lum.min(), lum.max(), lum.mean(), lum.std()))
    col_mean = lum.mean(axis=0)
    col_std = lum.std(axis=0)
    row_mean = lum.mean(axis=1)
    row_std = lum.std(axis=1)
    print("column mean:", np.round(col_mean, 3).tolist())
    print("column std :", np.round(col_std, 3).tolist())
    print("row mean:", np.round(row_mean, 3).tolist())
    print("row std :", np.round(row_std, 3).tolist())
    print("column spread %.3f  row spread %.3f" %
            (col_mean.max() - col_mean.min(), row_mean.max() - row_mean.min()))

    margin_frac = 0.3
    col_id, joint_cols = column_groups(col_mean, margin_frac)
    print(f"margin_frac {margin_frac} -> joint columns {joint_cols.tolist()} of {n}: eight "
            "perfectly flat (std 0.0), perfectly regular, period-4 dark seams. Plank joints, "
            "not bark furrows: treated as a flat masonry groove, no warp amplitude.")

    # Flat, narrow joints: a deep, sharp cut, unwarped. The eight plank
    # faces differ only slightly in brightness (0.336 to 0.353), so the
    # plank_range gap is small, most of the visual interest is the grain.
    # edge_dist widened from 2 to 9: at 2 (under one art texel of the 256
    # map) the packer's own fine_detail damping, which specifically
    # flattens whatever varies at close to a one texel scale, ate most of
    # the joint's depth before ao and normal were derived from it, the
    # same failure salt_crust and incense_bark hit first (see those
    # scripts); ao_min read 0.51 even with a real, deep joint_target of
    # 0.05. Widened, the groove keeps enough of its depth through that
    # damping to actually occlude.
    layout, t = stepped_layout(col_id, col_mean, joint_target=0.05,
            plank_range=(0.55, 0.66), edge_dist=9, size=SIZE)

    # Wavy figured grain: see wavy_grain's own docstring for the warp.
    # warp_cells is low (slow: the bend drifts over tens of texels, not
    # every texel) and warp_amp is a few texels (low amplitude), so the
    # streaks bend rather than zigzag.
    grain = wavy_grain(SIZE, base_cells=16, grain_radius=16, warp_cells=3,
            warp_amp=7.0, seed=SEED) * 0.30

    # A second, finer wavy pass for the fine figure inside the grain,
    # same warp field so the fine detail bends with the coarse streaks
    # rather than crossing them.
    fine_grain = wavy_grain(SIZE, base_cells=30, grain_radius=6, warp_cells=3,
            warp_amp=7.0, seed=SEED + 20) * 0.10

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1)
    pores = blur_axis(pores_src, radius=3, axis=0) * 0.03

    # A scatter of small pits for a real self shadowing floor: the
    # narrow-wide matched slope groove on the joints alone left ao_min at
    # 0.51 (the same finding the three bark scripts made), because
    # normalise01's percentile clip is set by the grain and joint terms
    # together, not the joint floor alone. A few small worn knots and
    # pores on the plank faces (masked by t, none on the joints) give
    # ao_from_height real local drops to find.
    def dome_stamp(radius, amp):
        d = np.arange(-radius, radius + 1, dtype=np.float32)
        dy, dx = np.meshgrid(d, d, indexing="ij")
        r = np.sqrt(dx ** 2 + dy ** 2)
        dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, radius) / radius)), 0.0)
        return (amp * dome).astype(np.float32)

    def scatter_pits(size, count, seed, radius_range, amp_range):
        rng = np.random.default_rng(seed)
        field = np.zeros((size, size), dtype=np.float32)
        cx = rng.integers(0, size, count)
        cy = rng.integers(0, size, count)
        radius = rng.integers(radius_range[0], radius_range[1] + 1, count)
        amp = rng.uniform(amp_range[0], amp_range[1], count)
        for i in range(count):
            r = int(radius[i])
            stamp = dome_stamp(r, amp[i])
            ys = (np.arange(-r, r + 1) + cy[i]) % size
            xs = (np.arange(-r, r + 1) + cx[i]) % size
            idx = np.ix_(ys, xs)
            field[idx] = np.minimum(field[idx], stamp)
        return field

    pit_count, pit_radius, pit_amp = 90, (2, 4), (-0.6, -0.25)
    pits = scatter_pits(SIZE, pit_count, seed=SEED + 9, radius_range=pit_radius, amp_range=pit_amp)
    print(f"scattered pits: {pit_count}, radius {pit_radius}, amp {pit_amp}")

    # Grain, fine figure, pores and pits are all kept off the joints
    # (scaled by t): the joint is a flat masonry groove, not timber, so it
    # gets none of the plank face's texture.
    height = lib.normalise01(layout + (grain + fine_grain + pores + pits) * t, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the joint/plank closeness (dusty in the seam,
    # worn smoother on the plank face) plus the same wavy grain field, so
    # the figure that catches the light lines up with the figure in the
    # height map, and its own modest directional variation.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 5, gain=0.55), radius=8, axis=0)
    grain_z = (grain - grain.mean()) / (grain.std() + 1e-6)
    smooth = 0.45 * t + 0.20 * grain_z * t + 0.25 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 16.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=n)
    print(f"normal_strength={normal_strength}  fine_detail=0.35 (default)")
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
