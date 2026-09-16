"""Hand authored height and smoothness for kythen_khmer_river_silt.

The same reading as kythen_khmer_paddy_silt.py: six close shades in a fine
dither (segments do not find real regions at any reasonable tolerance),
row and column mean standard deviation both under 0.02 with no dominant
axis, so no directional ripple is invented. This is river bed sediment
rather than paddy floor, so it is built a touch smoother still: a lower
normal_strength than paddy_silt's, since river current works a bed finer
than foot and buffalo traffic works a paddy. lib.class_of reads it back as
soil from the bake; this script uses sand instead, for the same reason as
paddy_silt, a loose fine sediment with no drawn joints.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_river_silt"
CLS_READ = lib.class_of(STEM, GAME)
CLS = "sand"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print(f"class read back from the bake: {CLS_READ}; used here: {CLS} "
          "(fine loose sediment reads like sand, not jointed dirt)")

    for tolerance in (0.02, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        print(f"segments at tolerance {tolerance}: n={n} (fine dither, no drawn regions)")

    row_sd = lum.mean(axis=1).std()
    col_sd = lum.mean(axis=0).std()
    print(f"row-mean sd {row_sd:.4f}  col-mean sd {col_sd:.4f} (no directional bias in the art)")

    sweep16 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep16.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)

    grain = lib.fbm(SIZE, base_cells=90, octaves=2, seed=611, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=612), 1)

    height = lib.normalise01(0.20 * sweep + 0.55 * grain + 0.35 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=40, octaves=3, seed=613, gain=0.55)
    smooth = 0.25 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    normal_strength = 1.5
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
