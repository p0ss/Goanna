"""Hand authored height and smoothness for kythen_khmer_kapok.

The 32 px art is a cut-out, 10 percent alpha punched out in 34 separate
patches of one to fourteen texels, none of them a large clean shape: sky
gaps scattered through a canopy, the same statistical pattern
mcl_core_leaves_big_oak.py's art has (holes everywhere, no single big cut),
not the long slit a fibre strand or a whole tree face would leave. The
brief allows either reading for this stem; the alpha evidence points at a
leaf canopy, so it is built the oak leaves way: overlapping lobed domes
scattered two scales deep, amplitude taken from the art's own brightness,
with the alpha holes carved to a shared dark floor regardless of what lobe
would otherwise sit there.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_kapok"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def lobe_stamp(radius, angle, amp, rim_frac=0.80, rim_depth=0.10,
        midrib_amp=0.20, midrib_sigma_frac=0.24):
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


def scatter_lobes(size, guide, n, seed, radius_range):
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
          f"({100.0 * (alpha16 < 0.5).mean():.0f}%), scattered in small patches: a canopy, not a fibre strand")
    print("class:", CLS)

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))
    alpha256 = lib.upscale(src[..., 3])
    alpha_soft = lib.blur(alpha256, 1)

    lobes_fine = scatter_lobes(SIZE, guide, 550, seed=1101, radius_range=(3, 5))
    lobes_coarse = scatter_lobes(SIZE, guide, 220, seed=1102, radius_range=(6, 9))
    lobes = np.maximum(lobes_fine, 0.8 * lobes_coarse)
    lobes = lib.normalise01(lobes)

    grain = lib.fbm(SIZE, base_cells=42, octaves=2, seed=1103, gain=0.5)
    canopy = lib.normalise01(0.82 * lobes + 0.18 * guide + 0.08 * (grain * 0.5 + 0.5))

    hole_floor = 0.04
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=18, octaves=3, seed=1104, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src)

    normal_strength = 10.0
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
