"""Hand authored height and smoothness for kythen_mitteleuropa_fen_peat.

The 32 px art has three shades: one 505 to 560 texel matrix (tolerance
dependent) plus two smaller patches of 229 and 129 texels, and a handful of
fragments, the same shape of structure kythen_firecountry_reed_peat.py
found in its own fen art, one broad mat rather than separate clods. This is
packed fibrous peat, soft underfoot, so it follows that script's own
recipe directly: tangled fibre at two crossing angles rather than
default_dirt's clod domes, with the darker patches carved down as the
mat's own settled hollows.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_fen_peat"
CLS = "soil"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    for tolerance in (0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} biggest={int(sizes.max())}")

    guide = lib.normalise01(lib.blur(lib.upscale(lum, smooth=True), 2))

    fibre_a = blur_axis(lib.fbm(SIZE, base_cells=28, octaves=2, seed=861, gain=0.5), radius=10, axis=1)
    fibre_b = blur_axis(lib.fbm(SIZE, base_cells=28, octaves=2, seed=862, gain=0.5), radius=10, axis=0)
    fibre = 0.6 * fibre_a + 0.6 * fibre_b

    lumps = lib.fbm(SIZE, base_cells=9, octaves=3, seed=863, gain=0.55) * 0.30

    layout = 0.30 * guide + 0.35 * lumps + 0.35 * fibre

    fuzz = lib.blur(lib.white_noise(SIZE, seed=864), 1) * 0.05
    # A narrower blur than reed_peat's own (radius 1, not 2) so the hollow
    # wall rises within a texel or two: at radius 2 the ao minimum sat at
    # 0.37 to 0.40 whatever the depth, the wall too gradual for the
    # horizon based occlusion to see.
    hollow_field = lib.blur(lib.white_noise(SIZE, seed=865), 1)
    hollow_cut = float(np.percentile(hollow_field, 30))
    hollows = np.where(hollow_field < hollow_cut, hollow_field - hollow_cut, 0.0) * 2.4

    height = lib.normalise01(layout + fuzz + hollows, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=866, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 12.0
    height = lib.band(height, 0.42)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
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
