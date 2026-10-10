"""Hand authored height and smoothness for kythen_gravel.

The 16 px art is per texel dither, luminance 0.413 to 0.586, no two
touching texels reliably close: segmenting at 0.02 already gives 161
regions for 256 texels, essentially one region per texel, and it never
collapses into anything but tiny fragments before 0.08. That is grain, the
same reading kythen_sand.py and default_sand.py give their own dithered
art, but gravel is coarser stone, not fine sand: real chips a couple of
texels across, sharper edged and deeper than a sand grain, packed close
enough to touch and occlude each other rather than lying loose.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_gravel"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")

    for tolerance in (0.02, 0.05, 0.08):
        labels, n = lib.segments(rgb, tolerance=tolerance)
        print(f"segments at tolerance {tolerance}: n={n} (no real regions, colour is grain not drawing)")

    # The broad sweep the art carries at native resolution, the same
    # measure kythen_sand.py uses: a shade or two of unevenness across the
    # tile, worn or packed patches.
    sweep16 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep16.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)

    # Chip scale structure: a couple of hires texels across, coarser and
    # deeper than sand's grain, so gravel reads as packed chips rather than
    # fine dust. A second, finer dusting sits in the gaps between chips.
    chips = lib.fbm(SIZE, base_cells=40, octaves=3, seed=241, gain=0.55)
    dust = lib.blur(lib.white_noise(SIZE, seed=242), 1)

    height = lib.normalise01(0.15 * sweep + 0.65 * chips + 0.25 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: gravel is uniformly dull, chip tops a touch smoother than
    # the gaps between them, following the chip field itself.
    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=243, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(src[..., :3])

    cls = lib.class_of(STEM, GAME)
    print("class_of ->", cls)
    normal_strength = 9.0
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
