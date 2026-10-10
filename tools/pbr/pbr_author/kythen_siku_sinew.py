"""Hand authored LabPBR height and smoothness for kythen_siku_sinew.

The 32 px art (cultures/siku/materials.json: "bark", base sinew_pale,
accent bone_shadow, fissure 10, furrow 0.45, wander 1.6, flake 0, cells 10)
never separates into clean furrow columns the way kythen_siku_driftwood.py's
own bark does (checked: the art's column spread, 0.0147, is a fine dither
rather than a handful of clear dark columns), and the recipe's own note
says why: it was drawn with "bark", blocktex.py's parallel strand field,
"laid cord" at ten strands to the node with almost no meander, rather than
the woven checker this package has no recipe for. So this is not read off
the art's own regions at all; it is built directly as a twisted cord: a
handful of parallel ridges running down the tile, given a slow helical
twist rather than kept straight, the difference between a cord and a
plank.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_siku_sinew"
CLS = "leaves"
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"row mean spread {lum.mean(axis=1).std():.4f} col mean spread {lum.mean(axis=0).std():.4f}")
    print("lib.class_of reads:", lib.class_of(STEM, GAME))

    y = np.arange(SIZE)[:, None].astype(np.float32)
    x = np.arange(SIZE)[None, :].astype(np.float32)
    strands = 10  # the recipe's own "ten strands to the node"
    twist_cycles = 2.0  # a slow helical lay over the length of the cord
    phase = (x / SIZE) * strands * 2 * np.pi + (y / SIZE) * twist_cycles * 2 * np.pi
    ridges = np.cos(phase)  # -1..1, one ridge per strand, running along y and twisting in x

    fibre = lib.fbm(SIZE, base_cells=30, octaves=3, seed=191, gain=0.55) * 0.35
    grain = lib.blur(lib.white_noise(SIZE, seed=192), 1) * 0.15

    shape = 0.65 * ridges + fibre + grain
    height = lib.band(shape, 0.20)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=193, gain=0.55)
    smooth = 0.30 * ridges + 0.4 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(src[..., :3])
    normal_strength = 8.0
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
