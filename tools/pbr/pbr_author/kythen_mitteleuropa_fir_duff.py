"""Hand authored height and smoothness for kythen_mitteleuropa_fir_duff.

The 32 px art is a dense fine mottle, four shades with no drawn regions
lib.segments can hold onto past a loose tolerance (0.05 already collapses
half the tile into two big matrices). That reading matches needle litter:
many short fallen needles crossing at every angle, not reed_peat's long
combed fibre lying mostly in one of two directions. The relief is built
from a scatter of short, narrow ridges (a needle stamp, much shorter than
mcl_core_grass_block_top's own blade) at a uniform random angle, two size
populations so it does not read as one repeated length, taller where the
art itself is lighter.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_fir_duff"
CLS = "soil"
SIZE = lib.SIZE


def needle_stamp(radius, angle, length, width, amp):
    """A single fallen needle: a short, narrow ridge, raised cosine along
    its length so it tapers to nothing at both tips, gaussian across its
    width."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_needles(size, guide, n, seed, length_range, width_range):
    """Places n needles at a uniform random angle (fir duff has no
    combed direction the way reed peat does), taller where guide (the
    art's own brightness) is higher."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    jitter = rng.uniform(0.7, 1.3, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.30 + 0.90 * local_guide)
        radius = int(np.ceil(length[i] / 2.0 + width[i]))
        stamp = needle_stamp(radius, angle[i], length[i], width[i], amp)
        ys = (np.arange(-radius, radius + 1) + cy[i]) % size
        xs = (np.arange(-radius, radius + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())} "
              f"(a fine mottle, not drawn needles)")

    art_rgb = lib.upscale(rgb)
    guide = lib.normalise01(lib.blur(lib.luminance(art_rgb), 2))

    needles_fine = scatter_needles(SIZE, guide, 3200, seed=871, length_range=(5, 10), width_range=(1, 2))
    needles_coarse = scatter_needles(SIZE, guide, 1400, seed=872, length_range=(9, 16), width_range=(1.5, 2.5))
    needles = np.maximum(needles_fine, 0.8 * needles_coarse)
    needles = lib.normalise01(needles)

    grain = lib.fbm(SIZE, base_cells=50, octaves=2, seed=873, gain=0.5)

    height = 0.65 * needles + 0.20 * guide + 0.15 * (grain * 0.5 + 0.5)
    height = lib.normalise01(height)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=874, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    # No lib.band: the needle scatter already gives a bounded relief close
    # to the soil target at a low strength, and banding it further left
    # the ambient occlusion above 0.6 (the low points too shallow).
    normal_strength = 6.0
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
