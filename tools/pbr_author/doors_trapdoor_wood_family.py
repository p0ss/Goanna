"""Shared build for the wood trapdoor pair: doors_trapdoor and
doors_trapdoor_side.

doors_trapdoor is a plank frame with a cross of bracing over it (the
brightest shade, proud, at the border and running down the middle column
and across the middle row) and four square gaps cut through the panel
between the bracing (alpha zero), each ringed by a darker groove shade
where the bracing meets the gap. doors_trapdoor_side is the same plank
seen edge on: the same border and groove drawing top and bottom (its row
0 is a texel for texel match to its row 15, so the two ends of the hinge
side already agree without any help from this script) and a flat plank
face between them.
"""

import numpy as np

import lib

SIZE = lib.SIZE
HOLE_FLOOR = 0.04


def _base(lum16):
    lum01 = lib.normalise01(lum16, 1, 99)
    base = lib.upscale(lum01)
    narrow = lib.blur(base, 1)
    wide = lib.blur(base, 2)
    return narrow + 0.6 * (narrow - wide)


def build_main(stem, out_dir, seed, normal_strength):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    print("%s: opaque shades %s" % (stem, sorted(set(np.round(lum[alpha > 0.5], 3).tolist()))))

    base = _base(lum)
    grain = lib.fbm(SIZE, base_cells=22, octaves=3, seed=seed, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=seed + 1), 1) * 0.02
    height = base + grain + pores

    alpha_soft = lib.blur(lib.upscale(alpha), 1)
    height = height * alpha_soft + HOLE_FLOOR * (1.0 - alpha_soft)
    height = lib.normalise01(height, 0.5, 99.5)

    variation = lib.fbm(SIZE, base_cells=18, octaves=2, seed=seed + 2, gain=0.5)
    smooth = 0.55 * lib.normalise01(base) + 0.45 * (variation * 0.5 + 0.5)

    albedo = lib.upscale(src)
    m = lib.pack(stem, out_dir, albedo, height, smooth, "wood",
            normal_strength=normal_strength)
    return m


def build_side(stem, out_dir, seed, normal_strength):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    lum = lib.luminance(rgb)
    print("%s: shades %s" % (stem, sorted(set(np.round(lum.ravel(), 3).tolist()))))

    base = _base(lum)
    # The side is a flat plank face for eleven of its sixteen rows, so the
    # grain has to carry more of the tilt than on the frame's own faces.
    grain = lib.fbm(SIZE, base_cells=22, octaves=3, seed=seed, gain=0.55) * 0.16
    pores = lib.blur(lib.white_noise(SIZE, seed=seed + 1), 1) * 0.07
    height = lib.normalise01(base + grain + pores, 0.5, 99.5)

    variation = lib.fbm(SIZE, base_cells=18, octaves=2, seed=seed + 2, gain=0.5)
    smooth = 0.55 * lib.normalise01(base) + 0.45 * (variation * 0.5 + 0.5)

    albedo = lib.upscale(rgb)
    m = lib.pack(stem, out_dir, albedo, height, smooth, "wood",
            normal_strength=normal_strength)
    return m


def report(stem, m):
    lines = lib.check(m, "wood")
    print("\n".join(lines))
    for k, v in m.items():
        print("  %s %.4f" % (k, v))
    return lines
