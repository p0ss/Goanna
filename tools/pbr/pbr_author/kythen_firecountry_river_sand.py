"""Hand authored height and smoothness for kythen_firecountry_river_sand.

The 32 px art carries a real broad sweep the wind blown ridge_sand does
not: lib.segments at 0.03 and 0.05 both find 43 regions, the biggest 504
texels (half the tile), the next four 34 to 150 texels, then it collapses
to one blob at 0.08. That is water sorted sand, coarser and less even than
wind blown sand, sitting in patches a shade or two apart rather than an
even dither, standard deviation 0.029 against ridge_sand's 0.010. The
patches are read as a broad packed/loose sweep rather than as separate
domed regions (a river bar has no drawn stones to dome), then grain and
dust below the texel do the rest, the same construction as
default_sand.py.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_river_sand"
CLS = "sand"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"{STEM}: lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        sizes = np.bincount(labels.ravel())
        print(f"segments at tolerance {tolerance}: n={n} sizes_top5={sorted(sizes.tolist(), reverse=True)[:5]}")

    # The sweep: blur the native art (radius 2, enough to wash out texel
    # jitter, matching default_sand.py) then a smooth upscale.
    sweep32 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)

    # Grain a touch coarser than ridge_sand's own: river sand is less well
    # sorted, mixed grain size, plus its own dusting.
    grain = lib.fbm(SIZE, base_cells=80, octaves=2, seed=151, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=152), 1)

    height = lib.normalise01(0.24 * sweep + 0.52 * grain + 0.36 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=36, octaves=3, seed=153, gain=0.55)
    smooth = 0.26 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 1.8
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
