"""Hand authored LabPBR height and smoothness for kythen_habesha_iron_stock.

The 32 px art is a single flat shade, luminance 0.354 everywhere, darker
and with no drawn detail at all, the same situation as cast_bronze: nothing
to segment, so the relief is sub texel structure built to read as worked
iron rather than cast.

Metal over the whole face, so metal_mask covers the whole 256 map and cls
is "metal" by hand, not lib.class_of's "stone" (the bake it reads back
from predates metal awareness on this stem). keep_mean=False for the same
reason as cast_bronze: with metal_mask covering everything, lib.pack's
smoothness reference falls back to the whole field's own mean and
recentres it onto class "metal"'s level, 0.4, which reads dull rather than
worked iron. The authored field (mean near 0.58, hammer facets pushing it
around) is written as built instead.

Hammered rather than cast: broad, roughly planar facets at a shallow angle
to each other, the low frequency undulation a smith's hammer leaves, with
a scatter of small shallow dimples for individual blows on top, rather
than cast_bronze's round casting pits.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_iron_stock"
CLS = "metal"  # class_of reads "stone" (bake predates metal awareness); this
               # is a solid worked metal face, set by hand
SIZE = lib.SIZE


def dome_stamp(radius, amp):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    r = np.sqrt(dx ** 2 + dy ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * np.clip(r, 0, radius) / radius)), 0.0)
    return (amp * dome).astype(np.float32)


def scatter_stamps(size, n, seed, radius_range, amp_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    radius = rng.integers(radius_range[0], radius_range[1] + 1, n)
    amp = rng.uniform(amp_range[0], amp_range[1], n)
    for i in range(n):
        r = int(radius[i])
        stamp = dome_stamp(r, amp[i])
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.minimum(field[idx], stamp) if amp[i] < 0 else np.maximum(field[idx], stamp)
    return field


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: source shape {src.shape}")
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} sd {lum.std():.4f} "
          f"(flat, no drawn detail)")
    print(f"lib.class_of reads: {lib.class_of(STEM, GAME)} (overridden to metal, see docstring)")

    # Broad, low, roughly planar facets: a coarse noise field with few
    # octaves reads as flattish plateaus meeting at shallow angles, the way
    # hammer blows leave a faceted rather than a smooth curved surface.
    facets = lib.fbm(SIZE, base_cells=5, octaves=2, seed=221, gain=0.4) * 0.16

    # A network of shallow creases where facets meet: a ridged field (the
    # absolute value of a coarser noise, inverted) puts its valleys along
    # the seams between broad facets rather than scattered at random.
    ridge_src = lib.fbm(SIZE, base_cells=8, octaves=2, seed=222, gain=0.5)
    creases = -np.abs(ridge_src) * 0.10

    # Individual hammer strikes: many small, shallow, shield shaped dimples,
    # denser and shallower than cast_bronze's rounder, deeper casting pits.
    dimples = scatter_stamps(SIZE, n=160, seed=223, radius_range=(1, 3), amp_range=(-0.14, -0.03))

    grain = lib.blur(lib.white_noise(SIZE, seed=224), 1) * 0.04

    height = lib.normalise01(0.6 + facets + creases + dimples + grain, 0.5, 99.5)
    height = lib.band(height, 0.34)
    print(f"height sd {height.std():.4f}")

    # Roughness follows height: the creases between facets stay rough
    # (unworked, catches no reflection), the facet faces themselves are
    # what carries the worked sheen. A little of the facet field's own
    # directionality rides on top so the sheen is not perfectly uniform.
    rough_noise = lib.fbm(SIZE, base_cells=16, octaves=3, seed=225, gain=0.55)
    smooth = 0.58 + 0.16 * zscore(height) + 0.07 * zscore(rough_noise)
    print(f"pre pack smooth sd {smooth.std():.4f}, mean {smooth.mean():.4f}")

    albedo = lib.upscale(src[..., :3])
    metal_mask = np.full((SIZE, SIZE), True)
    normal_strength = 24.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, metal_mask=metal_mask,
            keep_mean=False, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, keep_mean=False")
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
