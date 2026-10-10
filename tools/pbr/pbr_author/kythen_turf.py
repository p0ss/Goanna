"""Hand authored height and smoothness for kythen_turf.

The 16 px art is a dithered mat, luminance 0.399 to 0.509, no regions for
lib.segments to find (a photograph of grass from above, not a drawing of
individual blades), the same reading mcl_core_grass_block_top.py gives its
own art. Unlike that Mineclonia texture, this one is not tinted grey for
the engine to colour: the raw RGB carries its own green, mean (0.333,
0.506, 0.239), saturation up to 0.267, so the albedo keeps the art's full
colour rather than going to greyscale. The relief is a felt of short blade
tip stamps at random angles, taller where the art sits lighter.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_turf"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def blade_stamp(radius, angle, length, width, amp):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_blades(size, guide, n, seed, length_range, width_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    jitter = rng.uniform(0.8, 1.2, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.35 + 0.95 * local_guide)
        radius = int(np.ceil(length[i] / 2.0 + width[i]))
        stamp = blade_stamp(radius, angle[i], length[i], width[i], amp)
        ys = (np.arange(-radius, radius + 1) + cy[i]) % size
        xs = (np.arange(-radius, radius + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    sat = rgb.max(-1) - rgb.min(-1)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print(f"mean rgb {rgb.reshape(-1, 3).mean(0).round(3)}, max sat {sat.max():.3f}: "
          "coloured art, not tinted grey, so the albedo keeps its colour")

    for tolerance in (0.02, 0.05):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        print(f"segments at tolerance {tolerance}: n={n} (a dithered mat, no distinct regions)")

    art_rgb = lib.upscale(rgb)
    art_lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(art_lum, 2))

    blades_fine = scatter_blades(SIZE, guide, 2600, seed=411, length_range=(6, 12), width_range=(2, 3))
    blades_coarse = scatter_blades(SIZE, guide, 900, seed=412, length_range=(12, 22), width_range=(3, 5))
    blades = lib.normalise01(np.maximum(blades_fine, 0.75 * blades_coarse))

    grain = lib.fbm(SIZE, base_cells=48, octaves=2, seed=413, gain=0.5)

    height = lib.normalise01(0.72 * blades + 0.18 * guide + 0.10 * (grain * 0.5 + 0.5))
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=414, gain=0.55)
    smooth = 0.5 + 0.13 * zscore(height) + 0.09 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 5.5
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
