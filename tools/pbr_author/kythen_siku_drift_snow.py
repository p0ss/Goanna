"""Hand authored LabPBR height and smoothness for kythen_siku_drift_snow.

The 32 px art (cultures/siku/materials.json: "mottle", base snow_lit,
accent snow_white, cells 26) is fresh drift, almost flat: two shades a few
percent apart, the same kind of art default_snow.py reads for
Mineclonia's own snow, a soft crust with a gentle roll from drifting and a
scatter of individual crystal facets catching the light. Built the same
way: a broad low frequency drift plus sparse texel sized sparkle, no
regions, no joints, nothing with a hard edge.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_drift_snow"
CLS = "snow"
SIZE = lib.SIZE


def zscore(field):
    return (field - field.mean()) / (field.std() + 1e-6)


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    lum16 = lib.luminance(src[..., :3])
    print(f"source luminance min {lum16.min():.3f} mean {lum16.mean():.3f} max {lum16.max():.3f} sd {lum16.std():.3f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    art_rgb = lib.upscale(src[..., :3])
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 3))

    drift = lib.fbm(SIZE, base_cells=6, octaves=3, seed=131, gain=0.5)
    drift = lib.blur(drift * 0.5 + 0.5, 3)

    grains = lib.white_noise(SIZE, seed=132)
    threshold = np.percentile(grains, 96.0)
    sparkle = np.clip((grains - threshold) / (grains.max() - threshold), 0.0, 1.0)
    sparkle = lib.blur(sparkle, 1)

    height = 0.60 * drift + 0.30 * guide + 0.22 * sparkle
    height = lib.normalise01(height)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=7, octaves=2, seed=133, gain=0.5)
    smooth = 0.5 + 0.11 * zscore(variation) + 0.35 * sparkle

    albedo = lib.upscale(src[..., :3])
    normal_strength = 5.5
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
