"""Hand authored height and smoothness for kythen_shared_bedding_grass.

The 32 px art is a dense per texel dither, luminance 0.330 to 0.628, no
regions for lib.segments to find at any tolerance tried (591 fragments,
average under two texels each): a photograph of loose material, not a
drawing, the same reading kythen_turf.py and mcl_core_grass_block_top.py
give their own art. Dry bedding stalks lie criss-crossed at every angle
rather than standing up the way live turf does, so the relief is built
from short stalk stamps scattered at random angles and lengths, taller
where the art itself sits lighter.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_shared_bedding_grass"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def stalk_stamp(radius, angle, length, width, amp):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_stalks(size, guide, n, seed, length_range, width_range):
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
        amp = jitter[i] * (0.35 + 0.9 * local_guide)
        radius = int(np.ceil(length[i] / 2.0 + width[i]))
        stamp = stalk_stamp(radius, angle[i], length[i], width[i], amp)
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
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    labels, n = lib.segments(rgb, tolerance=0.03)
    print(f"segments at tolerance 0.03: n={n} (a dithered mat, no distinct regions)")

    art_rgb = lib.upscale(rgb)
    art_lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(art_lum, 3))

    stalks_fine = scatter_stalks(SIZE, guide, 1800, seed=111, length_range=(14, 26), width_range=(2, 3))
    stalks_coarse = scatter_stalks(SIZE, guide, 600, seed=112, length_range=(26, 44), width_range=(3, 5))
    stalks = lib.normalise01(np.maximum(stalks_fine, 0.7 * stalks_coarse))

    grain = lib.fbm(SIZE, base_cells=44, octaves=2, seed=113, gain=0.5)
    height = lib.normalise01(0.7 * stalks + 0.2 * guide + 0.10 * (grain * 0.5 + 0.5))
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=114, gain=0.55)
    smooth = 0.5 + 0.14 * zscore(height) + 0.09 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 6.5
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
