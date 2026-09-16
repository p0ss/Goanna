"""Hand authored height and smoothness for kythen_habesha_fig_leaf.

The 32 px art is a canopy seen face on, the same kind of layout as
mcl_core_leaves_big_oak: a dithered green mass with small clusters of
texels punched to alpha zero for sky showing through. There is no drawn
outline of one leaf to segment against. But a fig leaf is large and
broadly lobed, so unlike the oak's undifferentiated mass the relief here
uses fewer, larger lobes with a clearly readable midrib on each, so a
single fig leaf's shape is visible within the tile rather than a fine
mottled canopy texture. The alpha holes are gaps through the whole
canopy and are carved to a low floor regardless of what lobe sits there.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out
    at."""
    return (field - field.mean()) / (field.std() + 1e-6)


def lobe_stamp(radius, angle, amp, rim_frac=0.82, rim_depth=0.10,
        midrib_amp=0.32, midrib_sigma_frac=0.16):
    """A gentle dome and a clearly raised midrib along a random axis
    through the centre: a fig leaf is large enough that its own midrib
    reads as a feature, not a faint texture, so midrib_amp is higher and
    midrib_sigma_frac narrower than the oak canopy's fine mottle."""
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
    """Places n lobes at random positions, taller where guide (the art's
    own brightness) is higher, combined by maximum so a proud lobe is not
    averaged away by whatever else overlaps it."""
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


def build(out_dir):
    stem = "kythen_habesha_fig_leaf"
    src = lib.load_source(stem, GAME)
    print("source", stem, src.shape)
    lum32 = lib.luminance(src[..., :3])
    alpha32 = src[..., 3]
    print("source luminance min %.3f mean %.3f max %.3f sd %.3f" %
          (lum32.min(), lum32.mean(), lum32.max(), lum32.std()))
    transparent = (alpha32 < 0.5).sum()
    print("alpha: %d of %d texels transparent (%.1f%%)" %
          (transparent, alpha32.size, 100.0 * transparent / alpha32.size))

    cls = lib.class_of(stem, GAME)
    print("class_of ->", cls)

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    alpha256 = lib.upscale(src[..., 3])
    alpha_soft = lib.blur(alpha256, 2)

    # Fewer, larger lobes than the oak canopy: a fig leaf is a broad,
    # simple shape, so a small number of coarse lobes carries the leaf's
    # own silhouette, backed by a medium tier for overlap and a light
    # fine tier so the canopy still reads as more than one leaf per gap.
    lobes_coarse = scatter_lobes(SIZE, guide, 55, seed=6101, radius_range=(18, 26))
    lobes_medium = scatter_lobes(SIZE, guide, 140, seed=6102, radius_range=(11, 16))
    lobes_fine = scatter_lobes(SIZE, guide, 260, seed=6103, radius_range=(6, 9))
    lobes = np.maximum(lobes_coarse, np.maximum(0.85 * lobes_medium, 0.55 * lobes_fine))
    lobes = lib.normalise01(lobes)

    # Fine cuticle grain, well under a lobe's own size, kept light so it
    # does not compete with the midribs for attention.
    grain = lib.fbm(SIZE, base_cells=36, octaves=2, seed=6104, gain=0.5)

    canopy = lib.normalise01(0.84 * lobes + 0.16 * guide + 0.06 * (grain * 0.5 + 0.5))

    hole_floor = 0.03
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    variation = lib.fbm(SIZE, base_cells=16, octaves=3, seed=6105, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)

    albedo = lib.upscale(src)
    normal_strength = 10.5
    metrics = lib.pack(stem, out_dir, albedo, height, smooth, cls,
                        normal_strength=normal_strength, art_texels=src.shape[0])
    lines = lib.check(metrics, cls)
    print("normal_strength", normal_strength)
    for k, v in metrics.items():
        print("  %s %.4f" % (k, v))
    print("\n".join(lines))
    preview_path = out_dir.rstrip("/") + "/" + stem + "_preview.png"
    lib.preview(out_dir, stem, preview_path)
    print("preview", preview_path)
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = build(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
