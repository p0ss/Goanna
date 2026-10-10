"""Hand authored height and smoothness for kythen_habesha_incense_bark.

32 px art, busier and higher contrast than fig bark: luminance 0.396 to
0.577, mean 0.542, sd 0.051. Column mean spread 0.102 against row mean
spread 0.040, so the family's column direction signal holds, but the row
spread is unusually large for this family too (row std 0.037 to 0.060
everywhere, no row anywhere near flat), which says there is real horizontal
structure here as well as vertical, not the clean furrow-only read
default_tree.py's oak gives.

Two adjacent columns, 20 and 21 (mean 0.474 and 0.471), sit clearly below
every other column; the next lowest are 0.504 to 0.523 at columns 0, 1, 9
to 12, 19, 22, 30 and 31, a full 0.03 to 0.05 higher, not close enough to
read as the same feature. So there is exactly one real furrow, columns 20
and 21, cutting the ring into one wide ridge (everything else), not the
many-column layout default_tree.py finds on the oak.

That wide ridge is not uniform, though: rows 20 to 23 read distinctly
flatter and brighter (row std 0.037 to 0.042, mean 0.556 to 0.560) than
rows 14 to 18 around them (std 0.058 to 0.060). A flat, calmer band sitting
inside an otherwise busier field is what a peeled patch looks like from
above, the bark's outer layer lifted away to show smoother inner bark
underneath, not a furrow and not scattered pores. This script finds that
kind of patch directly rather than assuming the row band's exact location:
texels distinctly brighter than their own local neighbourhood average,
warped into organic blobs the way mcl_core_log_birch.py's lenticels are,
each raised on one side and receded on the other like a lifted flake, on
top of the single real furrow and the ridge's own column banding.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_incense_bark"
SIZE = lib.SIZE
SEED = 301


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


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def repeat_columns(col_values, size):
    """Upscale a per-column array (labels or a continuous profile) to size
    x size with straight column edges and no row variation: np.repeat
    along x then broadcast down y. Gives the same straight-column result
    np.kron would, without kron."""
    n = col_values.shape[0]
    scale = size // n
    hi = np.repeat(col_values, scale)
    return np.broadcast_to(hi[None, :], (size, size)).copy()


def column_groups(col_mean, margin_frac):
    """Wrap-aware furrow/ridge column ids from the art's own column means,
    default_tree.py's read generalised to any margin as a share of the
    column mean's own spread."""
    n = col_mean.shape[0]
    spread = float(col_mean.max() - col_mean.min())
    margin = margin_frac * max(spread, 1e-6)
    is_furrow = col_mean < (col_mean.min() + margin)
    furrow_cols = np.where(is_furrow)[0]
    col_id = np.zeros(n, dtype=int)
    next_id = 0
    cur_id = None
    for x in range(n):
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
    return col_id, furrow_cols


def stepped_layout(col_id, col_mean, furrow_target, ridge_range, edge_dist, size):
    """default_tree.py's stepped plateau plus matched-slope groove, built
    with repeat_columns instead of kron. Returns the layout and t, the ridge
    closeness (1 on the ridge crown, 0 in the furrow floor)."""
    ids = sorted(set(col_id.tolist()))
    furrow_ids = [c for c in ids if c < 0]
    ridge_ids = [c for c in ids if c >= 0]
    ridge_lum = {c: float(col_mean[np.where(col_id == c)[0]].mean()) for c in ids}
    ridge_vals = np.array([ridge_lum[c] for c in ridge_ids]) if ridge_ids else np.array([0.0])
    lo, hi = float(ridge_vals.min()), float(ridge_vals.max())
    target = {}
    for c in furrow_ids:
        target[c] = furrow_target
    for c in ridge_ids:
        m = ridge_lum[c]
        target[c] = ridge_range[0] + (ridge_range[1] - ridge_range[0]) * (m - lo) / max(hi - lo, 1e-6)
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


def flap_patches(lum, base_blur_radius, bright_thresh_pct, warp_amp, edge_dist, tilt_amp, seed):
    """Small proud, slightly lifted patches for peeling bark: texels
    distinctly brighter than their own local neighbourhood (a raised or
    curled flake catching more light than the bark around it), warped into
    organic blobs the way mcl_core_log_birch.py's lenticels are, then each
    blob biased so one edge sits higher than the other, like a flake still
    attached on one side and lifted on the other, rather than a symmetric
    dome. Returns the biased dish (roughly -0.3 to 1.3) and the mask share
    found, for the diagnostic print."""
    local_base = lib.blur(lum, base_blur_radius)
    anomaly = lum - local_base
    thresh = np.percentile(anomaly, bright_thresh_pct)
    mask16 = (anomaly > thresh).astype(int)
    share = float(mask16.mean())

    labels_hi = lib.warp_labels(mask16, size=SIZE, amp=warp_amp, seed=seed, cells=8)
    edges = lib.region_edges(labels_hi)
    dist = lib.distance_to_edge(edges, max_dist=edge_dist)
    t = np.clip(dist / edge_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)
    dish = (1 - t) * labels_hi

    # One edge higher than the other: dy is positive on the upper edge of
    # each blob (the dish is rising there as y grows downward into the
    # patch) and negative on the lower edge (the dish is falling away), so
    # adding a multiple of it lifts the top of the flake proud and lets the
    # bottom recede into shadow, rather than a symmetric bump.
    dy = np.roll(dish, -1, axis=0) - np.roll(dish, 1, axis=0)
    flap = dish + tilt_amp * dy
    return flap, share


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

    margin_frac = 0.18
    col_id, furrow_cols = column_groups(col_mean, margin_frac)
    print(f"margin_frac {margin_frac} -> furrow columns {furrow_cols.tolist()} of {n} "
            "(one real furrow, the rest one wide ridge)")

    flattest_row = int(np.argmin(row_std))
    print("flattest row %d (std %.3f, mean %.3f); busiest row %d (std %.3f)" %
            (flattest_row, row_std[flattest_row], row_mean[flattest_row],
             int(np.argmax(row_std)), row_std.max()))

    # The one real furrow: a small luminance gap, this is a groove, not a
    # split trunk.
    furrow_layout, t = stepped_layout(col_id, col_mean, furrow_target=0.08,
            ridge_range=(0.45, 0.70), edge_dist=6, size=SIZE)

    # The ridge is not flat either: a gentle secondary ripple from the
    # column mean profile carries the rest of the busy column variation
    # the single furrow does not, without inventing more furrow steps.
    col_hi_mean = repeat_columns(col_mean.astype(np.float32), SIZE)
    ripple = lib.blur(col_hi_mean, 8)
    layout = furrow_layout + 0.10 * zscore(ripple) * t

    # Grain: bark fibre along the log (y), stronger than fig bark's tight
    # grain to match this art's real streakiness (row std up to 0.06).
    grain_src = lib.fbm(SIZE, base_cells=18, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=11, axis=0) * 0.20

    # Peeling flap patches, found from the art's own brightness anomalies,
    # not assumed: top 12 percent of texels brighter than a broad local
    # blur of their own neighbourhood.
    flap, flap_share = flap_patches(lum, base_blur_radius=5, bright_thresh_pct=88,
            warp_amp=3.0, edge_dist=4, tilt_amp=0.6, seed=SEED + 7)
    print("flap anomaly texels: %.1f%% of the tile" % (100.0 * flap_share))
    layout = layout + 0.22 * flap

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1)
    pores = blur_axis(pores_src, radius=2, axis=0) * 0.05

    # A scatter of small pits, on top of the one real furrow: this art is
    # busy everywhere (row std 0.037 to 0.060, no row anywhere near flat),
    # so unlike fig bark's occasional lenticel this is not a sparse
    # accent, it is a genuine texture the whole tile carries, and gives
    # ao_from_height real local features beyond the single furrow to find.
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

    pit_count, pit_radius, pit_amp = 140, (2, 4), (-0.55, -0.20)
    pits = scatter_pits(SIZE, pit_count, seed=SEED + 11, radius_range=pit_radius, amp_range=pit_amp)
    print(f"scattered pits: {pit_count}, radius {pit_radius}, amp {pit_amp}")

    height = lib.normalise01(layout + grain + pores + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the furrow/ridge closeness and the flap patches
    # (a lifted flake catches light more evenly, a touch smoother) plus its
    # own directional variation.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 5, gain=0.55), radius=9, axis=0)
    smooth = 0.45 * t + 0.15 * np.clip(flap, 0.0, 1.0) + 0.35 * directional_rough
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 20.0
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
