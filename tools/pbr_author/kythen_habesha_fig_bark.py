"""Hand authored height and smoothness for kythen_habesha_fig_bark.

32 px art, and the calmest reading of the three habesha barks by a wide
margin: overall luminance sits in 0.519 to 0.593, a spread of only 0.074,
against incense bark's 0.181 and juniper's 0.133. Column mean spread is
0.031, row mean spread 0.013, so there is a column direction signal (the
family rule: bark furrows run along the log), but it is faint.

Crucially it is not default_tree.py's furrow signature. The oak has a
column that is both dark and flat (std near zero) cut straight down the
log. Here the flattest columns, std 0.006 to 0.008 at columns 4 to 7, 10 to
12 and 18 to 20, are the *brightest* columns in the tile (mean 0.582 to
0.589), and the darkest column, 9 at mean 0.558, has one of the highest
column standard deviations (0.028): it is not a smooth cut groove, it is a
patch of active colour variation that happens to sit a little darker. So
this art shows no true furrow: a handful of glassy, evenly lit bands
(worn smooth, catching light evenly) separated by slightly darker, mildly
streaky bands, reading as gentle colour banding on an otherwise even
surface, not sharp grooves. Building default_tree.py's stepped plateau and
matched-slope groove on this would invent a furrow the pixels do not
support, so this script skips that machinery entirely: the banding becomes
a smooth, continuous ripple (a heavily blurred copy of the column mean
profile, no hard region edges anywhere) and the grain on top is kept
tighter (shorter blur radius, lower amplitude) than default_tree.py's oak,
matching "tighter grain" and "overall smoother finish". The one thing a
pure ripple and grain cannot give is any self shadowing at all: with
nothing local for ao_from_height to catch, ao_min came out at 0.87, flatter
even than the plastic bake this project exists to fix. Real calm bark
still breathes through occasional lenticels, so a sparse scatter of small
round pits carries that floor instead of an invented furrow.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_fig_bark"
SIZE = lib.SIZE
SEED = 201


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
    """A per-column profile stretched to size x size with straight column
    edges and no row variation: np.repeat along x then broadcast down y.
    Gives the same straight-column result np.kron would, without kron."""
    n = col_values.shape[0]
    scale = size // n
    hi = np.repeat(col_values, scale)
    return np.broadcast_to(hi[None, :], (size, size)).copy()


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
    darkest = int(np.argmin(col_mean))
    flattest = int(np.argmin(col_std))
    print("darkest column %d (mean %.3f, std %.3f); flattest column %d (mean %.3f, std %.3f)" %
            (darkest, col_mean[darkest], col_std[darkest], flattest, col_mean[flattest], col_std[flattest]))
    print("no dark-and-flat furrow found: the flattest columns are the brightest ones. "
            "Reading this as smooth bark with mild colour banding, not a cut groove.")

    # A smooth, continuous ripple straight from the column mean profile:
    # heavy blur removes the per-source-column stair step, leaving a gentle
    # wave with no hard edges anywhere, unlike default_tree.py's stepped
    # plateau. That keeps the relief to the mild banding the pixels show.
    col_hi = repeat_columns(col_mean, SIZE)
    ripple = lib.blur(col_hi, 10)
    layout = 0.5 + 0.55 * zscore(ripple)

    # Grain: bark fibre along the log (y). Tighter than default_tree.py's
    # oak (radius 7 not 14, lower amplitude), for the calmer, less streaky
    # finish the brief asks for.
    grain_src = lib.fbm(SIZE, base_cells=22, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=7, axis=0) * 0.14

    # Lenticels, not broad pores: with no true furrow anywhere on this
    # tile, a diffuse fbm or white noise pore field was tried at several
    # amplitudes (0.05 to 0.22) and radii, and ao_min never moved off 0.85
    # to 0.88, because normalise01 rescales the WHOLE field by its own 0.5
    # to 99.5 percentile range, and a broad, everywhere noise field never
    # leaves enough of that range for its own small amplitude no matter how
    # it is tuned (measured directly, bypassing the shared file). What
    # actually carries a real, if shallow, floor is a sparse scatter of
    # small round pits, most of the tile untouched: a real trunk this calm
    # still breathes through occasional lenticels, which is exactly this
    # shape, not the pitting a rough bark would have everywhere.
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

    lenticel_count, lenticel_radius, lenticel_amp = 110, (2, 5), (-1.1, -0.45)
    lenticels = scatter_pits(SIZE, lenticel_count, seed=SEED + 9,
            radius_range=lenticel_radius, amp_range=lenticel_amp)
    print(f"lenticel pits: {lenticel_count}, radius {lenticel_radius}, amp {lenticel_amp}")

    height = lib.normalise01(layout + grain + lenticels, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows the same ripple (the bright glassy bands are the
    # worn-smooth ones) plus a modest directional variation of its own.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=16, octaves=3, seed=SEED + 5, gain=0.55), radius=8, axis=0)
    smooth = 0.5 + 0.18 * zscore(ripple) + 0.30 * zscore(directional_rough)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    # The first pass used 42, matching default_tree.py's oak-scale groove
    # depth, but this tile has no groove at all (see the diagnostic above):
    # normalise01 still stretches its mild ripple to the full 0 to 1 height
    # range, so a groove-scale normal_strength on top of that gave a tilt
    # of 39.5 degrees and an ao_min of 0.88, both badly out of band for a
    # calm, smooth bark. Dropped to a third of that, close to the oak's own
    # grain-only regions rather than its furrow.
    normal_strength = 18.0
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
