"""Hand authored height and smoothness for kythen_shared_gravel.

The art is 32 px here, twice kythen_gravel's 16, so a source texel is 8
map texels rather than 16. Same reading: per texel dither, luminance 0.397
to 0.593, segments giving over a hundred fragments at every tolerance
tried and never a real region, so this is colour grain, not drawing, built
the same way as kythen_gravel.py: a broad sweep from a blur of the art,
chip scale structure coarser than sand, and a dusting in the gaps.
"""

import sys

import lib

GAME = "kythen"
STEM = "kythen_shared_gravel"
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

    sweep32 = lib.blur(lum, 3)  # wider than the 16 px script, the art is twice the size
    print(f"sweep sd at native res: {sweep32.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.normalise01(lib.upscale(sweep32, smooth=True))

    chips = lib.fbm(SIZE, base_cells=40, octaves=3, seed=251, gain=0.55)
    dust = lib.blur(lib.white_noise(SIZE, seed=252), 1)

    height = lib.normalise01(0.15 * sweep + 0.65 * chips + 0.25 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.3f}")

    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=253, gain=0.55)
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
