"""Hand authored LabPBR height and smoothness for kythen_siku_qulliq_flame.

The 32 px art (cultures/siku/materials.json: "flat", base flame_orange,
accent flame_pale, grain 1, surface.emission 0.75) is a single flat warm
shade, nothing drawn: every texel of this tile is the flame itself, "a
line of small flames along the straight edge of a shallow dish of oil",
the recipe's own note, "light, heat, cooker and clothes-dryer for a whole
household". Since every texel is flame and none is dish or wick, the
brief's instruction is followed directly rather than the recipe's own
0.75: emission is set to full strength (1.0) across the whole map, not
partial, so the shader's EMISSION = ALBEDO * strength * emission_strength
reads the lamp's own warm colour at its full brightness everywhere.

lib.class_of reads "stone" here, a level heuristic coincidence rather than
a claim about what a flame is made of; left as is, since nothing about the
class matters next to the emission, and the flame has no real surface to
speak of.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_qulliq_flame"
CLS = "stone"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    lum = lib.luminance(src[..., :3])
    print(f"lum min {lum.min():.3f} max {lum.max():.3f}, flat recipe, nothing to segment")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    # A soft flicker in the height, a flame has no fixed shape, and a
    # little grain, held very shallow: light, not a solid.
    flicker = lib.fbm(SIZE, base_cells=6, octaves=3, seed=231, gain=0.55)
    grain = lib.blur(lib.white_noise(SIZE, seed=232), 1)
    shape = 0.7 * flicker + 0.3 * grain
    height = lib.band(shape, 0.06)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=20, octaves=2, seed=233, gain=0.5)
    z = (variation - variation.mean()) / (variation.std() + 1e-6)
    smooth = np.clip(0.20 + 0.10 * z, 0.02, 0.6)

    emission = np.ones((SIZE, SIZE), dtype=np.float32)  # every texel is flame, full strength

    albedo = lib.upscale(src[..., :3])
    normal_strength = 3.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, emission=emission, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, emission=1.0 everywhere")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    # tilt and ao are expected to miss: a flame has no real surface,
    # held nearly flat on purpose.
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
