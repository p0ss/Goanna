"""Hand authored height and smoothness for kythen_firecountry_scarp_moss.

The art is a sparse cut-out, 93 percent opaque, a scatter of single texel
holes spread almost evenly across the whole tile rather than one drawn
silhouette: this is a soft cushion of moss with tiny gaps down to the rock
it grows on, not a blade or a leaf shape. lib.class_of reads "wood" from
the old bake, which is the underlying scarp rock's own footstep sound
carrying over, not what the moss itself is; a cushion of moss is a soft
organic growth, matched far better by the leaves class (its own
smoothness level and subsurface scattering byte suit a damp organic mat,
where wood's near zero smoothness would read as a dry, hard growth). The
relief is a dense scatter of small rounded tufts, shorter and rounder than
a grass blade, standing proud of a shallow base that carries the alpha
holes down to nothing at each gap.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_scarp_moss"
CLS = "leaves"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def tuft_stamp(radius, amp):
    """A small rounded cushion: a raised cosine dome, isotropic, no
    preferred direction, since a moss tuft has none."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    r = np.sqrt(dx ** 2 + dy ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, radius) / radius)), 0.0)
    return (amp * dome).astype(np.float32)


def scatter_tufts(size, guide, inside, n, seed, radius_range):
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
        radius = int(rng.integers(radius_range[0], radius_range[1] + 1))
        jitter = rng.uniform(0.85, 1.15)
        amp = jitter * (0.4 + 0.9 * guide[cy, cx])
        stamp = tuft_stamp(radius, amp)
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
    print("lib.class_of reads:", lib.class_of(STEM, GAME), "- overridden to leaves, see module docstring")
    alpha32 = src[..., 3]
    opaque = int((alpha32 > 0.5).sum())
    print(f"alpha: {opaque} of {alpha32.size} texels opaque ({100.0 * opaque / alpha32.size:.0f}%)")

    art_rgba = lib.upscale(src)
    art_rgb = art_rgba[..., :3]
    alpha256 = art_rgba[..., 3]
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))
    inside = (alpha256 > 0.5).astype(np.float32)

    tufts_fine = scatter_tufts(SIZE, guide, inside, 1400, seed=261, radius_range=(4, 8))
    tufts_coarse = scatter_tufts(SIZE, guide, inside, 420, seed=262, radius_range=(9, 15))
    tufts = np.maximum(tufts_fine, 0.8 * tufts_coarse)
    tufts = lib.normalise01(tufts)

    grain = lib.fbm(SIZE, base_cells=48, octaves=2, seed=263, gain=0.5)
    cushion = lib.normalise01(0.78 * tufts + 0.14 * guide + 0.08 * (grain * 0.5 + 0.5))

    alpha_soft = lib.blur(alpha256, 1)
    hole_floor = 0.03
    height = cushion * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=264, gain=0.55)
    smooth = 0.5 + 0.14 * zscore(height) + 0.10 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    normal_strength = 8.5
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
