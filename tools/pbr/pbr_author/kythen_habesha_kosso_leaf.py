"""Hand authored height and smoothness for kythen_habesha_kosso_leaf.

The 32 px art is a canopy seen face on, coloured a rust red-brown with
green flecks (Hagenia abyssinica carries reddish young growth and its
drooping "kosso" flower clusters are themselves pinkish red, so the art's
warm colour is the game's own choice, not repainted here), with the same
small clusters punched to alpha zero as the other habesha leaves. Kosso
is compound pinnate like the incense tree but its leaflets are coarser
and more defined, so the relief uses small to medium lobes with a
stronger midrib bias than the incense script's, so each lobe reads as an
elongated leaflet rather than a round dot. The alpha holes are gaps
through the whole canopy and are carved to a low floor regardless of
what lobe sits there.
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


def lobe_stamp(radius, angle, amp, rim_frac=0.80, rim_depth=0.10,
        midrib_amp=0.30, midrib_sigma_frac=0.16):
    """A gentle dome with a pronounced midrib: the strong midrib bias is
    what makes a radially symmetric dome read as an elongated leaflet
    rather than a round lobe, per the coarser kosso leaflet shape."""
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
    stem = "kythen_habesha_kosso_leaf"
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

    # Small to medium lobes, coarser and fewer than incense's fine
    # leaflets but smaller than fig's broad lobes, with the midrib bias
    # doing the work of making each one read as an elongated leaflet.
    lobes_fine = scatter_lobes(SIZE, guide, 620, seed=6401, radius_range=(5, 7))
    lobes_coarse = scatter_lobes(SIZE, guide, 260, seed=6402, radius_range=(8, 11))
    lobes = np.maximum(lobes_fine, 0.8 * lobes_coarse)
    lobes = lib.normalise01(lobes)

    grain = lib.fbm(SIZE, base_cells=42, octaves=2, seed=6403, gain=0.5)

    canopy = lib.normalise01(0.81 * lobes + 0.19 * guide + 0.08 * (grain * 0.5 + 0.5))

    hole_floor = 0.03
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=6404, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)

    albedo = lib.upscale(src)
    normal_strength = 7.2
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
