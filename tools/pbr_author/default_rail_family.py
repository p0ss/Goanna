"""Shared build for the rail family: default_rail, default_rail_curved,
default_rail_crossing and default_rail_t_junction.

Each piece is a cut-out: most of the tile is a real gap (alpha zero,
the ground underneath the track shows through) and the drawn part is two
kinds of texel in one palette of browns and greys. Luminance alone will
not separate them (a rail texel and a sleeper texel can sit at the same
brightness), but colour does: a rail texel is neutral, red equal to blue,
where a sleeper texel is warm, red well above blue, the same test on all
four pieces because it is the paint, not the layout, that says which is
which. The steel sits proud and smooth on top of the wooden sleepers
below it, both carrying the art's own shading as their base relief.
"""

import numpy as np

import lib

SIZE = lib.SIZE
HOLE_FLOOR = 0.03
WARM_THRESHOLD = 0.05


def build(stem, out_dir, seed, normal_strength):
    src = lib.load_source(stem)
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    warm = rgb[..., 0] - rgb[..., 2]
    opaque = alpha > 0.5
    rail16 = opaque & (warm < WARM_THRESHOLD)
    sleeper16 = opaque & ~rail16
    print("%s: %d rail texels, %d sleeper texels, %d transparent" % (
            stem, rail16.sum(), sleeper16.sum(), (~opaque).sum()))

    lum01 = lib.normalise01(lum, 2, 98)
    base = lib.upscale(lum01)
    rail_hi = lib.upscale(rail16.astype(np.float32)) > 0.5
    sleeper_hi = lib.upscale(sleeper16.astype(np.float32)) > 0.5

    # The rail rides on top of the sleeper: its own shading picked out at
    # a higher band, the sleeper's at a lower one, so the two read as two
    # different pieces of material rather than one continuous surface.
    height = np.where(rail_hi, 0.55 + 0.35 * base,
              np.where(sleeper_hi, 0.15 + 0.30 * base, base * 0.1))
    narrow = lib.blur(height, 1)
    wide = lib.blur(height, 2)
    height = narrow + 0.5 * (narrow - wide)

    # Wood grain along the sleepers, brushed steel structure on the rail,
    # both far under the texel's own size.
    grain = lib.fbm(SIZE, base_cells=24, octaves=3, seed=seed, gain=0.55)
    steel_grain = lib.fbm(SIZE, base_cells=50, octaves=2, seed=seed + 7, gain=0.5)
    height = height + np.where(sleeper_hi, grain * 0.05, steel_grain * 0.015)
    pores = lib.blur(lib.white_noise(SIZE, seed=seed + 1), 1) * 0.015
    height = height + pores

    alpha_soft = lib.blur(lib.upscale(alpha), 1)
    height = height * alpha_soft + HOLE_FLOOR * (1.0 - alpha_soft)
    height = lib.normalise01(height, 0.3, 99.7)

    variation = lib.fbm(SIZE, base_cells=20, octaves=2, seed=seed + 2, gain=0.5)
    smooth = np.where(rail_hi, 0.70 + 0.12 * (variation * 0.5 + 0.5),
              np.where(sleeper_hi, 0.20 + 0.20 * (variation * 0.5 + 0.5),
                       0.30 + 0.15 * (variation * 0.5 + 0.5)))

    albedo = lib.upscale(src)
    m = lib.pack(stem, out_dir, albedo, height, smooth, "metal",
            normal_strength=normal_strength, metal_mask=rail_hi)
    return m


def report(stem, m):
    lines = lib.check(m, "metal")
    print("\n".join(lines))
    for k, v in m.items():
        print("  %s %.4f" % (k, v))
    return lines
