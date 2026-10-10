"""Hand authored height and smoothness for kythen_mitteleuropa_meadow_turf.

The 32 px art has four shades, but they are not a plain lightness ladder:
checking each shade's own spatial layout, the two darkest (lum 0.481 and
0.483, 107 and 77 texels) sit as scattered lone texels the way grass gaps
do, the mid shade (0.537, 559 texels) fills most of the tile as the base
blade mat, and the brightest (0.597, 281 texels, 27 percent of the art)
forms real rounded clusters, a strip down the left edge and a dozen
smaller blobs, not a scatter. That is the meadow's flowers: a distinct
patch, not a dither fleck, so it is segmented from the art and built as a
second, proud layer riding above the ordinary blade mat everywhere else,
the same blade stamp kythen_firecountry_sward.py and
mcl_core_grass_block_top.py use for the base. All four shades are close in
hue (0.20 to 0.23, olive green), so this is not a coloured flower against
green grass, only a lighter, denser patch of growth; it keeps the art's
own colour rather than a tint the game would recolour away.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_meadow_turf"
SIZE = lib.SIZE


def blade_stamp(radius, angle, length, width, amp):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_blades(size, guide, n, seed, length_range, width_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    jitter = rng.uniform(0.8, 1.2, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.35 + 0.95 * local_guide)
        radius = int(np.ceil(length[i] / 2.0 + width[i]))
        stamp = blade_stamp(radius, angle[i], length[i], width[i], amp)
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
    maxc, minc = rgb.max(axis=-1), rgb.min(axis=-1)
    print(f"lum min {lum.min():.3f} mean {lum.mean():.3f} max {lum.max():.3f} sd {lum.std():.3f}")
    print(f"saturation mean {(maxc - minc).mean():.3f} (kept as drawn colour)")
    print("lib.class_of reads:", lib.class_of(STEM, GAME), "- overridden to leaves, grass mat from above")

    shades = sorted(set(np.round(lum.ravel(), 4).tolist()))
    for sh in shades:
        mask = np.isclose(lum, sh, atol=1e-4)
        print(f"  shade {sh:.4f}: {int(mask.sum())} texels")

    # The brightest shade alone, the flower patch, at native resolution.
    fleck_native = (lum > 0.59).astype(int)
    print(f"flower fraction at native res: {fleck_native.mean():.3f}")
    flecks = lib.warp_labels(fleck_native, amp=2.5, seed=901).astype(np.float32)
    flecks = lib.blur(flecks, 1)  # soften the warped edge into a rounded clump

    art_rgb = lib.upscale(rgb)
    lum_hi = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum_hi, 2))

    blades_fine = scatter_blades(SIZE, guide, 2600, seed=902, length_range=(6, 12), width_range=(2, 3))
    blades_coarse = scatter_blades(SIZE, guide, 900, seed=903, length_range=(12, 22), width_range=(3, 5))
    blades = np.maximum(blades_fine, 0.75 * blades_coarse)
    blades = lib.normalise01(blades)

    grain = lib.fbm(SIZE, base_cells=48, octaves=2, seed=904, gain=0.5)
    base = 0.72 * blades + 0.18 * guide + 0.10 * (grain * 0.5 + 0.5)
    base = lib.normalise01(base)

    # The flowers stand proud of the ordinary mat, a soft dome over each
    # patch rather than a hard step.
    height = np.clip(base * (1.0 - 0.35 * flecks) + 0.55 * flecks, 0.0, 1.0)
    height = lib.normalise01(height)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=905, gain=0.55)
    # Flower heads catch a touch more light than the blade mat around them.
    smooth = 0.5 + 0.13 * (height - height.mean()) / (height.std() + 1e-6) \
            + 0.09 * (variation - variation.mean()) / (variation.std() + 1e-6) \
            + 0.06 * flecks

    albedo = lib.upscale(rgb)
    normal_strength = 6.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, "leaves",
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, "leaves")
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
