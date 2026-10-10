"""Norse iron work: a hammered metal face, metal_mask over the face.

32 px art, a single flat shade, luminance 0.337 everywhere, no drawn
detail at all: a plain metal face with nothing painted on it beyond its
own colour, the same situation kythen_habesha_cast_bronze.py's art is in.
Unlike that cast face, this is described as hammered, not cast: hand
worked with repeated hammer blows rather than poured smooth, so the
waviness is anisotropic and directional, elongated blows rather than a
cast face's round, gentle waviness, and the surface carries more of them,
closer together. No rivets are stamped: the art draws no rivet marks
anywhere (a single flat shade gives nothing to read them from), so unlike
Mineclonia's mcl_doors_iron_family.py riveted plate this stays a plain
hammered face.

class_of reads stone here, the bake it reads back from predating metal
awareness on this stem the same way kythen_habesha_cast_bronze.py records
for its own art, so this overrides to metal by hand and covers the whole
face with metal_mask, the same reasoning.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_iron_work"
CLS = "metal"  # class_of reads "stone" (bake predates metal awareness on this
               # stem); a plain metal face, set by hand
SIZE = lib.SIZE
SEED = 9601


def hammer_stamp(length, width, angle, amp):
    r = int(np.ceil(max(length, width)))
    d = np.arange(-r, r + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    r_norm = np.sqrt((u / length) ** 2 + (v / width) ** 2)
    dome = np.where(r_norm <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(r_norm, 0, 1))), 0.0)
    return (amp * dome).astype(np.float32), r


def scatter_hammer_marks(size, n, seed, length_range, width_range, amp_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    amp = rng.uniform(*amp_range, n)
    for i in range(n):
        stamp, r = hammer_stamp(length[i], width[i], angle[i], amp[i])
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
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

    # Anisotropic hammer blows: elongated, overlapping dished facets at
    # random angles, closer together than kythen_habesha_cast_bronze.py's
    # round casting pits, the way a smith's repeated hammer strikes leave
    # a directional, faceted texture rather than a smooth poured skin.
    hammer_marks = scatter_hammer_marks(SIZE, n=260, seed=SEED,
            length_range=(4.0, 9.0), width_range=(1.6, 3.2), amp_range=(-0.30, -0.08))

    # A slower waviness underneath: the plate itself is not perfectly
    # flat even between hammer blows.
    waviness = lib.fbm(SIZE, base_cells=6, octaves=2, seed=SEED + 1, gain=0.5) * 0.08

    grain = lib.blur(lib.white_noise(SIZE, seed=SEED + 3), 1) * 0.04

    height = lib.normalise01(0.6 + hammer_marks + waviness + grain, 0.5, 99.5)
    # A real but shallow surface: the hammer facets are the deepest
    # feature and only a few texels wide, so the height is held to a
    # fraction of the class depth, the same reasoning
    # kythen_habesha_cast_bronze.py gives its own casting pits.
    height = lib.band(height, 0.32)
    print(f"height sd {height.std():.4f}")

    # Roughness follows height: the facets themselves stay duller (hammer
    # scale, never polished flat), the plate between them is what a hand
    # or a blade would polish smooth over years of use.
    rough_noise = lib.fbm(SIZE, base_cells=24, octaves=3, seed=SEED + 4, gain=0.55)
    smooth = 0.55 + 0.20 * zscore(height) + 0.07 * zscore(rough_noise)
    print(f"pre pack smooth sd {smooth.std():.4f}, mean {smooth.mean():.4f}")

    albedo = lib.upscale(rgb)
    metal_mask = np.full((SIZE, SIZE), True)
    normal_strength = 22.0
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
