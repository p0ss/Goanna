"""Hand authored LabPBR height and smoothness for kythen_siku_ochre.

The 32 px art (cultures/siku/materials.json: "flat", base ochre_red,
accent blood_red, grain 1) is "red ochre, for a face and for a grave", a
single flat shade, nothing drawn. lib.class_of reads "stone" (a level
heuristic read, not a claim ochre is rock), left as is here rather than
overridden, because stone's own low packed level (0.12) is exactly matte,
which is what a ground pigment is. All structure is our own, sub texel
grit from a powder ground fine on a stone, held nearly flat.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_ochre"
CLS = "stone"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    lum = lib.luminance(src[..., :3])
    print(f"lum min {lum.min():.3f} max {lum.max():.3f}, flat recipe, nothing to segment")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    # Powdery grit: fine noise a texel or two across, no larger structure
    # at all, a ground pigment has no grain the way wood or stone does.
    grit = lib.blur(lib.white_noise(SIZE, seed=221), 1)
    dust = lib.fbm(SIZE, base_cells=26, octaves=2, seed=222, gain=0.5)
    shape = 0.6 * grit + 0.4 * dust
    height = lib.band(shape, 0.035)  # a powder has almost no relief at all
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=30, octaves=2, seed=223, gain=0.5)
    z = (variation - variation.mean()) / (variation.std() + 1e-6)
    smooth = np.clip(0.10 + 0.10 * z, 0.02, 0.6)  # matte, a powder scatters light every way
    print(f"pre pack smooth mean {smooth.mean():.4f} sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 3.0
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=normal_strength, art_texels=src.shape[0])
    print(f"normal_strength={normal_strength}")
    for k, v in m.items():
        print(f"  {k} = {v:.4f}")
    lines = lib.check(m, CLS)
    for line in lines:
        print(line)
    # tilt and ao are expected to miss: a powder is held nearly flat on
    # purpose, the flat manufactured face case the brief allows to miss
    # the stone band and say why.
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main()
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
