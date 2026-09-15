"""Hand authored height and smoothness for mcl_flowers_tallgrass.

The art is a cut-out, 46 percent opaque: greyscale blades the game tints
green, drawn as thin diagonal strokes against full transparency, two loose
tufts that merge lower in the frame. There is nothing for lib.segments to
find, a segment needs neighbours of similar colour and these strokes are a
texel or two wide with transparency either side, so the layout comes
straight from the alpha channel. A first pass tried reading the whole
opaque area as one dome from its distance to the alpha edge, the way a
cobble's stones come from their distance to the mortar; where the strokes
are close enough to read as one clump the interior sits farther from any
edge than a blade's own cross section should, and the middle of the clump
went flat. A clump that size is several overlapping blades, not one wide
one, so the relief is a scatter of individual blade ridges instead (the
device grass_block_top.py and leaves_spruce.py use for their own dense
mats): each blade almost uniform along most of its length, tapering only
near its own tip, convex across its width with a slightly raised midrib
down the centre, mostly upright with some lean either way. The scatter is
then held inside an envelope taken from the alpha shape's own warped
distance to edge, so height still falls to nothing exactly at the art's
cut boundary and at a drawn tip, whatever the scatter did there.
Smoothness follows that envelope, waxy along the exposed length and matte
right at the cut edge, plus the art's own per texel dither folded in as a
mild extra lift.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE
STEM = "mcl_flowers_tallgrass"
CLS = "leaves"

SEED = 801
GRAIN_SEED = 811
VARIATION_SEED = 821


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def edge_envelope(alpha16, seed, warp_amp=4.0, cap=8.0):
    """0 at the art's own cut edge and at a drawn tip, 1 across the middle
    of a blade's width. See mcl_flowers_double_plant_grass_bottom.py for
    the full reasoning; this is the same construction."""
    mask16 = (alpha16 > 0.5).astype(int)
    mask_hi = lib.warp_labels(mask16, amp=warp_amp, seed=seed, cells=10)
    inside = mask_hi.astype(np.float32)
    edges = lib.region_edges(mask_hi)
    dist = lib.distance_to_edge(edges, max_dist=int(cap) + 6)
    dist_in = dist * inside
    shape = np.clip(dist_in / cap, 0.0, 1.0)
    envelope = np.sin(0.5 * np.pi * shape)
    return envelope, inside


def blade_stamp(radius, angle, length, width, amp, midrib_amp=0.35, tip_frac=0.4):
    """One blade: almost uniform height along most of its length, a cosine
    taper only over the tip_frac nearest its tip, convex gaussian across
    the width with a narrower, slightly raised midrib down the centre."""
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
        angle_mean=np.pi / 2.0, angle_spread=0.45):
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


def build(out_dir):
    src = lib.load_source(STEM)
    print("source", STEM, src.shape)
    alpha16 = src[..., 3]
    opaque = int((alpha16 > 0.5).sum())
    print("alpha: %d of 256 texels opaque (%.0f%%), the rest cut clean away" %
          (opaque, 100.0 * opaque / 256))

    art_rgba = lib.upscale(src)  # nearest, keeps the cut-out's alpha crisp
    art_rgb = art_rgba[..., :3]
    alpha256 = art_rgba[..., 3]
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    envelope, inside = edge_envelope(alpha16, SEED)

    blades_fine = scatter_blades(SIZE, guide, inside, 230, seed=SEED,
            length_range=(24, 46), width_range=(6, 9))
    blades_coarse = scatter_blades(SIZE, guide, inside, 80, seed=SEED + 31,
            length_range=(46, 80), width_range=(8, 13))
    blades = np.maximum(blades_fine, 0.85 * blades_coarse)
    blades = lib.normalise01(blades)

    grain = lib.fbm(SIZE, base_cells=40, octaves=2, seed=GRAIN_SEED, gain=0.5)

    sprig = lib.normalise01(0.66 * blades + 0.20 * guide + 0.14 * (grain * 0.5 + 0.5))

    body = sprig * envelope
    alpha_soft = lib.blur(alpha256, 2)
    hole_floor = 0.02
    height = body * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=VARIATION_SEED, gain=0.55)
    smooth = 0.5 + 0.16 * zscore(envelope) + 0.08 * zscore(variation)

    normal_strength = 17.5
    m = lib.pack(STEM, out_dir, art_rgba, height, smooth, CLS,
                 normal_strength=normal_strength)
    lines = lib.check(m, CLS)
    print("normal_strength", normal_strength)
    for k, v in m.items():
        print("  %s %.4f" % (k, v))
    print("\n".join(lines))
    preview_path = out_dir.rstrip("/") + "/" + STEM + "_preview.png"
    lib.preview(out_dir, STEM, preview_path)
    print("preview", preview_path)
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = build(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
