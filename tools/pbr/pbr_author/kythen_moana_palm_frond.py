"""Hand authored height and smoothness for kythen_moana_palm_frond.

The 32 px art is a cut-out, 85 percent opaque: a mottled dither against
transparency with no drawn vein, midrib or blade outline, the same device
mcl_flowers_tallgrass.py found in its own strokes. There is nothing for
lib.segments to find and no single wide clump either, so the relief is a
scatter of individual long blade ridges, mostly upright with a little
lean, each tapering only near its own tip and carrying a raised midrib
down its centre, the frond's fibrous rib. The scatter sits inside an
envelope taken from the alpha shape's own warped distance to edge, so
height still falls to nothing exactly at the cut boundary whatever the
scatter did there. Smoothness follows that envelope, waxy along the blade
and matte right at the cut edge.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_palm_frond"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE

SEED = 1701
GRAIN_SEED = 1711
VARIATION_SEED = 1721


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def edge_envelope(alpha_art, seed, warp_amp=2.5, cap=5.0):
    """0 at the art's own cut edge and at a drawn tip, 1 across the middle
    of a blade's width. Same construction as
    mcl_flowers_tallgrass.py's edge_envelope."""
    mask_art = (alpha_art > 0.5).astype(int)
    mask_hi = lib.warp_labels(mask_art, amp=warp_amp, seed=seed, cells=10)
    inside = mask_hi.astype(np.float32)
    edges = lib.region_edges(mask_hi)
    dist = lib.distance_to_edge(edges, max_dist=int(cap) + 6)
    dist_in = dist * inside
    shape = np.clip(dist_in / cap, 0.0, 1.0)
    envelope = np.sin(0.5 * np.pi * shape)
    return envelope, inside


def blade_stamp(radius, angle, length, width, amp, midrib_amp=0.35, tip_frac=0.4):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    taper_len = length * tip_frac
    taper_u0 = half_l - taper_len
    along = np.ones_like(u)
    in_taper = (u > taper_u0) & (u <= half_l)
    along[in_taper] = 0.5 * (1.0 + np.cos(np.pi * (u[in_taper] - taper_u0) / taper_len))
    along[u > half_l] = 0.0
    along[u < -half_l] = 0.0
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    midrib = midrib_amp * np.exp(-(v ** 2) / (2.0 * (width / 6.0) ** 2))
    return (amp * along * (cross + midrib)).astype(np.float32)


def scatter_blades(size, guide, inside, n, seed, length_range, width_range,
        angle_mean=np.pi / 2.0, angle_spread=0.35):
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
        angle = rng.normal(angle_mean, angle_spread)
        length = rng.uniform(*length_range)
        width = rng.uniform(*width_range)
        jitter = rng.uniform(0.85, 1.15)
        amp = jitter * (0.35 + 0.9 * guide[cy, cx])
        radius = int(np.ceil(length / 2.0 + width))
        stamp = blade_stamp(radius, angle, length, width, amp)
        ys = (np.arange(-radius, radius + 1) + cy) % size
        xs = (np.arange(-radius, radius + 1) + cx) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
        placed += 1
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    alpha_art = src[..., 3]
    opaque = int((alpha_art > 0.5).sum())
    print("alpha: %d of %d texels opaque (%.0f%%), the rest cut clean away" %
          (opaque, alpha_art.size, 100.0 * opaque / alpha_art.size))
    print("class:", CLS)

    art_rgba = lib.upscale(src)
    art_rgb = art_rgba[..., :3]
    alpha256 = art_rgba[..., 3]
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    envelope, inside = edge_envelope(alpha_art, SEED)

    blades_fine = scatter_blades(SIZE, guide, inside, 55, seed=SEED,
            length_range=(50, 90), width_range=(9, 13))
    blades_coarse = scatter_blades(SIZE, guide, inside, 18, seed=SEED + 31,
            length_range=(90, 150), width_range=(12, 18))
    blades = np.maximum(blades_fine, 0.85 * blades_coarse)
    blades = lib.normalise01(blades)

    grain = lib.fbm(SIZE, base_cells=40, octaves=2, seed=GRAIN_SEED, gain=0.5)

    sprig = lib.normalise01(0.66 * blades + 0.20 * guide + 0.14 * (grain * 0.5 + 0.5))

    body = sprig * envelope
    alpha_soft = lib.blur(alpha256, 2)
    hole_floor = 0.02
    height = body * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=VARIATION_SEED, gain=0.55)
    smooth = 0.5 + 0.16 * zscore(envelope) + 0.08 * zscore(variation)

    normal_strength = 15.0
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
