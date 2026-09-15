"""Hand authored height and smoothness for mcl_flowers_double_plant_grass_bottom.

The art is a cut-out: greyscale blades the game tints green, drawn as thin
diagonal strokes one or two texels wide against full transparency, seen
from the side rather than the dithered mat a grass block's top gets. There
is nothing for lib.segments to find either, a segment needs neighbours of
similar colour and these blades are one texel wide with transparency on
both sides, so the layout comes straight from the alpha channel: each
opaque run is a blade, its silhouette the shape lib.warp_labels rounds.

A first pass built the relief from the alpha shape's own distance to edge
alone: it gave a correct convex cross section, but where the art's strokes
run close enough together to read as one solid clump (the bottom half is
78 percent opaque) the middle of that clump sits farther than any cross
section's cap from an edge on every side, so the whole interior saturated
into one flat plateau and the tilt came out at 7 degrees against a 20 to
30 target. A clump that dense is not one wide blade, it is several blades
overlapping, so the relief is built as a scatter of individual blade
ridges (the same device grass_block_top.py and leaves_spruce.py use for
their own dense mats), each an almost uniform strip tapering only at its
own tip, convex across its width with a slightly raised midrib down the
centre, mostly upright with some lean either way to match the art's own
diagonal strokes. The scatter is then held inside an envelope taken from
the alpha shape's own warped distance to edge, so height still falls to
nothing exactly at the art's cut boundary and at its drawn tips, whatever
the scatter did there. Smoothness follows the same envelope, waxy along
the exposed length and matte right at the cut edge, plus the art's own
per texel dither, which reads as a shaded fold rather than noise, folded
in as a mild extra lift.

mcl_flowers_double_plant_grass_top.py is the upper half of the same plant
and imports SEED, GRAIN_SEED, VARIATION_SEED, edge_envelope, blade_stamp
and scatter_blades from this module, so the two textures share the same
warp and grain character and read as one plant split across two blocks.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE
STEM = "mcl_flowers_double_plant_grass_bottom"
CLS = "leaves"

SEED = 501
GRAIN_SEED = 511
VARIATION_SEED = 521


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out at."""
    return (field - field.mean()) / (field.std() + 1e-6)


def edge_envelope(alpha16, seed, warp_amp=4.0, cap=8.0):
    """0 at the art's own cut edge and at a drawn tip, 1 across the middle
    of a blade's width, from the wrapped texel distance to the alpha
    shape's own boundary. The 16 px alpha is thresholded to a two label
    map and warped up to map size with lib.warp_labels first, so the
    boundary this distance is measured from is a rounded, irregular
    silhouette rather than the blocky one np.kron would give it. A
    scatter placed inside this envelope always reads as tapering to
    nothing at the real cut, whatever the scatter itself did there."""
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
    taper only over the tip_frac nearest its tip (the other end runs off
    into the plant's own base rather than tapering, unlike a blade seen
    from above with both ends in frame), convex gaussian across the width
    with a narrower, slightly raised midrib down the centre."""
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
        angle_mean=np.pi / 2.0, angle_spread=0.4):
    """Places n blades with their centres inside the art's own opaque
    texels, mostly upright with some lean either way to match the art's
    diagonal strokes, taller where the art itself is brighter there."""
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

    blades_fine = scatter_blades(SIZE, guide, inside, 260, seed=SEED,
            length_range=(28, 55), width_range=(6, 10))
    blades_coarse = scatter_blades(SIZE, guide, inside, 90, seed=SEED + 31,
            length_range=(55, 95), width_range=(9, 14))
    blades = np.maximum(blades_fine, 0.85 * blades_coarse)
    blades = lib.normalise01(blades)

    # Grain below the texel: the fine crinkle of a blade's own cuticle.
    grain = lib.fbm(SIZE, base_cells=40, octaves=2, seed=GRAIN_SEED, gain=0.5)

    sprig = lib.normalise01(0.66 * blades + 0.20 * guide + 0.14 * (grain * 0.5 + 0.5))

    # Held inside the envelope from the art's own alpha shape, so height
    # still falls to nothing exactly at the cut edge and at a drawn tip
    # whatever the scatter did there, then blended by the art's own soft
    # antialiased edge: a transparent texel is a hole cut clean through,
    # not a dip in the surface.
    body = sprig * envelope
    alpha_soft = lib.blur(alpha256, 2)
    hole_floor = 0.02
    height = body * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    # Waxy along the exposed length (where the envelope is high), matte at
    # the cut edge (where it falls to zero), plus the material's own
    # grubby variation from an unrelated field.
    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=VARIATION_SEED, gain=0.55)
    smooth = 0.5 + 0.16 * zscore(envelope) + 0.08 * zscore(variation)

    normal_strength = 11.0
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
