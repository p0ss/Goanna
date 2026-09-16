"""Norse roof turf: a grass mat seen from above, laid on a roof.

32 px art, seven shades, a busy per-texel dither with no macro structure
at all (column spread 0.039, row spread 0.030, and lib.segments finds no
clean region either): a mat of short grass blades seen from directly
above, every one pointing a different way, not a single dominant grain
direction the way a log's bark or a plank's grain has. Built the same way
this game's own leaf scripts build a canopy of small stamps, here short
blades scattered at random angles and positions rather than one directional
grain, taller where the art itself is brighter. class_of reads soil, the
same class kythen_norse_turf_wall.py's stacked blocks use, and soil is a
jointed class in lib.check (ao_min at or under 0.35), so the blade scatter
also has to carry real self shadowing, not just colour variation.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_norse_roof_turf"
SIZE = lib.SIZE
SEED = 9401


def blade_stamp(length, width, angle, amp, rim_frac=0.8, rim_depth=0.05):
    r = int(np.ceil(max(length, width)))
    d = np.arange(-r, r + 1, dtype=np.float32)
    dy, dx = np.meshgrid(d, d, indexing="ij")
    ca, sa = np.cos(angle), np.sin(angle)
    u = dx * ca + dy * sa
    v = -dx * sa + dy * ca
    rr = np.sqrt((u / length) ** 2 + (v / width) ** 2)
    dome = np.where(rr <= 1.0, 0.5 * (1.0 + np.cos(np.pi * np.clip(rr, 0, 1))), 0.0)
    in_rim = (rr > rim_frac) & (rr <= 1.0)
    rim = np.zeros_like(dome)
    rim[in_rim] = -rim_depth * np.sin(np.pi * (rr[in_rim] - rim_frac) / (1.0 - rim_frac))
    return (amp * (dome + rim)).astype(np.float32), r


def scatter_blades(size, guide, n, seed, length_range, width_range):
    rng = np.random.default_rng(seed)
    field = np.zeros((size, size), dtype=np.float32)
    cx = rng.integers(0, size, n)
    cy = rng.integers(0, size, n)
    angle = rng.uniform(0.0, np.pi, n)
    length = rng.uniform(*length_range, n)
    width = rng.uniform(*width_range, n)
    jitter = rng.uniform(0.85, 1.15, n)
    for i in range(n):
        local_guide = guide[cy[i], cx[i]]
        amp = jitter[i] * (0.35 + 0.85 * local_guide)
        stamp, r = blade_stamp(length[i], width[i], angle[i], amp)
        ys = (np.arange(-r, r + 1) + cy[i]) % size
        xs = (np.arange(-r, r + 1) + cx[i]) % size
        idx = np.ix_(ys, xs)
        field[idx] = np.maximum(field[idx], stamp)
    return field


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("lum min %.3f max %.3f mean %.3f sd %.3f" % (lum.min(), lum.max(), lum.mean(), lum.std()))
    col_mean = lum.mean(axis=0)
    row_mean = lum.mean(axis=1)
    print("column spread %.3f  row spread %.3f (no macro structure)" %
            (col_mean.max() - col_mean.min(), row_mean.max() - row_mean.min()))
    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)

    art_rgb = lib.upscale(rgb)
    guide = lib.normalise01(lib.blur(lib.luminance(art_rgb), 2))

    blades_fine = scatter_blades(SIZE, guide, 2600, seed=SEED, length_range=(3.0, 5.5),
            width_range=(1.0, 1.6))
    blades_coarse = scatter_blades(SIZE, guide, 800, seed=SEED + 1, length_range=(5.5, 9.0),
            width_range=(1.4, 2.2))
    blades = np.maximum(blades_fine, 0.75 * blades_coarse)
    blades = lib.normalise01(blades)

    grain = lib.fbm(SIZE, base_cells=40, octaves=2, seed=SEED + 3, gain=0.5)

    height = lib.normalise01(0.85 * blades + 0.15 * guide + 0.06 * (grain * 0.5 + 0.5), 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=SEED + 4, gain=0.55)
    smooth = 0.5 * height + 0.45 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 4.5
    m = lib.pack(STEM, out_dir, albedo, height, smooth, cls,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, cls)
    for line in lines:
        print(line)
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
