"""Hand authored LabPBR height and smoothness for kythen_siku_gravel_beach.

The 32 px art (cultures/siku/materials.json: "mottle", base gravel_tan,
accent silt_grey, cells 16, grain 6) never separates into real regions at
any lib.segments tolerance below 0.08, where it collapses straight to one
region: a per texel dither, not a drawing of individual pebbles, the same
reading kythen_gravel.py gives its own art. Built the same way: chip scale
structure from noise rather than segmented flecks, coarser and deeper
than sand, packed close enough to occlude itself.
"""

import sys

import lib

GAME = "kythen"
STEM = "kythen_siku_gravel_beach"
CLS = "gravel"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    sweep16 = lib.blur(lum, 2)
    print(f"sweep sd at native res: {sweep16.std():.4f} (raw art sd {lum.std():.4f})")
    sweep = lib.upscale(sweep16, smooth=True)
    sweep = lib.normalise01(sweep)

    chips = lib.fbm(SIZE, base_cells=42, octaves=3, seed=111, gain=0.55)
    dust = lib.blur(lib.white_noise(SIZE, seed=112), 1)

    height = lib.normalise01(0.15 * sweep + 0.65 * chips + 0.25 * dust, 0.5, 99.5)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=113, gain=0.55)
    smooth = 0.30 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 9.0
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
