"""Hand authored LabPBR height and smoothness for kythen_habesha_cast_bronze.

The 32 px art is a single flat shade, luminance 0.543 everywhere, no drawn
detail at all: a cast metal face with nothing painted on it beyond its
colour. There is nothing in the art to segment or trace, so every texel of
relief here is sub texel structure of our own, the way lib.py's "structure
below the texel" rule allows for a plain shade.

This is metal over its whole face, not a vein in a stone matrix, so
metal_mask covers the whole 256 map and cls is set to "metal" rather than
trusting lib.class_of, which reads "stone" here because the bake it reads
back from predates metal awareness on this stem.

lib.pack's keep_mean path computes its smoothness reference from the
texels outside metal_mask; with metal_mask covering everything that set is
empty, so pack() falls back to recentring the WHOLE smoothness field onto
class "metal"'s level, 0.4. That reads as dull, not "cast bronze, slightly
rough and pitted" the way a real casting looks (matte but honestly
reflective, not sandpaper). keep_mean=False is passed instead, so the
authored field (mean near 0.62, with real spread down into the pits) is
written as built.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_cast_bronze"
CLS = "metal"  # class_of reads "stone" (bake predates metal awareness); this
               # is a solid cast metal face, not stone, so the class is set
               # by hand
SIZE = lib.SIZE


def dome_stamp(radius, amp):
    """A round bump (amp > 0) or pit (amp < 0), zero slope at its own rim."""
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
        if amp[i] >= 0:
            field[idx] = np.maximum(field[idx], stamp)
        else:
            field[idx] = np.minimum(field[idx], stamp)
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

    # A wide, gentle casting waviness, the face never poured perfectly flat.
    waviness = lib.fbm(SIZE, base_cells=6, octaves=2, seed=211, gain=0.5) * 0.10

    # Casting pits: a moderate scatter of small round dips, some shallow,
    # a few deeper. "Slightly rough and pitted", not a pockmarked ruin, so
    # the count stays modest and the amplitudes stay small.
    pits = scatter_stamps(SIZE, n=90, seed=212, radius_range=(2, 5), amp_range=(-0.28, -0.08))

    grain = lib.blur(lib.white_noise(SIZE, seed=213), 1) * 0.05

    height = lib.normalise01(0.6 + waviness + pits + grain, 0.5, 99.5)
    # A real but shallow surface: the pits are the deepest feature and they
    # are only a few texels wide, so the height is held to a fraction of
    # the class depth rather than let normalise01 stretch a small dip to
    # fill the whole byte.
    height = lib.band(height, 0.30)
    print(f"height sd {height.std():.4f}")

    # Roughness follows height: pits collect no light and read rough, the
    # cast face between them is what a hand or a blade would polish. Own
    # variation on top, held to a real spread, not a mirror scatter.
    rough_noise = lib.fbm(SIZE, base_cells=22, octaves=3, seed=214, gain=0.55)
    smooth = 0.62 + 0.18 * zscore(height) + 0.06 * zscore(rough_noise)
    print(f"pre pack smooth sd {smooth.std():.4f}, mean {smooth.mean():.4f}")

    albedo = lib.upscale(src[..., :3])
    metal_mask = np.full((SIZE, SIZE), True)
    normal_strength = 26.0
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
