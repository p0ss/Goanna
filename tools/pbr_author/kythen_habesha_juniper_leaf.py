"""Hand authored height and smoothness for kythen_habesha_juniper_leaf.

The 32 px art is a dark, fine grained canopy: unlike the fig or incense
leaf art it has no blotches at all, just a dense scatter of single texel
tone changes and small clusters punched to alpha zero. Juniper foliage is
scale-like and needle-like, not a broad lobed leaf, and the art does not
read as overlapping round lobes the way the oak canopy does, so this
script departs from the pure lobe_stamp recipe: instead of round domes it
stamps short, elongated bumps, each with its own dominant axis, densely
scattered so they overlap like a mass of tiny needles or scales rather
than leaves. The alpha holes are gaps through the whole canopy and are
carved to a low floor regardless of what needle sits there.
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


def needle_stamp(half_len, half_wid, angle, amp, rim_frac=0.85, rim_depth=0.08):
    """An elongated dome, an ellipse stretched along a random axis rather
    than a round lobe: the needle's own long axis is the readable feature,
    so there is no separate midrib, just a shallow rim groove where one
    needle gives way to the next."""
    r = half_len
    d = np.arange(-r, r + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    along = dx * ca + dy * sa
    across = -dx * sa + dy * ca
    q = np.sqrt((along / half_len) ** 2 + (across / half_wid) ** 2)
    dome = np.where(q <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(q, 0, 1))), 0.0)
    in_rim = (q > rim_frac) & (q <= 1.0)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (q[in_rim] - rim_frac) / (1.0 - rim_frac))
    return (amp * (dome + rim)).astype(np.float32)


def scatter_needles(size, guide, n, seed, len_range, wid_range):
    """Places n needles at random positions and random axes, taller where
    guide (the art's own brightness) is higher, combined by maximum so a
    proud needle is not averaged away by whatever else overlaps it."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    half_len = rng.integers(len_range[0], len_range[1] + 1, n)
    half_wid = rng.uniform(wid_range[0], wid_range[1], n)
    jitter = rng.uniform(0.85, 1.15, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.4 + 0.9 * local_guide)
        r = int(half_len[i])
        stamp = needle_stamp(r, float(half_wid[i]), angle[i], amp)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def build(out_dir):
    stem = "kythen_habesha_juniper_leaf"
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

    # Dense elongated needles, two tiers so the mass still has some
    # depth variation, rather than round lobes: the art has no blotches
    # to segment into leaves, only a fine, directionless scatter.
    needles_fine = scatter_needles(SIZE, guide, 1600, seed=6301,
            len_range=(4, 7), wid_range=(1.3, 2.0))
    needles_coarse = scatter_needles(SIZE, guide, 500, seed=6302,
            len_range=(7, 11), wid_range=(1.8, 2.6))
    needles = np.maximum(needles_fine, 0.7 * needles_coarse)
    needles = lib.normalise01(needles)

    # Fine grain, finer again than the needles themselves, matching the
    # art's own single texel dithering.
    grain = lib.fbm(SIZE, base_cells=56, octaves=2, seed=6303, gain=0.5)

    canopy = lib.normalise01(0.78 * needles + 0.22 * guide + 0.10 * (grain * 0.5 + 0.5))

    hole_floor = 0.03
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=6304, gain=0.55)
    smooth = 0.5 + 0.12 * zscore(height) + 0.09 * zscore(variation)

    albedo = lib.upscale(src)
    normal_strength = 6.6
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
