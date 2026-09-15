"""Hand authored height and smoothness for mcl_flowers_short_dry_grass.

The art is a cut-out, 31 percent opaque: a small, sparse tuft, much
smaller in footprint than mcl_flowers_tallgrass.py's, and paler, the
lum16 dither running 0.55 to 0.86 against tallgrass's 0.36 to 0.67, dead
straw rather than living green. The layout comes from the alpha channel
the same way the other grass cut-outs read theirs (see
mcl_flowers_double_plant_grass_bottom.py for the full reasoning): a
scatter of blade ridges held inside an envelope taken from the alpha
shape's own warped distance to edge.

Dry stalks stand straighter and hold their shape less than living blades:
the cross section here is flatter across most of its width rather than a
rounded dome, dropping only at the very edge, so a stalk reads stiff
rather than supple, and the along length taper is shorter, a stalk this
dry snaps rather than curling to a fine point. Smoothness drops the waxy
term the living blade cut-outs get; dry, sun bleached fibre has no sheen
left in it, only a matte, grubbier variation, closer to how
mcl_core_leaves_spruce.py keeps its own needles matte at the tip.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE
STEM = "mcl_flowers_short_dry_grass"
CLS = "leaves"

SEED = 901
GRAIN_SEED = 911
VARIATION_SEED = 921


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def edge_envelope(alpha16, seed, warp_amp=3.0, cap=7.0, stiff=2.2):
    """0 at the art's own cut edge and at a drawn tip, close to 1 across
    most of a blade's width: stiff raises the shape to a power greater
    than 1, so the profile stays flatter across the body and drops only
    near the true edge, a stiffer cross section than the sine dome the
    living blade cut-outs use."""
    mask16 = (alpha16 > 0.5).astype(int)
    mask_hi = lib.warp_labels(mask16, amp=warp_amp, seed=seed, cells=10)
    inside = mask_hi.astype(np.float32)
    edges = lib.region_edges(mask_hi)
    dist = lib.distance_to_edge(edges, max_dist=int(cap) + 6)
    dist_in = dist * inside
    shape = np.clip(dist_in / cap, 0.0, 1.0)
    envelope = np.sin(0.5 * np.pi * shape) ** (1.0 / stiff)
    return envelope, inside


def blade_stamp(radius, angle, length, width, amp, midrib_amp=0.30, tip_frac=0.22):
    """A stiffer blade than the living cut-outs: the taper only reaches
    the last tip_frac of its length (0.22 against 0.4), so a stalk holds
    its width until it snaps off rather than curling to a fine point."""
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
        angle_mean=np.pi / 2.0, angle_spread=0.5):
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

    blades_fine = scatter_blades(SIZE, guide, inside, 150, seed=SEED,
            length_range=(16, 30), width_range=(5, 8))
    blades_coarse = scatter_blades(SIZE, guide, inside, 55, seed=SEED + 31,
            length_range=(30, 50), width_range=(7, 10))
    blades = np.maximum(blades_fine, 0.85 * blades_coarse)
    blades = lib.normalise01(blades)

    # Fibrous grain, coarser than a living blade's cuticle: a dried stalk
    # is cracked and split, not smooth.
    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=GRAIN_SEED, gain=0.55)

    sprig = lib.normalise01(0.62 * blades + 0.20 * guide + 0.18 * (grain * 0.5 + 0.5))

    body = sprig * envelope
    alpha_soft = lib.blur(alpha256, 2)
    hole_floor = 0.02
    height = body * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    # Matte, not waxy: the envelope still sets where the body is (rather
    # than the cut edge), but with a much smaller weight than the living
    # cut-outs give it, and the material's own rougher variation leads.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=VARIATION_SEED, gain=0.55)
    smooth = 0.5 + 0.05 * zscore(envelope) - 0.09 * zscore(variation)

    # With 69 percent of the map cut away to nothing (a smaller, sparser
    # tuft than tallgrass's own 54), the whole image mean cannot reach the
    # leaves band (20 to 30 degrees) without the remaining stalks reading
    # as near vertical; 21 degrees was tried and only reached 17.2 already
    # visibly overdriven (p90 57.9 degrees before this pull back). Held
    # here at a value consistent with the other cut-outs; see the report
    # for the actual number and why.
    normal_strength = 16.0
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
