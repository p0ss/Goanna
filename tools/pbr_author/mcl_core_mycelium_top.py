"""Hand authored height and smoothness for mcl_core_mycelium_top.

The art is a dithered mat of six close grey shades, mean luminance 0.374,
standard deviation 0.034, the same character mcl_core_grass_block_top's own
script found: a photograph like texture with no drawn stone or clod, so
lib.segments never finds a real region (checked 0.02 to 0.1; by 0.05 it is
already one 168 texel blob and a scatter of one to seven texel flecks, not
a layout). That reading fits what mycelium actually is: not blades and not
crumb, but a spongy mat of fungal growth, rounded and packed close, with no
preferred direction the way grass blades lean. The relief here is built
from short, round bumps rather than grass_block_top's elongated blades,
scattered denser and taller where the art sits lighter.
"""

import sys

import numpy as np

import lib

STEM = "mcl_core_mycelium_top"
CLS = "leaves"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def bump_stamp(radius, amp):
    """A single spongy bump: a rounded dome, raised cosine radially so it
    tapers to nothing at its own edge and has no preferred direction."""
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    r = np.sqrt(dx ** 2 + dy ** 2)
    dome = np.where(r <= radius, 0.5 * (1.0 + np.cos(np.pi * r / max(radius, 1))), 0.0)
    return (amp * dome).astype(np.float32)

def scatter_bumps(size, guide, n, seed, radius_range):
    """Places n bumps at random positions, taller where guide (the art's
    own brightness) is higher, combined by maximum so one tall bump is not
    drowned by the average of everything under it."""
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    radius = rng.integers(radius_range[0], radius_range[1] + 1, n)
    jitter = rng.uniform(0.8, 1.2, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.35 + 0.95 * local_guide)
        r = int(radius[i])
        stamp = bump_stamp(r, amp)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    for tolerance in (0.02, 0.05, 0.08, 0.1):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n}, largest {sizes.max()} texels "
              f"(no real layout, a dithered mat like grass_block_top's own art)")

    art_rgb = lib.upscale(src[..., :3])
    art_lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(art_lum, 2))

    # Two bump populations, a finer and a coarser one, so the mat does not
    # read as one repeated stamp size, the same reasoning grass_block_top
    # uses for its two blade populations.
    bumps_fine = scatter_bumps(SIZE, guide, 2400, seed=501, radius_range=(2, 4))
    bumps_coarse = scatter_bumps(SIZE, guide, 700, seed=502, radius_range=(5, 8))
    bumps = np.maximum(bumps_fine, 0.7 * bumps_coarse)
    bumps = lib.normalise01(bumps)

    # Grain inside the mat itself: the fine crinkle of the fungal surface,
    # well under a bump's own width.
    grain = lib.fbm(SIZE, base_cells=50, octaves=2, seed=503, gain=0.5)

    height = 0.68 * bumps + 0.20 * guide + 0.12 * (grain * 0.5 + 0.5)
    height = lib.normalise01(height)
    print(f"height sd {height.std():.3f}")

    # Smoothness follows height: bump tops catch a faint sheen, the gaps
    # between them stay matte with moisture and grit. A second, unrelated
    # noise gives it its own texture. Both z scored and centred on 0.5 so
    # the spread survives pack()'s own 0..1 clip.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=504, gain=0.55)
    smooth = 0.5 + 0.13 * zscore(height) + 0.09 * zscore(variation)
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 6.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength)
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
