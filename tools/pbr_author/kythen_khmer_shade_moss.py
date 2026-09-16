"""Hand authored height and smoothness for kythen_khmer_shade_moss.

The 32 px art is mostly opaque (94 percent) with small alpha holes
scattered singly across the tile, and a dark background with sparse
bright flecks, a soft cushion of tiny overlapping tufts with the odd gap
down to whatever is underneath, the same reading mcl_core_leaves_big_oak.py
gives an oak canopy but at a much smaller, denser scale (a moss tuft, not a
leaf lobe). lib.class_of reads this stem back as wood from the bake: there
is no "moss" or "leaves" entry in the name hints it checks first, so it
fell through to the nearest smoothness level by chance. A soft, damp
cushion of tiny plants is plainly not bark, so this script uses the leaves
class instead, matching the physical material and giving it leaves' tilt
target and unjointed ambient occlusion rule rather than wood's.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_shade_moss"
CLS_READ = lib.class_of(STEM, GAME)
CLS = "leaves"
SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out at."""
    return (field - field.mean()) / (field.std() + 1e-6)


def lobe_stamp(radius, angle, amp, rim_frac=0.80, rim_depth=0.10,
        midrib_amp=0.20, midrib_sigma_frac=0.24):
    """A small dome for one moss tuft, the same shape
    mcl_core_leaves_big_oak.py builds a leaf lobe from."""
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


def scatter_tufts(size, guide, n, seed, radius_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    radius = rng.integers(radius_range[0], radius_range[1] + 1, n)
    jitter = rng.uniform(0.85, 1.15, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.4 + 0.9 * local_guide)
        stamp = lobe_stamp(int(radius[i]), angle[i], amp)
        r = int(radius[i])
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    lum16 = lib.luminance(src[..., :3])
    alpha16 = src[..., 3]
    print(f"source luminance min {lum16.min():.3f} mean {lum16.mean():.3f} max {lum16.max():.3f}")
    print(f"alpha: {(alpha16 < 0.5).sum()} of {alpha16.size} texels transparent "
          f"({100.0 * (alpha16 < 0.5).mean():.0f}%)")
    print(f"class read back from the bake: {CLS_READ}; used here: {CLS} "
          "(a moss cushion, not bark)")

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))
    alpha256 = lib.upscale(src[..., 3])
    alpha_soft = lib.blur(alpha256, 1)

    # Small, dense tufts: a moss cushion is many tiny overlapping plants,
    # finer than an oak leaf's lobes.
    tufts_fine = scatter_tufts(SIZE, guide, 500, seed=701, radius_range=(3, 5))
    tufts_coarse = scatter_tufts(SIZE, guide, 200, seed=702, radius_range=(6, 9))
    tufts = np.maximum(tufts_fine, 0.8 * tufts_coarse)
    tufts = lib.normalise01(tufts)

    grain = lib.fbm(SIZE, base_cells=50, octaves=2, seed=703, gain=0.5)
    canopy = lib.normalise01(0.85 * tufts + 0.15 * guide + 0.06 * (grain * 0.5 + 0.5))

    hole_floor = 0.05
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=704, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src)

    normal_strength = 8.0
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
