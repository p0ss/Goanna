"""Hand authored height and smoothness for kythen_firecountry_ridge_sand.

The 32 px art is a five shade per texel dither, luminance 0.712 to 0.736,
standard deviation only 0.010, tighter than any Mineclonia sand: no two
touching texels reliably share a shade, so there is nothing for
lib.segments to find (checked at 0.03, 0.05, 0.08, all one blob). This is
wind blown ridge sand, well sorted and fine, with almost no broad tonal
sweep in the art at all (blurred sd at native res barely above raw), so
the height here leans harder on built grain than default_sand.py's own
sweep and less on the art's own broad shape.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_firecountry_ridge_sand"
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
        print(f"segments at tolerance {tolerance}: n={n} (no real regions, ridge sand's colour is grain, not drawing)")

    # The broad sweep: blur the native art hard enough to kill texel to
    # texel dither, then a smooth upscale so it arrives as a gentle rise
    # and fall. Weaker than default_sand's own share below, since this
    # art carries almost no broad signal to begin with.
    sweep32 = lib.blur(lum, 3)
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep32, smooth=True)
    sweep = lib.normalise01(sweep)

    # Fine grain: well sorted wind blown sand is smaller and more even than
    # river sand's own mixed grading, so a tighter cell count and a fainter
    # separate dusting.
    grain = lib.fbm(SIZE, base_cells=110, octaves=2, seed=141, gain=0.5)
    dust = lib.blur(lib.white_noise(SIZE, seed=142), 1)

    height = lib.normalise01(0.14 * sweep + 0.58 * grain + 0.34 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    # Smoothness: uniformly rough with only a faint variation, a touch of
    # it riding the grain the way loose sand's high side wears smoother.
    variation = lib.fbm(SIZE, base_cells=42, octaves=3, seed=143, gain=0.55)
    smooth = 0.22 * (height - height.mean()) + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)

    normal_strength = 1.3
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
