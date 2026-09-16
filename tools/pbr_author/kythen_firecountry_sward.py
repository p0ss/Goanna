"""Hand authored height and smoothness for kythen_firecountry_sward.

The art is not greyscale (checked): mean saturation 0.35, the highest of
any stem in this batch, so this is a naturally coloured grass mat drawn in
full colour, not a tinted texture the game recolours the way
mcl_core_grass_block_top is. It is still a photograph style dither with no
drawn blade to segment (lib.segments finds no real region structure
beyond patches of a few dozen texels), a felt of overlapping blade tips
seen from above. lib.class_of reads "soil" from the old bake, the ground
node's own footstep, not the material of the visible surface itself: a
lawn top is living grass, and soil's near zero smoothness level would
render it as wet packed dirt rather than blades with a slight waxy sheen,
so this follows mcl_core_grass_block_top.py's own precedent and takes
"leaves" directly rather than the bake's class.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_sward"
SIZE = lib.SIZE


def blade_stamp(radius, angle, length, width, amp):
    d = np.arange(-radius, radius + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    half_l = length / 2.0
    along = np.where(np.abs(u) <= half_l, 0.5 * (1.0 + np.cos(np.pi * u / half_l)), 0.0)
    cross = np.exp(-(v ** 2) / (2.0 * (width / 2.0) ** 2))
    return (amp * along * cross).astype(np.float32)


def scatter_blades(size, guide, n, seed, length_range, width_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    jitter = rng.uniform(0.8, 1.2, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.35 + 0.95 * local_guide)
        radius = int(np.ceil(length[i] / 2.0 + width[i]))
        stamp = blade_stamp(radius, angle[i], length[i], width[i], amp)
        ys = (np.arange(-radius, radius + 1) + cy[i]) % size
        xs = (np.arange(-radius, radius + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum16 = lib.luminance(rgb)
    maxc, minc = rgb.max(axis=-1), rgb.min(axis=-1)
    print(f"lum min {lum16.min():.3f} mean {lum16.mean():.3f} max {lum16.max():.3f} sd {lum16.std():.3f}")
    print(f"saturation mean {(maxc - minc).mean():.3f} (not greyscale, kept as drawn colour)")
    print("lib.class_of reads:", lib.class_of(STEM, GAME), "- overridden to leaves, see module docstring")

    art_rgb = lib.upscale(rgb)
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    blades_fine = scatter_blades(SIZE, guide, 2600, seed=271, length_range=(6, 12), width_range=(2, 3))
    blades_coarse = scatter_blades(SIZE, guide, 900, seed=272, length_range=(12, 22), width_range=(3, 5))
    blades = np.maximum(blades_fine, 0.75 * blades_coarse)
    blades = lib.normalise01(blades)

    grain = lib.fbm(SIZE, base_cells=48, octaves=2, seed=273, gain=0.5)
    height = 0.72 * blades + 0.18 * guide + 0.10 * (grain * 0.5 + 0.5)
    height = lib.normalise01(height)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=3, seed=274, gain=0.55)
    smooth = 0.5 + 0.13 * (height - height.mean()) / (height.std() + 1e-6) \
            + 0.09 * (variation - variation.mean()) / (variation.std() + 1e-6)

    albedo = lib.upscale(rgb)
    normal_strength = 5.5
    m = lib.pack(STEM, out_dir, albedo, height, smooth, "leaves",
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, "leaves")
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
