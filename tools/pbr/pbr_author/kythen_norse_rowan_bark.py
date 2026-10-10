"""Norse rowan bark: smooth grey.

32 px art, the calmest of the three Norse barks by a wide margin: only two
shades, 0.453 and 0.478, arranged as a per-texel dither with no macro
pattern at all (column mean spread 0.010, row mean spread 0.008, both far
below birch's 0.152/0.032 and pine's 0.141/0.043). There is nothing here
to read as a furrow, a column band or even kythen_habesha_fig_bark.py's
own gentle ripple: the dither has no larger scale signal for a ripple to
follow. Real rowan bark is famously smooth and pale grey, close to
featureless except for the odd shallow lenticel scar, so this is built the
same way kythen_habesha_fig_bark.py's own lenticel pits are, a flat
baseline plus a sparse scatter of small round pits placed by modulo
indexing (tiles cleanly by construction) and a faint grain, with no ripple
term at all since the art gives none to follow.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_rowan_bark"
SIZE = lib.SIZE
SEED = 8301


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


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
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    print("column spread %.4f  row spread %.4f (no macro signal, dither only)" %
            (col_mean.max() - col_mean.min(), row_mean.max() - row_mean.min()))

    # Faint grain along the log (y), tighter than either of the other two
    # Norse barks: a smooth trunk's finish, not a furrowed one.
    grain_src = lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED + 2, gain=0.55)
    grain = blur_axis(grain_src, radius=8, axis=0) * 0.10

    # A sparse scatter of shallow lenticel pits carries the only real
    # occlusion this calm a bark gets, the same reasoning
    # kythen_habesha_fig_bark.py gives for its own trunk: a diffuse
    # everywhere noise field never leaves enough of normalise01's own
    # stretched range for ao to fall, but a sparse scatter of real pits
    # does.
    lenticel_count, lenticel_radius, lenticel_amp = 90, (2, 4), (-0.9, -0.35)
    lenticels = scatter_pits(SIZE, lenticel_count, seed=SEED + 9,
            radius_range=lenticel_radius, amp_range=lenticel_amp)
    print(f"lenticel pits: {lenticel_count}, radius {lenticel_radius}, amp {lenticel_amp}")

    height = lib.normalise01(0.6 + grain + lenticels, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: matte, mostly its own faint variation, with a whisper
    # following height so a pit's own rim reads a touch rougher than the
    # smooth trunk around it.
    directional_rough = blur_axis(
            lib.fbm(SIZE, base_cells=18, octaves=3, seed=SEED + 5, gain=0.55), radius=8, axis=0)
    smooth = 0.5 + 0.10 * zscore(height) + 0.35 * zscore(directional_rough)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 34.0
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
