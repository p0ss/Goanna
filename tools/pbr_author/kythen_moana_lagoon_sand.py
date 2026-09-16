"""Hand authored height and smoothness for kythen_moana_lagoon_sand.

The 32 px art is the flattest of the three moana sands: luminance 0.818 to
0.880, standard deviation only 0.021, and lib.segments finds the same 39
regions at every tolerance tried, one 652 texel background (64 percent of
the tile) and a scatter of small patches, never collapsing further and
never fragmenting more. Blurred at native resolution the sweep barely
rises above the raw noise (0.0085 against 0.021), the weakest broad signal
of the three, so this is fine, still lagoon water sand, packed close to
uniform with almost no dune or ripple structure left in it. Built the same
way as default_sand.py and kythen_firecountry_ridge_sand.py, with the
sweep given the smallest share of the height and the grain built at the
highest cell count (the finest individual grains) of the three moana sands.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_lagoon_sand"
CLS = "sand"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("class_of reads:", lib.class_of(STEM, GAME))

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = sorted(np.bincount(labels.ravel()).tolist(), reverse=True)
        print(f"segments at tolerance {tolerance}: n={n} sizes_top5={sizes[:5]}")

    sweep32 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)

    # Fine grain, the highest cell count of the three moana sands: lagoon
    # water sorts sand fine and even, with only a faint separate dusting.
    grain = lib.fbm(SIZE, base_cells=125, octaves=2, seed=871, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=872), 1)

    height = lib.normalise01(0.12 * sweep + 0.58 * grain + 0.36 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=46, octaves=3, seed=873, gain=0.55)
    smooth = 0.20 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 1.4
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
