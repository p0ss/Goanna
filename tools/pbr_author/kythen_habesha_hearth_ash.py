"""Hand authored height and smoothness for kythen_habesha_hearth_ash.

The 32 px art is dark and warm, luminance 0.08 to 0.294, coloured by the
embers still glowing under it (rgb runs from near neutral char, about
[0.13, 0.12, 0.11], to a warm ember red, about [0.66, 0.20, 0.17]) rather
than by any drawn lump or crack. The brief calls this fine soft ash, very
flat and matte, so the relief is built the way hardened_clay.py reads a
fired tile's own mottling, not the way default_dirt.py reads a clod: a
smoothly upscaled reading of the art's own tone, held in a narrow band, no
domes or region boundaries. The warm colour is left as colour only; ash is
not shaped by what glows under it.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_hearth_ash"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"lib.class_of reads: {CLS}")

    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)

    # The ash's own soft drift, smoothly upscaled and rounded: no drawn
    # lump to build a dome from, only where it has settled thicker or thin.
    mottle = lib.upscale(norm_lum, smooth=True)
    mottle = lib.blur(mottle, 3)

    ripple = lib.fbm(SIZE, base_cells=44, octaves=2, seed=151, gain=0.5)

    # Very fine, soft grain: ash is a powder, not a grit.
    grain = lib.blur(lib.white_noise(SIZE, seed=152), 2)
    fine = lib.blur(lib.white_noise(SIZE, seed=153), 1) * 0.5

    field = 0.35 * mottle + 0.30 * ripple + 0.20 * grain + 0.15 * fine
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    height = lib.band(field, 0.10)

    # One real deep pocket, a place fuel burned right down to the hearth
    # floor, cut after the band so it does not flatten the ash's own soft
    # drift the way mixing it in before the band would.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=154), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 2.8, 0.0)
    height = np.clip(height + holes, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=28, octaves=3, seed=155, gain=0.55)
    smooth = 0.20 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 32.0
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
