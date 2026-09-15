"""Hand authored height and smoothness for mcl_flowers_double_plant_grass_top.

The upper half of the same plant mcl_flowers_double_plant_grass_bottom.py
builds, at 32 percent opaque against that one's 78, a sparser cluster of
blade tips rather than the dense clump the lower half's base makes. It
imports SEED, GRAIN_SEED, VARIATION_SEED, edge_envelope, blade_stamp and
scatter_blades from that module rather than redefining them, so both
textures get the same warp amplitude, the same midrib shape and the same
grain and variation character, and read as one plant split across two
blocks rather than two unrelated cut-outs that happen to be tiled one atop
the other.
"""

import sys

import numpy as np

import lib
from mcl_flowers_double_plant_grass_bottom import (
    GRAIN_SEED, SEED, VARIATION_SEED, edge_envelope, scatter_blades, zscore,
)

SIZE = lib.SIZE
STEM = "mcl_flowers_double_plant_grass_top"
CLS = "leaves"


def build(out_dir):
    src = lib.load_source(STEM)
    print("source", STEM, src.shape)
    alpha16 = src[..., 3]
    opaque = int((alpha16 > 0.5).sum())
    print("alpha: %d of 256 texels opaque (%.0f%%), the rest cut clean away" %
          (opaque, 100.0 * opaque / 256))

    art_rgba = lib.upscale(src)  # nearest, keeps the cut-out's alpha crisp
    art_rgb = art_rgba[..., :3]
    alpha256 = art_rgba[..., 3]
    lum = lib.luminance(art_rgb)
    guide = lib.normalise01(lib.blur(lum, 2))

    envelope, inside = edge_envelope(alpha16, SEED)

    # The same seeds as the bottom half, but shorter, narrower blades at a
    # higher count: the opaque area here is smaller (32 against 78 percent)
    # and the bottom half's own blade size would cover it in a few flat
    # topped strokes rather than the tapering tips this half's own art
    # actually draws.
    blades_fine = scatter_blades(SIZE, guide, inside, 150, seed=SEED,
            length_range=(18, 34), width_range=(5, 8), angle_spread=0.5)
    blades_coarse = scatter_blades(SIZE, guide, inside, 55, seed=SEED + 31,
            length_range=(34, 55), width_range=(7, 10), angle_spread=0.5)
    blades = np.maximum(blades_fine, 0.85 * blades_coarse)
    blades = lib.normalise01(blades)

    grain = lib.fbm(SIZE, base_cells=40, octaves=2, seed=GRAIN_SEED, gain=0.5)

    sprig = lib.normalise01(0.66 * blades + 0.20 * guide + 0.14 * (grain * 0.5 + 0.5))

    body = sprig * envelope
    alpha_soft = lib.blur(alpha256, 2)
    hole_floor = 0.02
    height = body * alpha_soft + hole_floor * (1.0 - alpha_soft)
    height = np.clip(height, 0.0, 1.0)

    variation = lib.fbm(SIZE, base_cells=30, octaves=3, seed=VARIATION_SEED, gain=0.55)
    smooth = 0.5 + 0.16 * zscore(envelope) + 0.08 * zscore(variation)

    # Kept equal to the bottom half's own normal_strength: it is the same
    # plant at the same physical scale, and pushing this alone higher to
    # chase the tilt target would make the tip visibly steeper relief than
    # the base it grows from. With 68 percent of the map cut away to
    # nothing, the whole image mean cannot reach the leaves band (20 to
    # 30 degrees) without the remaining blades reading as near vertical;
    # see the printed tilt line below and the report for the actual number.
    normal_strength = 11.0
    m = lib.pack(STEM, out_dir, art_rgba, height, smooth, CLS,
                 normal_strength=normal_strength)
    lines = lib.check(m, CLS)
    print("normal_strength", normal_strength)
    for k, v in m.items():
        print("  %s %.4f" % (k, v))
    print("\n".join(lines))
    preview_path = out_dir.rstrip("/") + "/" + STEM + "_preview.png"
    lib.preview(out_dir, STEM, preview_path)
    print("preview", preview_path)
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = build(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
