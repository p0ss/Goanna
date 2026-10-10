"""Hand authored height and smoothness for kythen_moana_deep_sand.

The 32 px art carries a real broad sweep: blurred at native resolution
(radius 2) the standard deviation is 0.029 against the raw art's 0.049, a
clear broad packed to loose signal, stronger than either of Firecountry's
own two sands (ridge_sand's sweep barely rises above its raw noise, river_
sand's sits at 0.029 as well but off a lower raw sd). lib.segments finds
real patches at 0.03 and 0.05 (126 regions, a graded spread of sizes rather
than one dominant blob), collapsing mostly to a single background only at
0.08. This is the coarsest of the three moana sands, deep loose sand that
has not been packed by water or wind the way the lagoon and reef sands
have, so the grain here is built at the lowest cell count of the three
(bigger individual grains) and the sweep carries a full share of the
height, the same reasoning default_sand.py and kythen_firecountry_river_
sand.py give their own broad packed to loose reading.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_moana_deep_sand"
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

    # The sweep: blur the native art hard enough to kill texel to texel
    # dither, then a smooth upscale so it arrives as a gentle rise and
    # fall rather than the source's own texel edges.
    sweep32 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)

    # Coarse grain, the lowest cell count of the three moana sands: big,
    # loose, ungraded grains, plus a separate finer dusting on top.
    grain = lib.fbm(SIZE, base_cells=55, octaves=2, seed=861, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=862), 1)

    height = lib.normalise01(0.28 * sweep + 0.48 * grain + 0.34 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: uniformly rough, with only a faint variation, a little of
    # it following the grain the way loose sand's own high side wears a
    # touch smoother than the pit beside it.
    variation = lib.fbm(SIZE, base_cells=34, octaves=3, seed=863, gain=0.55)
    smooth = 0.26 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 2.2
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
