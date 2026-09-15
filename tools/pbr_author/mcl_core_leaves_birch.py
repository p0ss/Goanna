"""Hand authored height and smoothness for mcl_core_leaves_birch.

The art is a per-texel dither of five grey levels with 36 percent of its
texels punched to alpha zero, the widest holes of the three species here,
matching the airy look of a birch canopy: small oval leaves on thin
branches, more sky showing through than either the oak or the spruce.
There is nothing to segment, so the relief is built the way the art reads,
from many small oval domes, each shorter across than an oak lobe and
carrying its own faint midrib along the long axis, scattered so they
overlap, standing taller where the art is lighter and lower where it is
darker, with a shallow drop right at its own rim before the next leaf
starts. The alpha holes are gaps clean through the canopy, carved to the
deepest points on the map regardless of what leaf would otherwise sit
there.
"""

import sys

import numpy as np

import lib

SIZE = lib.SIZE


def zscore(field):
    """Zero mean, unit spread, so components combine by a chosen weight
    instead of by whatever scale a noise function happened to come out at."""
    return (field - field.mean()) / (field.std() + 1e-6)


def oval_leaf_stamp(length, width, angle, amp, rim_frac=0.80, rim_depth=0.10,
        midrib_amp=0.18, midrib_sigma_frac=0.22):
    """A small oval dome, long axis at angle, meeting zero slope at its own
    rim, a faint midrib along the long axis and a shallow groove just
    inside the rim where one leaf gives way to the next."""
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
    sigma = midrib_sigma_frac * width
    midrib = midrib_amp * np.exp(-(v ** 2) / (2.0 * sigma ** 2)) * dome
    return (amp * (dome + rim + midrib)).astype(np.float32), r_extent


def scatter_leaves(size, guide, n, seed, length_range):
    """Places n small oval leaves at random positions and angles, width
    a random fraction of each leaf's own length so the ovals are not all
    the same shape, taller where guide (the art's own brightness) is
    higher, combined by maximum so a proud leaf is not averaged away by
    whatever else overlaps it."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(length_range[0], length_range[1], n)
    width = length * rng.uniform(0.55, 0.75, n)
    jitter = rng.uniform(0.85, 1.15, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.4 + 0.9 * local_guide)
        stamp, r = oval_leaf_stamp(length[i], width[i], angle[i], amp)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def build(out_dir):
    stem = "mcl_core_leaves_birch"
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

    # Small ovals, shorter across than an oak lobe or a birch's own branch
    # gap: a fine layer of individual leaves and a sparser, slightly bigger
    # layer underneath for the odd leaf caught face on.
    leaves_fine = scatter_leaves(SIZE, guide, 950, seed=801,
            length_range=(4.5, 6.5))
    leaves_coarse = scatter_leaves(SIZE, guide, 320, seed=802,
            length_range=(7.0, 9.5))
    leaves = np.maximum(leaves_fine, 0.8 * leaves_coarse)
    leaves = lib.normalise01(leaves)

    # Fine cuticle grain on the leaf faces, well under a single leaf's size.
    grain = lib.fbm(SIZE, base_cells=44, octaves=2, seed=803, gain=0.5)

    canopy = lib.normalise01(0.82 * leaves + 0.18 * guide + 0.08 * (grain * 0.5 + 0.5))

    # The holes go all the way down regardless of what leaf would otherwise
    # be there: a hole is a gap through the whole canopy, not a dim leaf.
    hole_floor = 0.03
    height = canopy * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    # Smoothness follows height (leaf faces smoother than the rim drops and
    # holes), plus its own independent variation. Both z scored and centred
    # on 0.5 so the spread survives pack()'s own 0..1 clip.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=804, gain=0.55)
    smooth = 0.5 + 0.11 * zscore(height) + 0.08 * zscore(variation)

    albedo = lib.upscale(src)
    normal_strength = 7.4
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
