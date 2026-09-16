"""Hand authored height and smoothness for kythen_habesha_painted_plaster.

The 32 px art is a red ochre and cream motif on plaster, luminance 0.29 to
0.67 and the widest colour spread in this family (mean saturation 0.359).
The brief is explicit: flat, the painted design is colour only, with no
relief on the paint. So unlike every other stem here, the height field
below is built with no reference at all to the art's own luminance or
lib.segments: it comes only from independent plaster grain noise, held in a
narrow band, so a dark red brushstroke and a pale ground sit at exactly the
same height. Reading the paint's own pattern into the height, the way
almost every other soil stem in this family does, would draw the design a
second time as relief the brief says is not there.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_painted_plaster"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    sat = rgb.max(-1) - rgb.min(-1)
    print(f"sat mean {sat.mean():.3f} max {sat.max():.3f}")
    print(f"lib.class_of reads: {CLS}")

    # Plaster grain only, no reading of the art's own tone or regions: the
    # paint carries no relief.
    ripple = lib.fbm(SIZE, base_cells=36, octaves=3, seed=191, gain=0.5)
    grain = lib.blur(lib.white_noise(SIZE, seed=192), 2)
    fine = lib.blur(lib.white_noise(SIZE, seed=193), 1) * 0.5

    field = 0.55 * ripple + 0.25 * grain + 0.20 * fine
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    height = lib.band(field, 0.08)

    # One real deep pit, a genuine chip in the render where the plaster has
    # come away, not anything to do with the paint.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=194), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 2.4, 0.0)
    height = np.clip(height + holes, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    # Smoothness may carry a very light trace of the paint (a fresh painted
    # patch can catch the light a touch differently from the bare plaster
    # around it), well inside the class spread, plus the render's own grain.
    variation = lib.fbm(SIZE, base_cells=22, octaves=3, seed=195, gain=0.55)
    lum_hi = lib.upscale(lum, smooth=True)
    smooth = 0.08 * lum_hi + 0.6 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    normal_strength = 46.0
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
