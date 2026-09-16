"""Hand authored LabPBR height and smoothness for kythen_mitteleuropa_limewash.

The 32 px art is a fine dither in two close shades, 0.786 and 0.907, no
drawn joint or block anywhere: a flat washed wall. Row means run a narrow
0.812 to 0.850, but column means spread wider, 0.801 to 0.869, with a soft
low band at columns 2 to 4 and 26 to 28 against higher ground near columns
0, 9 and 14: a slow, broad column-wise wave rather than a texel dither, the
mark of a brush swept top to bottom, so the wash's own faint streaking runs
vertically (elongated along y, varying with x).

lib.class_of reads back "wood" from the bake, the same level-readback
artefact kythen_khmer_stucco.py's own render gets, not a material judgement:
a lime wash is a cured mineral coating on masonry, hard like stone, so this
overrides to "stone" for the same reason.

The brief is explicit that this surface is nearly flat with the brush
texture living in the smoothness, not the height, so the height stays a
whisper (kept in a narrow lib.band, smaller than kythen_khmer_stucco.py's
own render) and is expected to sit under the stone tilt band and above the
jointed ao_min target on purpose, the same informational shortfall
kythen_khmer_stucco.py and kythen_mitteleuropa_stone.py's own flat and
domeless faces report: there is no joint or dome here for it to occlude.
"""
import sys

import numpy as np

import lib

GAME = "kythen"
STEM = "kythen_mitteleuropa_limewash"
CLS = "stone"
SIZE = lib.SIZE


def blur_axis(field, radius, axis):
    """Wrapped box blur along one axis only, to stretch a feature along the
    other axis, the same helper mcl_core_planks_big_oak.py uses for grain."""
    if radius <= 0:
        return field
    k = 2 * radius + 1
    acc = np.zeros_like(field)
    for d in range(-radius, radius + 1):
        acc += np.roll(field, d, axis=axis)
    return acc / k


def main():
    out_dir = sys.argv[1]
    src = lib.load_source(STEM, GAME)
    print(f"{STEM}: source shape {src.shape}")
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print(f"lum min {lum.min():.3f} max {lum.max():.3f} mean {lum.mean():.3f} sd {lum.std():.3f}")
    print("unique shades:", sorted(set(np.round(lum.ravel(), 3).tolist())))
    print("row means:", np.round(lum.mean(axis=1), 3))
    print("col means:", np.round(lum.mean(axis=0), 3))
    print(f"class_of would read: {lib.class_of(STEM, GAME)}, overridden to {CLS} "
          f"(a cured lime coating on masonry is a hard manufactured face)")

    # Broad, hand trowelled undulation, the same construction
    # kythen_khmer_stucco.py uses for its own render.
    trowel = lib.fbm(SIZE, base_cells=5, octaves=2, seed=871, gain=0.5)

    # Sparse small pits where the wash has weathered off a high spot.
    pit_field = lib.blur(lib.white_noise(SIZE, seed=872), 1)
    pit_cut = float(np.percentile(pit_field, 5))
    pits = np.where(pit_field < pit_cut, pit_field - pit_cut, 0.0)

    grain = lib.blur(lib.white_noise(SIZE, seed=873), 2)

    field = 0.55 * trowel + 0.20 * pits + 0.25 * grain
    field = (field - field.mean()) / max(float(field.std()), 1e-6)
    # A wash this flat is well under the stone tilt band on purpose, the
    # same call kythen_khmer_stucco.py makes: kept in an even narrower band
    # than that render, since the brief puts the brush texture in the
    # smoothness, not here.
    height = lib.band(field, 0.05)
    print(f"height sd {height.std():.3f}")

    # Smoothness: this is where the brush lives. A broad, low frequency
    # streak swept vertically (blurred along y, varying with x) carries the
    # column-wise wave the art's own means show, plus the wash's own fine
    # variation, well spread since the height gives almost none.
    brush = blur_axis(lib.fbm(SIZE, base_cells=8, octaves=2, seed=874, gain=0.5), radius=30, axis=0)
    variation = lib.fbm(SIZE, base_cells=26, octaves=3, seed=875, gain=0.55)
    smooth = 0.42 * brush + 0.55 * variation
    print(f"pre pack smooth sd {smooth.std():.3f}")

    albedo = lib.upscale(rgb)
    normal_strength = 6.0
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
