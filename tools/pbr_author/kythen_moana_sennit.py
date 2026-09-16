"""Hand authored height and smoothness for kythen_moana_sennit.

Row means and column means carry the identical signature as
kythen_firecountry_woven_fibre.py itself, period four, both directions
matching exactly (0.323, 0.464, 0.511, 0.551 repeated eight times): the
same strand cell weave, a dark crease where one strand ducks under its
neighbour and a rounded, brightening top where it rises back over. Sennit
is coconut fibre cord, traditionally spun and then plaited flat into
sheets for lashing canoe hulls and thatch to a roof frame; the art draws
exactly that flat plait, not a single round cord, so it is built the same
way as the woven fibre panel: straight from the art's own row and column
brightness, replicated at the weave's own period, never warped.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_sennit"
CLS = "leaves"
SIZE = lib.SIZE
ART = 32
PERIOD = 4


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
    print("source", STEM, src.shape)
    print("lib.class_of reads:", lib.class_of(STEM, GAME))
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    row_means = lum.mean(axis=1)
    col_means = lum.mean(axis=0)
    print("row means:", np.round(row_means, 3).tolist())
    print("col means:", np.round(col_means, 3).tolist())

    phase_vals = np.concatenate([row_means.reshape(-1, PERIOD), col_means.reshape(-1, PERIOD)])
    profile = phase_vals.mean(axis=0)
    lo, hi = profile.min(), profile.max()
    profile = (profile - lo) / max(hi - lo, 1e-6)
    print("one strand-cell profile (crease to crest):", np.round(profile, 3).tolist())

    row_profile = np.tile(profile, ART // PERIOD)
    col_profile = np.tile(profile, ART // PERIOD)
    row_hi = np.repeat(row_profile, SIZE // ART)
    col_hi = np.repeat(col_profile, SIZE // ART)

    weave = 0.5 * row_hi[:, None] + 0.5 * col_hi[None, :]
    weave = lib.blur(weave, 2)

    weft_grain = blur_axis(lib.fbm(SIZE, base_cells=48, octaves=2, seed=2501, gain=0.5), radius=6, axis=1)
    warp_grain = blur_axis(lib.fbm(SIZE, base_cells=48, octaves=2, seed=2502, gain=0.5), radius=6, axis=0)
    grain = 0.5 * weft_grain + 0.5 * warp_grain

    fuzz = lib.blur(lib.white_noise(SIZE, seed=2503), 1) * 0.03

    height = lib.normalise01(0.78 * weave + 0.16 * (grain * 0.5 + 0.5) + fuzz, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=2504, gain=0.55)
    smooth = 0.35 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

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
