"""Hand authored height and smoothness for kythen_moana_sago_palm.

The 32 px art is 85 percent opaque, a per texel dither, lum 0.323 to
0.526, the same face on canopy dither as the other Moana foliage stems
(breadfruit, candlenut, hardwood): no drawn frond outline, no midrib line,
just overlapping tone with sky through the gaps. A sago palm's own fronds
are pinnate, many narrow leaflets off a central rib rather than an oak's
broad rounded lobes, so the lobe stamp used for the round canopies is
stretched into a short, narrow ellipse here to read as a leaflet cluster
instead, still placed and sized from the art's own brightness and still
carved through at the alpha holes.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_sago_palm"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def leaflet_stamp(radius, angle, amp, elongate=2.2, rim_frac=0.78, rim_depth=0.10,
        midrib_amp=0.24, midrib_sigma_frac=0.20):
    """A dome stretched along its own angle into a short narrow ellipse, a
    pinnate leaflet rather than a round oak lobe, with the same rim drop
    and midrib device as the round canopies."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    r = np.sqrt((u / elongate) ** 2 + v ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, radius) / radius)), 0.0)
    rim_r0 = rim_frac * radius
    in_rim = (r > rim_r0) & (r <= radius)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (r[in_rim] - rim_r0) / (radius - rim_r0))
    sigma = midrib_sigma_frac * radius
    midrib = midrib_amp * np.exp(-(v ** 2) / (2.0 * sigma ** 2)) * dome
    return (amp * (dome + rim + midrib)).astype(np.float32)


def scatter_leaflets(size, guide, n, seed, radius_range):
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
        r = int(radius[i])
        stamp = leaflet_stamp(r, angle[i], amp)
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
    print("source luminance min %.3f mean %.3f max %.3f sd %.3f" %
          (lum16.min(), lum16.mean(), lum16.max(), lum16.std()))
    print("alpha: %d of %d texels transparent (%.0f%%)" %
          ((alpha16 < 0.5).sum(), alpha16.size, 100.0 * (alpha16 < 0.5).mean()))
    print("class:", CLS)

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    alpha256 = lib.upscale(src[..., 3])
    alpha_soft = lib.blur(alpha256, 2)

    leaflets_fine = scatter_leaflets(SIZE, guide, 900, seed=1501, radius_range=(4, 7))
    leaflets_coarse = scatter_leaflets(SIZE, guide, 320, seed=1502, radius_range=(7, 11))
    leaflets = np.maximum(leaflets_fine, 0.8 * leaflets_coarse)
    leaflets = lib.normalise01(leaflets)

    grain = lib.fbm(SIZE, base_cells=42, octaves=2, seed=1503, gain=0.5)

    canopy = lib.normalise01(0.82 * leaflets + 0.18 * guide + 0.08 * (grain * 0.5 + 0.5))

    hole_floor = 0.03
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=1504, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src)
    normal_strength = 7.5
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
