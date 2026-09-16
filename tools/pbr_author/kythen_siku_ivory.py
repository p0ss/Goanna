"""Hand authored LabPBR height and smoothness for kythen_siku_ivory.

The 32 px art (cultures/siku/materials.json: "flat", base ivory_cream,
accent bone_white, grain 1) is "walrus ivory", a single flat shade, min
equals max: the "flat" recipe paints base alone, nothing drawn to
segment, so every texel of relief here is sub texel structure of our own,
the way lib.py's "structure below the texel" rule allows for a plain
shade (kythen_habesha_cast_bronze.py's own cast metal face reads the same
way off the same recipe).

lib.class_of reads "leaves" (ivory has real subsurface scattering when
thin, a plausible SSS read), whose packed ceiling (0.30 + 0.25 = 0.55)
falls short of the "high smoothness" the brief asks for a polished tusk,
so keep_mean=False carries the authored mean (about 0.78) through
untouched, the recipe's own surface.smooth (0.7) nudged up a little for
"high", the same lever kythen_siku_soapstone.py and
kythen_siku_whale_bone.py use for their own worked and weathered stone.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_ivory"
CLS = "leaves"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    lum = lib.luminance(src[..., :3])
    print(f"lum min {lum.min():.3f} max {lum.max():.3f}, flat recipe, nothing to segment")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    # A faint, wide swell (a tusk's own gentle curve catching the light
    # unevenly) plus fine grain, held in a narrow band: nearly flat.
    swell = lib.fbm(SIZE, base_cells=5, octaves=2, seed=211, gain=0.5)
    grain = lib.blur(lib.white_noise(SIZE, seed=212), 1)
    shape = 0.6 * swell + 0.25 * grain
    height = lib.band(shape, 0.05)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=213, gain=0.55)
    z = (variation - variation.mean()) / (variation.std() + 1e-6)
    smooth = np.clip(0.78 + 0.09 * z, 0.05, 0.95)
    print(f"pre pack smooth mean {smooth.mean():.4f} sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 4.0
    keep_mean = False
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, keep_mean=keep_mean, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}, keep_mean={keep_mean}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    # tilt is expected to miss: ivory is held nearly flat and glassy
    # smooth on purpose, the polished face case the brief allows to miss
    # the tilt band and say why.
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
