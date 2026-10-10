"""Hand authored height and smoothness for kythen_firecountry_clay_daub.

The 32 px art is a narrow buff band, luminance 0.451 to 0.643, mostly one
mid shade with occasional brighter streaks running across a few rows at a
time (rows 13 to 15 and 25 lift well above their neighbours, and within a
row the brightness itself wanders left to right rather than sitting flat).
That reads as the brief describes: a hand smoothed daub wall, the base
coat essentially flat, with faint horizontal sweeps left by a palm or a
float drawn as those brighter streaks. This is manufactured, not natural
stone, so it is held nearly flat with lib.band, the same treatment
hardened_clay_family.py gives a fired tile, and the warp is left at
amplitude 0 rather than bending the sweep into a scribble.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_clay_daub"
CLS = "soil"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a sweep mark along
    the direction a hand or a float actually moved."""
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
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)
    print(f"{STEM}: lum min {lo:.3f} max {hi:.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3).tolist())

    # The art's own brightness, smoothly upscaled: the base coat's own
    # gentle undulation, not a region search, since a smoothed wall has no
    # drawn lumps to segment.
    mottle = lib.upscale(norm_lum, smooth=True)
    mottle = lib.blur(mottle, 3)

    # Finger sweeps: broad, shallow, horizontal streaks, stretched far
    # along x (a whole wall's width) and narrow along y (the width of a
    # palm's pass), so they read as one long faint stroke rather than a
    # patch of noise.
    sweep_src = lib.fbm(SIZE, base_cells=6, octaves=2, seed=211, gain=0.5)
    sweep = blur_axis(sweep_src, radius=30, axis=1)

    # A finer ripple riding on the sweep, the daub's own texture where the
    # float did not fully smooth it.
    ripple = lib.fbm(SIZE, base_cells=40, octaves=2, seed=212, gain=0.5)

    # Sparse small pits, a stray pebble or straw fleck caught in the mix.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=213), 1)
    pit_cut = float(np.percentile(pit_field, 5))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0)

    field = 0.30 * mottle + 0.40 * sweep + 0.20 * ripple + 0.10 * pits
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    height = lib.band(field, 0.10)
    print(f"height sd {height.std():.3f}")

    # Smoothness: fairly even and a little glossy where the float passed
    # hardest, the daub's own light variation on top.
    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=214, gain=0.55)
    smooth = 0.20 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    # A hand smoothed wall face, not a jointed material: held nearly flat
    # on purpose, so the tilt is reported under the soil band rather than
    # forced into it.
    normal_strength = 11.0
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
