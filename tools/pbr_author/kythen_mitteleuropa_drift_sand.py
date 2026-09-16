"""Hand authored height and smoothness for kythen_mitteleuropa_drift_sand.

The 32 px art has only two grey shades, no two touching texels reliably
the same one: pure per texel dither, the same reading default_sand.py gives
its own 16 px art. lib.segments finds nothing (checked at 0.03, 0.05, 0.08,
the region count never falls, so the two shades never join into a real
region). There is no drawn structure to keep, only grain, so this follows
default_sand.py's own recipe: a broad blurred sweep for the loose large
scale undulation and fine fbm plus dust for the grain itself, since a
single 32 px texel is already many real sand grains.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_drift_sand"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print("source", STEM, src.shape)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("class:", CLS)

    for tolerance in (0.03, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        print(f"segments at tolerance {tolerance}: n={n} (no real regions, pure dither)")

    # The sweep: blur the native art hard enough to kill texel to texel
    # dither, then a smooth upscale so it arrives as a gentle continuous
    # rise and fall.
    sweep32 = lib.blur(lum, 3)
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)

    # Fine grain: two octaves so it is not one grain size, plus a finer
    # dusting on top for texel to texel sparkle.
    grain = lib.fbm(SIZE, base_cells=90, octaves=2, seed=821, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=822), 1)

    height = lib.normalise01(0.20 * sweep + 0.55 * grain + 0.35 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: uniformly rough with only a faint variation, a little of
    # it following the grain so a grain's own high side reads a touch less
    # rough than the pit beside it.
    variation = lib.fbm(SIZE, base_cells=40, octaves=3, seed=823, gain=0.55)
    smooth = 0.25 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

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
