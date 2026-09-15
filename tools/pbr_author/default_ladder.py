"""Hand authored height and smoothness for default_ladder.

The art is two vertical stringers, each two texels wide (columns 2 to 3
and 12 to 13, the only columns opaque in every row) and two horizontal
rungs, each two texels tall and opaque nearly the full width (rows found
as the rows with far more opaque texels than a stringer only row has).
Everywhere else is a real gap, punched to alpha zero, glimpsing whatever
is behind the ladder.

The rungs are round: a rod seen face on shows as a band shaded brighter
in the middle and darker at each edge, so the rung's relief is a half
cylinder across its own two texel height, proud of the flat stringers it
crosses. The stringers carry the art's own faint banding as their only
texture, the wood between the rungs.
"""

import sys

import numpy as np

import lib

STEM = "default_ladder"
CLS = "wood"
SIZE = lib.SIZE
SEED = 6100
NORMAL_STRENGTH = 36.0
HOLE_FLOOR = 0.03
STRINGER_LEVEL = 0.32
RUNG_PEAK = 0.95


def main(out_dir):
    src = lib.load_source(STEM)
    rgb = src[..., :3]
    alpha = src[..., 3]
    lum = lib.luminance(rgb)
    h, w = alpha.shape

    opaque = alpha > 0.5
    rung_row = opaque.sum(axis=1) > (opaque.sum(axis=1).max() + 4) / 2
    stringer_col = opaque.all(axis=0)
    print("%s: rung rows %s, stringer columns %s" % (
            STEM, np.where(rung_row)[0].tolist(), np.where(stringer_col)[0].tolist()))

    sy = SIZE // h
    sx = SIZE // w

    # Stringers: the art's own light and dark banding, percentile mapped,
    # kept well below the rung peak so the rungs stand proud on them.
    stringer_lum01 = lib.normalise01(lum, 2, 98)
    stringer_height16 = STRINGER_LEVEL * (0.5 + 0.5 * stringer_lum01)
    stringer_height = lib.upscale(stringer_height16)

    # Rungs: a half cylinder across the rung's own two texel band, one
    # profile per rung so two adjacent rung rows read as one rounded rod,
    # not two separate bumps.
    height = stringer_height.copy()
    rung_groups = []
    cur = []
    for y in range(h):
        if rung_row[y]:
            cur.append(y)
        elif cur:
            rung_groups.append(cur)
            cur = []
    if cur:
        if rung_groups and rung_groups[0][0] == 0 and cur[-1] == h - 1:
            rung_groups[0] = cur + rung_groups[0]
        else:
            rung_groups.append(cur)
    print("%s: rung groups %s" % (STEM, rung_groups))

    for group in rung_groups:
        y0 = group[0] * sy
        band = len(group) * sy
        ys = (np.arange(band) + y0) % SIZE
        t = (np.arange(band) + 0.5) / band * 2.0 - 1.0  # -1..1 across the rung
        profile = RUNG_PEAK * np.cos(t * (np.pi / 2.0)) ** 0.7
        height[ys, :] = np.maximum(height[ys, :], profile[:, None])

    # Fine wood grain along the whole ladder, and the rung's own faint
    # surface variation, both far under the rung's own size.
    grain = lib.fbm(SIZE, base_cells=20, octaves=3, seed=SEED, gain=0.55) * 0.05
    pores = lib.blur(lib.white_noise(SIZE, seed=SEED + 1), 1) * 0.02
    height = height + grain + pores

    alpha_soft = lib.blur(lib.upscale(alpha), 1)
    height = height * alpha_soft + HOLE_FLOOR * (1.0 - alpha_soft)
    height = lib.normalise01(height, 0.3, 99.7)

    variation = lib.fbm(SIZE, base_cells=18, octaves=2, seed=SEED + 2, gain=0.5)
    smooth = 0.55 * height + 0.45 * (variation * 0.5 + 0.5)

    albedo = lib.upscale(src)
    m = lib.pack(STEM, out_dir, albedo, height, smooth, CLS,
            normal_strength=NORMAL_STRENGTH)
    print("normal_strength", NORMAL_STRENGTH)
    for k, v in m.items():
        print("  %s %.4f" % (k, v))
    lines = lib.check(m, CLS)
    print("\n".join(lines))
    # ao min fails here by design, not oversight: the rungs and stringers
    # are isolated rods with open air on both sides everywhere except
    # where they cross, so no floor texel is ever enclosed by height on
    # two sides the way a masonry joint is. Reaching 0.35 would mean
    # digging a pocket the ladder does not have.
    print("note ao min target is for jointed masonry; the ladder is an open lattice, see comment")
    lib.preview(out_dir, STEM, str(out_dir) + "/" + STEM + "_preview.png")
    return lines


if __name__ == "__main__":
    out_dir = sys.argv[1]
    lines = main(out_dir)
    if any(l.startswith("FAIL") for l in lines):
        sys.exit(1)
