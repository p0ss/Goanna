"""Hand authored height and smoothness for kythen_firecountry_saltbush_leaf.

The art is a cut-out, 90 percent opaque, small single texel holes spread
almost evenly across the tile rather than one drawn blade silhouette: a
dense cluster of small saltbush leaves seen face on, not a sparse sprig of
blades the way mcl_flowers_tallgrass draws its grass. That is the same
shape default_leaves.py's own canopy is built from, many small overlapping
domes with the alpha holes carved all the way down as real gaps through
the leaf mat, so the same lobe scatter construction applies here rather
than tallgrass's elongated blade stamps: saltbush leaves are small, round
and fleshy, not long and narrow.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_saltbush_leaf"
CLS = "leaves"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def lobe_stamp(radius, angle, amp, rim_frac=0.78, rim_depth=0.10,
        midrib_amp=0.14, midrib_sigma_frac=0.30):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    r = np.sqrt(dx ** 2 + dy ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, radius) / radius)), 0.0)
    rim_r0 = rim_frac * radius
    in_rim = (r > rim_r0) & (r <= radius)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (r[in_rim] - rim_r0) / (radius - rim_r0))
    ca, sa = np.cos(angle), np.sin(angle)
    v = -dx * sa + dy * ca
    sigma = midrib_sigma_frac * radius
    midrib = midrib_amp * np.exp(-(v ** 2) / (2.0 * sigma ** 2)) * dome
    return (amp * (dome + rim + midrib)).astype(np.float32)


def scatter_lobes(size, guide, inside, n, seed, radius_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    placed = 0
    attempts = 0
    max_attempts = n * 8
    while placed < n and attempts < max_attempts:
        attempts += 1
        cx = int(rng.integers(0, size))
        cy = int(rng.integers(0, size))
        if inside[cy, cx] < 0.5:
            continue
        angle = rng.uniform(0.0, np.pi)
        radius = int(rng.integers(radius_range[0], radius_range[1] + 1))
        jitter = rng.uniform(0.85, 1.15)
        amp = jitter * (0.4 + 0.9 * guide[cy, cx])
        stamp = lobe_stamp(radius, angle, amp)
        ys = (np.arange(-radius, radius + 1) + cy) % size
        xs = (np.arange(-radius, radius + 1) + cx) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
        placed += 1
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    alpha32 = src[..., 3]
    opaque = int((alpha32 > 0.5).sum())
    print(f"alpha: {opaque} of {alpha32.size} texels opaque ({100.0 * opaque / alpha32.size:.0f}%)")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    art_rgba = lib.upscale(src)
    art_rgb = art_rgba[..., :3]
    alpha256 = art_rgba[..., 3]
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))
    inside = (alpha256 > 0.5).astype(np.float32)

    lobes_fine = scatter_lobes(SIZE, guide, inside, 700, seed=341, radius_range=(6, 9))
    lobes_coarse = scatter_lobes(SIZE, guide, inside, 240, seed=342, radius_range=(10, 14))
    lobes = np.maximum(lobes_fine, 0.8 * lobes_coarse)
    lobes = lib.normalise01(lobes)

    grain = lib.fbm(SIZE, base_cells=44, octaves=2, seed=343, gain=0.5)
    canopy = lib.normalise01(0.80 * lobes + 0.18 * guide + 0.10 * (grain * 0.5 + 0.5))

    alpha_soft = lib.blur(alpha256, 1)
    hole_floor = 0.03
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=344, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    normal_strength = 9.5
    m = lib.pack(STEM, out_dir, art_rgba, height, smooth, CLS,
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
