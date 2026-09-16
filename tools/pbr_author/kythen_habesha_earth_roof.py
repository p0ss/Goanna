"""Hand authored height and smoothness for kythen_habesha_earth_roof.

The 32 px art is a mottled tan and brown dither, luminance 0.35 to 0.46, one
dominant shade (lib.segments, tolerance 0.03, finds a single 516 texel
region, half the tile) with smaller patches of straw and timber colour on
top. Row means run 0.39 to 0.43 with no periodic dip, so there is no beam
line drawn under the earth to read: this is chika, packed mud plastered
over a timber roof from above, and what shows is the mud, not the frame
beneath it. The brief calls it flat and matte, so the layout here is the
mottling itself, smoothly upscaled and rounded the way hardened_clay.py
reads a fired tile's own blotches, held in a narrow band rather than the
soil class's full joint depth.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_habesha_earth_roof"
CLS = lib.class_of(STEM, GAME)
SIZE = lib.SIZE


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("row means:", np.round(lum.mean(axis=1), 3))
    print(f"lib.class_of reads: {CLS}")

    lo, hi = float(lum.min()), float(lum.max())
    norm_lum = (lum - lo) / max(hi - lo, 1e-6)

    # The mud's own mottling, smoothly upscaled and rounded, no drawn
    # region to build domes from.
    mottle = lib.upscale(norm_lum, smooth=True)
    mottle = lib.blur(mottle, 3)

    ripple = lib.fbm(SIZE, base_cells=40, octaves=2, seed=121, gain=0.5)

    # Sparse small pits: a straw stem's impression, a pebble trodden into
    # the mud before it set, not a crack network.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=122), 1)
    pit_cut = float(np.percentile(pit_field, 5))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0)

    grain = lib.blur(lib.white_noise(SIZE, seed=123), 2)

    field = 0.35 * mottle + 0.30 * ripple + 0.15 * pits + 0.12 * grain
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    height = lib.band(field, 0.16)

    # One real deep pit carved straight into the banded height, a genuine
    # hole trodden through towards the timber below before the mud dried,
    # cut after the band rather than mixed in before it: lib.band scales by
    # its single most extreme point, and an outlier mixed in earlier would
    # flatten every other texel's real, gentle mottling in the process.
    hole_field = lib.blur(lib.white_noise(SIZE, seed=124), 1)
    hole_cut = float(np.percentile(hole_field, 0.3))
    holes = np.where(hole_field < hole_cut, (hole_field - hole_cut) * 3.4, 0.0)
    height = np.clip(height + holes, 0.0, 1.0)
    print(f"height sd {height.std():.4f}")

    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=125, gain=0.55)
    smooth = 0.25 * (height - height.mean()) + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.4f}")

    albedo = lib.upscale(rgb)
    # Flat and matte, per the brief: a modest strength lets the mottling
    # register without turning packed earth into a pitted rock face.
    normal_strength = 25.0
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
