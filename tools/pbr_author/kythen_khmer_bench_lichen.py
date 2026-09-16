"""Hand authored height and smoothness for kythen_khmer_bench_lichen.

Unlike every other stem in this batch, the 32 px art is not flat pixel art
at all: it is hand shaded with a near continuous gradient (127 distinct
luminance values over 1024 texels) and carries real, non binary alpha (a
scattered dither from fully opaque down to 0, mean 0.82, no two texel
neighbourhood the same), not the blocky flat shade regions
lib.segments is built to find. lib.class_of reads "wood" back from the
bake, a level readback artefact; the brief calls this "a flat stone bench
face with lichen patches", so it is overridden to "stone".

Luminance and greenness (the green channel less the blue) are essentially
uncorrelated here (r = -0.02): brightness is the stone's own ambient
shading, greenness is the lichen's own coverage, and they are read
separately. The lichen sits slightly proud and matte where it grows, the
bare stone flat and a little smoother between patches.

The alpha channel is kept in the albedo as the art draws it. It is not a
classic cut-out (nothing else in this batch treats a bench as one) but a
genuine partial channel the source carries, so it is upscaled with the art
rather than dropped, the same call lib.upscale(src) makes for a real
cut-out.
"""

import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_khmer_bench_lichen"
CLS = "stone"
SIZE = lib.SIZE


def main(out_dir):
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: art shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    alpha = src[..., 3]
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print(f"alpha min {alpha.min():.3f} max {alpha.max():.3f} mean {alpha.mean():.3f}")
    greenness = rgb[..., 1] - rgb[..., 2]
    print(f"greenness min {greenness.min():.3f} max {greenness.max():.3f}")
    print(f"corr(lum, greenness) = {np.corrcoef(lum.ravel(), greenness.ravel())[0, 1]:.3f}")
    print(f"class_of reads: {lib.class_of(STEM, GAME)}, overridden to {CLS} per the brief")

    # A wrapped blur on a nearest upscale, not lib.upscale's smooth=True
    # (see kythen_khmer_earthenware_tile.py's note: PIL's own resize does
    # not wrap and reads as a bad seam on a field this smooth).
    lichen = lib.blur(lib.upscale((greenness - greenness.mean()) / max(float(greenness.std()), 1e-6)), 1)
    stone_shade = lib.blur(lib.upscale((lum - lum.mean()) / max(float(lum.std()), 1e-6)), 1)

    # Fine texture: a little grain in the stone, a slightly clumpier
    # texture in the lichen itself.
    grain = lib.fbm(SIZE, base_cells=30, octaves=3, seed=861, gain=0.55)
    clump = lib.fbm(SIZE, base_cells=16, octaves=3, seed=862, gain=0.55)

    lichen01 = np.clip(lichen * 0.5 + 0.5, 0.0, 1.0)
    field = 0.35 * stone_shade + 0.55 * lichen + 0.06 * grain + 0.10 * clump * lichen01
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    # A flat bench face, its lichen proud but shallow: furniture, not a
    # quarried block, so the relief stays in a narrow band.
    height = lib.band(field, 0.14)
    print(f"height sd {height.std():.3f}")

    # Smoothness: matte where the lichen grows, a little smoother on the
    # bare, worn stone between patches.
    variation = lib.fbm(SIZE, base_cells=24, octaves=3, seed=863, gain=0.55)
    smooth = 0.30 - 0.32 * lichen01 + 0.26 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    # The art's own alpha, kept: see the module docstring.
    albedo = lib.upscale(src)

    normal_strength = 12.0
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
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
