"""Hand authored height and smoothness for kythen_habesha_juniper_bark.

32 px art, luminance 0.311 to 0.444, mean 0.417, sd 0.035. Column mean
spread 0.060 against row mean spread 0.028, the family's column direction
signal (bark furrows run along the log), and busier than default_tree.py's
oak: the column mean climbs and falls almost every column rather than
sitting in a few long flat runs (0.412, 0.417, 0.436, 0.396, 0.405, 0.417,
0.420, 0.422, 0.392, ...), with no run longer than three columns before it
turns again.

Like the other two habesha barks, the darkest columns are not the flattest
ones: column 26 is the brightest and flattest in the tile (mean 0.442, std
0.008), and the columns that read darkest, 3, 8, 12, 16, 20, 23, 28 and 31
(mean 0.383 to 0.403), carry some of the highest column standard
deviations in the art (0.033 to 0.042). So the recesses here are not
smooth cut grooves either, they are shadowed, textured troughs between
smoother raised fibre strips, which is exactly what stringy, twisted bark
fibre looks like: rough in the gaps, glossy on the ridges the fibre
catches light on. A margin of 0.35 of the column spread (0.021) catches
nine of the thirty two columns as recessed, against default_tree.py's
three of sixteen (19 percent) or fig bark's seven of thirty two at a
looser margin: proportionally busier, matching the brief. The stepped
plateau and groove are default_tree.py's own construction (built with
repeat_columns instead of kron), but with many narrow ridges instead of a
few wide ones, and grain amplitude modulated by each source column's own
standard deviation, so the columns that measure streakier in the art carry
more streak in the height field too.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_juniper_bark"
SIZE = lib.SIZE
SEED = 401


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
    with repeat_columns instead of kron. Returns the layout and t, the
    ridge closeness (1 on a ridge crown, 0 in a furrow floor)."""
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
    print("column mean:", np.round(col_mean, 3).tolist())
    print("column std :", np.round(col_std, 3).tolist())
    print("column spread %.3f  row spread %.3f" %
            (col_mean.max() - col_mean.min(), row_mean.max() - row_mean.min()))

    margin_frac = 0.35
    col_id, furrow_cols = column_groups(col_mean, margin_frac)
    n_ridges = len(set(c for c in col_id.tolist() if c >= 0))
    print(f"margin_frac {margin_frac} -> furrow columns {furrow_cols.tolist()} of {n} "
            f"({len(furrow_cols)} furrows, {n_ridges} ridge runs): a busier alternation than "
            "default_tree.py's oak (3 of 16), reading as narrow, tightly packed fibre strips.")

    # A wide luminance gap between furrow and ridge, wider than fig bark's
    # calm banding: these troughs are real shadowed gaps between fibre
    # strips, not mild colour variation.
    layout, t = stepped_layout(col_id, col_mean, furrow_target=0.06,
            ridge_range=(0.55, 0.88), edge_dist=5, size=SIZE)

    # A slow crown on the ridge crowns only, faded to nothing at the
    # furrow edges so it never reopens the groove's matched slope.
    crown = lib.fbm(SIZE, base_cells=6, octaves=2, seed=SEED + 1) * 0.10
    layout = layout + crown * t

    # Grain: fibre running the length of the log (y), amplitude modulated
    # by each source column's own standard deviation, so the columns that
    # measure streakier in the art (the shadowed troughs) carry visibly
    # more streak than the calmer ridge columns, tying the height's
    # texture back to what was actually measured rather than a flat
    # amplitude everywhere.
    col_std_hi = repeat_columns(col_std.astype(np.float32), SIZE)
    std_lo, std_hi = float(col_std.min()), float(col_std.max())
    std_gain = 0.6 + 0.8 * (col_std_hi - std_lo) / max(std_hi - std_lo, 1e-6)
    grain_src = lib.fbm(SIZE, base_cells=24, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=12, axis=0) * 0.30 * std_gain

    # A second, finer twist: short cross streaks on the ridge tops only,
    # the way a fibre strip catches a twist along its own length, scaled
    # by t so the furrow floors (already the lowest point) stay clean.
    twist_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1)
    twist = blur_axis(twist_src, radius=3, axis=1) * 0.06 * t

    pores_src = lib.blur(lib.white_noise(SIZE, seed=SEED + 4), 1)
    pores = blur_axis(pores_src, radius=6, axis=0) * 0.03

    # Widening and deepening the groove alone left ao_min stuck around
    # 0.50 (measured directly at edge_dist 2, 3 and 5, furrow_target 0.06
    # to 0.12): with nine furrows the whole tile is already close to a
    # groove edge, so normalise01's percentile clip is set by the crown
    # and grain terms, not the furrow floor. A scatter of small twist pits
    # (the same fix fig bark and incense bark needed) gives
    # ao_from_height genuine sharp local drops to find instead.
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

    pit_count, pit_radius, pit_amp = 150, (2, 4), (-0.6, -0.25)
    pits = scatter_pits(SIZE, pit_count, seed=SEED + 9, radius_range=pit_radius, amp_range=pit_amp)
    print(f"scattered pits: {pit_count}, radius {pit_radius}, amp {pit_amp}")

    height = lib.normalise01(layout + grain + twist + pores + pits, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows distance from the nearest furrow (rough in the
    # shadowed troughs, worn smoother on the fibre ridges) plus its own
    # directional streakiness, also scaled by the measured column std.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=18, octaves=3, seed=SEED + 5, gain=0.55), radius=10, axis=0)
    smooth = 0.50 * t + 0.40 * directional_rough * std_gain
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 17.0
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
