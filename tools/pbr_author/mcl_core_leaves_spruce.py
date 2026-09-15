"""Hand authored height and smoothness for mcl_core_leaves_spruce.

The art is a per-texel dither of four grey levels with 24 percent of its
texels punched to alpha zero, the holes going straight to black rather than
some other colour showing through, which is the game's own way of drawing
a conifer sprig: needles seen edge on from every direction, not a canopy of
broad flat faces. There is nothing to segment either, so the relief is
built the way the art reads, from many short elongated ridges scattered at
random angles rather than the domes a broad leaf gets, each standing taller
where the art is lighter and lower where it is darker. The alpha holes are
gaps clean through the sprig, carved to the deepest points on the map
regardless of what ridge would otherwise sit there. Smoothness still
follows height, but with less of it: a needle is thin, so most of what
reads as a raised point is a tip rather than a broad waxy face, and tips
are what weathers first, so the material's own variation leans matte
rather than waxy the way the broad leaf stems do.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out at."""
    return (field - field.mean()) / (field.std() + 1e-6)


def needle_stamp(length, width, angle, amp, rim_frac=0.78, rim_depth=0.06):
    """An elongated dome, long axis at angle, meeting zero slope at its own
    rim, with a shallow groove just inside the rim where one needle gives
    way to the next. No midrib: a needle is too thin to carry one, unlike a
    broad leaf's lobe."""
    r_extent = int(np.ceil(max(length, width)))
    d = np.arange(-r_extent, r_extent + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    r = np.sqrt((u / length) ** 2 + (v / width) ** 2)
    dome = np.where(r <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, 1))), 0.0)
    in_rim = (r > rim_frac) & (r <= 1.0)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (r[in_rim] - rim_frac) / (1.0 - rim_frac))
    return (amp * (dome + rim)).astype(np.float32), r_extent


def scatter_needles(size, guide, n, seed, length_range, width_range):
    """Places n needles at random positions and angles, taller where guide
    (the art's own brightness) is higher, combined by maximum so a proud
    needle is not averaged away by whatever else overlaps it."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(length_range[0], length_range[1], n)
    width = rng.uniform(width_range[0], width_range[1], n)
    jitter = rng.uniform(0.85, 1.15, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.4 + 0.9 * local_guide)
        stamp, r = needle_stamp(length[i], width[i], angle[i], amp)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def build(out_dir):
    stem = "mcl_core_leaves_spruce"
    src = lib.load_source(stem)
    print("source", stem, src.shape)
    lum16 = lib.luminance(src[..., :3])
    alpha16 = src[..., 3]
    print("source luminance min %.3f mean %.3f max %.3f sd %.3f" %
          (lum16.min(), lum16.mean(), lum16.max(), lum16.std()))
    print("alpha: %d of 256 texels transparent (%.0f%%)" %
          ((alpha16 < 0.5).sum(), 100.0 * (alpha16 < 0.5).mean()))

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    alpha256 = lib.upscale(src[..., 3])
    alpha_soft = lib.blur(alpha256, 2)

    # Two needle scales: a fine layer that reads as individual needles and
    # a sparser, slightly longer layer underneath giving the sprig a body,
    # both far shorter and narrower than a broad leaf's lobes.
    needles_fine = scatter_needles(SIZE, guide, 2200, seed=701,
            length_range=(4.0, 7.0), width_range=(1.0, 1.8))
    needles_coarse = scatter_needles(SIZE, guide, 700, seed=702,
            length_range=(7.0, 12.0), width_range=(1.6, 2.6))
    needles = np.maximum(needles_fine, 0.75 * needles_coarse)
    needles = lib.normalise01(needles)

    # Fine cuticle grain, under a single needle's own width.
    grain = lib.fbm(SIZE, base_cells=48, octaves=2, seed=703, gain=0.5)

    sprig = lib.normalise01(0.85 * needles + 0.15 * guide + 0.08 * (grain * 0.5 + 0.5))

    # The holes go all the way down regardless of what needle would
    # otherwise be there: a hole is a gap clean through the sprig.
    hole_floor = 0.02
    height = sprig * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    # Smoothness follows height, but weaker than a broad leaf's: a needle
    # is thin, so a raised point is more often a matte tip than a
    # continuous waxy face. The independent variation runs at the needle
    # tip's own scale and outweighs the height term, keeping the sprig
    # matte overall while still letting the odd needle face catch a sheen.
    variation = lib.fbm(SIZE, base_cells=34, octaves=3, seed=704, gain=0.55)
    smooth = 0.5 + 0.06 * zscore(height) - 0.10 * zscore(variation)

    albedo = lib.upscale(src)
    normal_strength = 5.0
    metrics = lib.pack(stem, out_dir, albedo, height, smooth, "leaves",
                        normal_strength=normal_strength)
    lines = lib.check(metrics, "leaves")
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
