"""Norse birch bark: papery, with lenticels.

32 px art, mostly one bright shade (0.764 to 0.774 over most of the tile)
with darker, noisier columns: 0 and 1 (std 0.092, 0.076 against a typical
column std of 0.02 to 0.03) and a dark streak that wanders across columns
9 to 25 row by row rather than sitting in one fixed column (row 5's
darkest texel is column 22, row 16's is column 0, row 20's is column 1).
That reads the same way mcl_core_log_birch.py reads Mineclonia's own
birch: scattered darker patches on an otherwise even papery field, not a
cut furrow the way default_tree.py's oak groove is.

Tried first as kythen_bark_family's lenticel mode, the same recipe
mcl_core_log_birch.py uses: threshold the dark texels, warp the mask into
organic marks, dish them with lib.distance_to_edge. That mode's threshold
had to sit at 0.73 to catch this tile's real dark band, and at that
threshold the marks cover 25.5 percent of the tile, far more than
mcl_core_log_birch's own 10.5 percent; the wrapped dish still tiles, by
construction, but with this much of the tile inside a mark the seam
measure came out 1.83 to 1.97 (checked at warp_amp 0, 1.5 and 3.0) against
the 1.6 ceiling, and staying flat at that threshold either way meant the
technique itself, not a tuning knob, was the problem: too much of the map
is one mark's dish for the wrap join to still look like an ordinary
interior join.

So this splits the reading in two, the way kythen_habesha_fig_bark.py
handles a calmer bark and mcl_core_log_birch.py handles a marked one,
rather than forcing one technique to carry both signals. The broad column
banding (the real, if soft, brightness undulation the col std numbers
show) becomes kythen_habesha_fig_bark.py's own heavily blurred ripple,
continuous with no hard region edges anywhere, so it tiles by construction.
Only the genuinely darkest texels, luminance under 0.60 (55 of 1024, 5.4
percent, close to mcl_core_log_birch's own share), become lenticels, and
they are built the way kythen_habesha_fig_bark.py builds its own
lenticels: a sparse scatter of small round pits placed and wrapped by
modulo indexing rather than a thresholded, warped region mask, which tiles
cleanly by construction the same way kythen_habesha_cast_bronze.py's
casting pits and this game's various hard_cracks scatters do, with no
region boundary anywhere near the seam to go wrong.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_birch_bark"
SIZE = lib.SIZE
SEED = 8101


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, the same helper default_tree.py
    uses to stretch bark grain along the length of the log."""
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
    """A per-column profile stretched to size x size with straight column
    edges and no row variation, the same helper kythen_habesha_fig_bark.py
    uses for its own ripple."""
    n = col_values.shape[0]
    scale = size // n
    hi = np.repeat(col_values, scale)
    return np.broadcast_to(hi[None, :], (size, size)).copy()


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


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    n = src.shape[0]
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("lum min %.3f max %.3f mean %.3f sd %.3f" % (lum.min(), lum.max(), lum.mean(), lum.std()))
    col_mean = lum.mean(axis=0)
    col_std = lum.std(axis=0)
    print("column mean:", np.round(col_mean, 3).tolist())
    print("column std :", np.round(col_std, 3).tolist())
    dark_thresh = 0.60
    mask16 = lum < dark_thresh
    print(f"lenticel texels below {dark_thresh}: {int(mask16.sum())} / {mask16.size} "
          f"({100.0 * mask16.mean():.1f}%)")

    # Broad column banding: a heavily blurred, continuous ripple straight
    # from the column mean profile, kythen_habesha_fig_bark.py's own
    # technique, which tiles by construction (no hard region edge anywhere
    # for the wrap to cross badly).
    col_hi = repeat_columns(col_mean, SIZE)
    ripple = lib.blur(col_hi, 10)
    layout = 0.5 + 0.45 * zscore(ripple)

    # Grain: bark fibre along the log (y), tight and faint, a papery
    # bark's finish rather than a furrowed one.
    grain_src = lib.fbm(SIZE, base_cells=22, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=7, axis=0) * 0.12

    # Lenticels: a sparse scatter of small round pits at the tile's own
    # genuinely darkest texels' density, placed by modulo indexing so they
    # tile cleanly whatever their count, unlike a thresholded region mask
    # that covers a quarter of the tile (see module docstring for why that
    # approach was dropped here).
    lenticel_count, lenticel_radius, lenticel_amp = 150, (2, 5), (-1.0, -0.40)
    lenticels = scatter_pits(SIZE, lenticel_count, seed=SEED + 9,
            radius_range=lenticel_radius, amp_range=lenticel_amp)
    print(f"lenticel pits: {lenticel_count}, radius {lenticel_radius}, amp {lenticel_amp}")

    height = lib.normalise01(layout + grain + lenticels, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the same ripple (the paler bands read a touch
    # smoother) plus its own directional variation.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 5, gain=0.55), radius=8, axis=0)
    smooth = 0.5 + 0.16 * zscore(ripple) + 0.30 * zscore(directional_rough)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 20.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=n)
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
