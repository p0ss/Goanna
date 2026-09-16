"""Hand authored height and smoothness for kythen_shared_stick_wood.

The 32 px art is two flat values only, a light background (0.526, 79
percent of the tile) and a darker fleck (0.424) scattered through it, no
drawn stick silhouette to segment. class_of reads this stem back as
"leaves": the bake's own scattering byte matches CLASS_SSS's leaves entry
exactly (not a guessed level), which fits a bundle of thin, dry sticks
mixed with foliage bedding, the same material family as
kythen_shared_bedding_grass. The dark flecks read as the shadowed gaps
between individual sticks lying across each other, so the light background
is the raised stick surface and the dark flecks are shallow, narrow
recesses; a handful of longer raised ridges are added on top so the tile
also reads as sticks lying at angles, not only a stippled surface.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_shared_stick_wood"
SIZE = lib.SIZE


def stick_stamp(radius, angle, length, width, amp):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_sticks(size, n, seed, length_range, width_range, amp_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    amp = rng.uniform(*amp_range, n)
    for i in range(n):
        radius = int(np.ceil(length[i] / 2.0 + width[i]))
        stamp = stick_stamp(radius, angle[i], length[i], width[i], amp[i])
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
    vals = sorted(set(np.round(lum.ravel(), 3).tolist()))
    print(f"lum levels: {vals} (two values only, a flat scatter, not a drawn shape)")
    gap_frac = (lum < 0.5).mean()
    print(f"gap fraction {gap_frac:.3f}")

    is_gap = (lum < 0.5).astype(int)
    labels_hi = lib.warp_labels(is_gap, size=SIZE, amp=2.0, seed=101, cells=14)
    gap_mask = labels_hi == 1
    edges = lib.region_edges(labels_hi)
    max_dist = 3
    dist = lib.distance_to_edge(edges, max_dist=max_dist)
    t = np.clip(dist / max_dist, 0.0, 1.0)
    t = t * t * (3 - 2 * t)

    target = np.where(gap_mask, 0.34, 0.56)
    step = target.astype(np.float32)
    narrow = lib.blur(step, 1)
    wide = lib.blur(step, 2)
    layout = narrow + 0.8 * (narrow - wide)

    # A handful of longer, raised sticks lying across the tile, so it reads
    # as a bundle and not only a stippled surface.
    sticks = scatter_sticks(SIZE, n=26, seed=102, length_range=(30, 70),
            width_range=(4, 7), amp_range=(0.10, 0.20))

    grain = lib.fbm(SIZE, base_cells=40, octaves=3, seed=103, gain=0.55) * 0.05
    height = lib.normalise01(layout + sticks + grain, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=104, gain=0.55)
    smooth = 0.45 * t + 0.5 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 14.0
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
