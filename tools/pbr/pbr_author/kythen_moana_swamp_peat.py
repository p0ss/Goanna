"""Hand authored height and smoothness for kythen_moana_swamp_peat.

The 32 px art is the flattest and most uniform of the moana organics:
luminance 0.138 to 0.255, sd only 0.032, and lib.segments collapses almost
entirely to a single background at tolerance 0.05 (811 of 1024 texels, 79
percent) with only a scatter of small patches, one blob outright at 0.08.
Greenness (G minus the average of R and B) is essentially flat, mean 0.001,
max 0.012, no visible moss the way kythen_moana_peat_moss carries: this is
waterlogged peat sitting under the water table, soft and settled, not the
mossy surface peat above it. Built the same way as kythen_firecountry_
reed_peat.py, tangled fibre streaks at random angles rather than clod
domes, but with a flatter guide and a tighter band, since this art carries
far less broad structure than reed_peat's own drawn mat.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_swamp_peat"
CLS = "soil"
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
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    greenness = rgb[..., 1] - (rgb[..., 0] + rgb[..., 2]) / 2.0
    print(f"greenness min {greenness.min():.3f} max {greenness.max():.3f} mean {greenness.mean():.3f} (no moss here)")
    print("class_of reads:", lib.class_of(STEM, GAME))

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())}")

    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    # Tangled fibre at two independent angles, the same construction as
    # reed_peat's own mat.
    fibre_a = blur_axis(lib.fbm(SIZE, base_cells=30, octaves=2, seed=971, gain=0.5), radius=10, axis=1)
    fibre_b = blur_axis(lib.fbm(SIZE, base_cells=30, octaves=2, seed=972, gain=0.5), radius=10, axis=0)
    fibre = 0.55 * fibre_a + 0.55 * fibre_b

    # Softer, coarser settling, weaker than reed_peat's own since this art
    # carries almost no broad signal of its own.
    lumps = lib.fbm(SIZE, base_cells=8, octaves=3, seed=973, gain=0.55) * 0.20

    layout = 0.22 * guide + 0.28 * lumps + 0.42 * fibre

    fuzz = lib.blur(lib.white_noise(SIZE, seed=974), 1) * 0.05
    hollow_field = lib.blur(lib.white_noise(SIZE, seed=975), 2)
    hollow_cut = float(np.percentile(hollow_field, 30))
    hollows = np.where(hollow_field < hollow_cut, hollow_field - hollow_cut, 0.0) * 2.2

    height = lib.normalise01(layout + fuzz + hollows, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: soft and matte, waterlogged peat holds no worn high face
    # the way a dry, trodden mat does.
    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=976, gain=0.55)
    smooth = 0.22 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 10.0
    height = lib.band(height, 0.50)
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
